local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local system = import("goluwa/system.lua")
local terrain_layer_rules = import("goluwa/render3d/terrain_layer_rules.lua")
local vk = import("goluwa/bindings/vk.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local scatter_proxy = import("goluwa/render3d/scatter_proxy.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local ViewPriority = import("goluwa/render3d/view_priority.lua")
-- models grown on surfaces, see scatter_set.lua for what a surface asks for. a compute pass finds where
-- on the surface's triangles instances go, and writes their matrices. they are drawn by the gbuffer's
-- multi draw pipeline, with indirect draws whose instance counts the compute passes filled in, so a
-- scattered model looks like any other model in the scene
local scatter = {}
scatter.name = "gbuffer_multi_draw"
scatter.MAX_SURFACES = 512
scatter.SURFACE_RING = 4
scatter.MAX_JOBS = 2 ^ 20
scatter.JOB_ROW = 2 ^ 15
scatter.TILE_GROUPS_PER_ROW = 2 ^ 15
scatter.MAX_INSTANCES = 2 ^ 21
scatter.MIN_ROOM = 256
-- the sizes of the cells units are made of, a cell is split into the 16 of the size under it while the camera is
-- closer than BAKE_SPLIT times its size, so a unit a kilometer away is not one of 64 meters
scatter.BAKE_CELLS = {64, 256, 1024}
scatter.BAKE_SPLIT = 1.5
-- units of the bigger cells that the density rules say hold more than PROBE_ABOVE instances are first baked into a room
-- of PROBE_ROOM
scatter.PROBE_ABOVE = 2048
scatter.PROBE_ROOM = 1024
scatter.BAND_FIRST = 16
scatter.BAND_RATIO = 1.6
scatter.BAKE_BUDGET = 8
-- what to bake first: what the camera sees, and where it is going, before what is behind it (the terrain ranks its tiles the same way)
scatter.view_priority = ViewPriority.New()
scatter.MAX_UNITS = 16384
scatter.MAX_BAKED = 2 ^ 21
scatter.PROXY_MAX_INSTANCES = 2 ^ 16
scatter.GROW_MARGIN = 1.5
scatter.MAX_BATCHES = 1024
scatter.TILE_CELLS = 32
scatter.MAX_LEVEL = 4
pvars.StartGroup("Rendering", "Scatter", {store = false, prefix = "feature_"})
local enabled = pvars.Setup2{
	key = "r_feature_scatter",
	default = true,
	help = "the models scattered over surfaces that ask for them, grass, rocks and trees",
}
pvars.EndGroup()
pvars.StartGroup("Rendering", "Scatter", {store = false, prefix = "scatter_"})
local billboards_enabled = pvars.Setup2{
	key = "r_scatter_billboards",
	default = true,
	help = "draw the prototypes that have a billboard as one past their billboard distance",
}
local billboard_scale = pvars.Setup2{
	key = "r_scatter_billboard_distance",
	default = 0.25,
	help = "multiplies the distance the billboards of the scatter prototypes start at",
}
local gi_enabled = pvars.Setup2{
	key = "r_scatter_gi",
	default = true,
	friendly = "bvh",
	help = "put what scatter grows near the camera in the scene bvh, as geometry that is not drawn, for the soup shadows, global illumination and reflections",
}
local gi_distance = pvars.Setup2{
	key = "r_scatter_gi_distance",
	default = 200.0,
	friendly = "bvh distance",
	help = "how far from the camera what scatter grows is the model's own geometry in the scene bvh, past it only the billboards are in it",
}
local billboard_distance = pvars.Setup2{
	key = "r_scatter_gi_billboard_distance",
	default = 1500.0,
	friendly = "bvh billboard distance",
	help = "how far from the camera the prototypes that have a billboard are in the scene bvh as their billboards, for the soup shadows, global illumination and reflections",
}
pvars.EndGroup()
local MAX_PROTOTYPES = ScatterSet.MAX_PROTOTYPES
-- the material's per layer rules and the fields of the surface they go in
local LAYER_RULES = {
	{"SlopeMin", "slope_min"},
	{"SlopeMax", "slope_max"},
	{"SlopeBlend", "slope_blend"},
	{"CoverSlope", "cover_slope"},
	{"CoverStart", "cover_start"},
	{"CoverRange", "cover_range"},
	{"CoverPower", "cover_power"},
	{"CoverBlend", "cover_blend"},
}
local ScatterSurface = ffi.typeof([[struct {
	float world[16];
	uint32_t addresses[4];
	uint32_t info[4];
	float color[4];
	float layers[4];
	int32_t layer_textures[4];
	float layer_scales[4];
	float layer_detail[4];
	float layer_additive_detail[4];
	float slope_min[4];
	float slope_max[4];
	float slope_blend[4];
	float cover_slope[4];
	float cover_start[4];
	float cover_range[4];
	float cover_power[4];
	float cover_blend[4];
	int32_t blend[4];
	int32_t set[4];
	float params[4];
}]])
local ScatterPrototype = ffi.typeof([[struct {
	float placement[4];
	float cluster[4];
	float slope[4];
	float altitude[4];
	float scale[4];
	float sink[4];
	float color[4];
	float tint_a[4];
	float tint_b[4];
	float layers[4];
	float bounds[4];
	uint32_t info[4];
	uint32_t info2[4];
	uint32_t info3[4];
	uint32_t info4[4];
	float limits[4];
}]])
local DRAW_COMMAND_SIZE_SHADOW = 16
local ScatterBatch = ffi.typeof("struct { uint32_t index_count, first_index, prototype, double_sided; }")
local uint64_ptr = ffi.typeof("uint64_t *")
local int32_ptr = ffi.typeof("int32_t *")
local DRAW_COMMAND_SIZE = ffi.sizeof(vk.VkDrawIndexedIndirectCommand)
-- dispatch arguments, the job counter, then how many instances each prototype got
-- four counters for each prototype, its model, its billboard, and what casts shadows with its model and with its billboard
local ARGS_WORDS = 4 + 4 * MAX_PROTOTYPES
local ARGS_RESET = ffi.new("uint32_t[?]", ARGS_WORDS)
ARGS_RESET[1] = 1
ARGS_RESET[2] = 1
local buffers = nil

local function get_buffers()
	if buffers then return buffers end

	buffers = {
		surfaces = render.CreateBuffer{
			byte_size = ffi.sizeof(ScatterSurface) * scatter.MAX_SURFACES * scatter.SURFACE_RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter surfaces",
		},
		prototypes = render.CreateBuffer{
			byte_size = ffi.sizeof(ScatterPrototype) * MAX_PROTOTYPES,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter prototypes",
		},
		jobs = render.CreateBuffer{
			byte_size = 16 * scatter.MAX_JOBS,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "scatter jobs",
		},
		instances = render.CreateBuffer{
			byte_size = 64 * scatter.MAX_INSTANCES,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"device_local"},
			label = "scatter instances",
		},
		baked = render.CreateBuffer{
			byte_size = 64 * scatter.MAX_BAKED,
			buffer_usage = {"storage_buffer", "transfer_src"},
			memory_property = {"device_local"},
			label = "scatter baked",
		},
		unit_counts = render.CreateBuffer{
			byte_size = 4 * scatter.MAX_UNITS,
			buffer_usage = {"storage_buffer", "transfer_dst", "transfer_src"},
			memory_property = {"device_local"},
			label = "scatter unit counts",
		},
		unit_counts_readback = render.CreateBuffer{
			byte_size = 4 * scatter.MAX_UNITS * scatter.SURFACE_RING,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter unit counts readback",
		},
		units = render.CreateBuffer{
			byte_size = 16 * scatter.MAX_UNITS * scatter.SURFACE_RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter units",
		},
		blocks = render.CreateBuffer{
			byte_size = 8 * (scatter.MAX_BAKED / 64) * scatter.SURFACE_RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter blocks",
		},
		proxy_staging = render.CreateBuffer{
			byte_size = 64 * scatter.PROXY_MAX_INSTANCES * scatter.SURFACE_RING,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter proxy staging",
		},
		args = render.CreateBuffer{
			byte_size = ffi.sizeof(ARGS_RESET),
			buffer_usage = {"storage_buffer", "indirect_buffer", "transfer_dst", "transfer_src"},
			memory_property = {"device_local"},
			label = "scatter args",
		},
		demand = render.CreateBuffer{
			byte_size = 16 * MAX_PROTOTYPES * scatter.SURFACE_RING,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter demand",
		},
		batches = render.CreateBuffer{
			byte_size = ffi.sizeof(ScatterBatch) * scatter.MAX_BATCHES,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter batches",
		},
		commands = render.CreateBuffer{
			byte_size = DRAW_COMMAND_SIZE * scatter.MAX_BATCHES * 2,
			buffer_usage = {"storage_buffer", "indirect_buffer"},
			memory_property = {"device_local"},
			label = "scatter commands",
		},
		shadow_commands = render.CreateBuffer{
			byte_size = DRAW_COMMAND_SIZE_SHADOW * scatter.MAX_BATCHES,
			buffer_usage = {"storage_buffer", "indirect_buffer"},
			memory_property = {"device_local"},
			label = "scatter shadow commands",
		},
	}
	buffers.surface_data = ffi.cast(ffi.typeof("$ *", ScatterSurface), buffers.surfaces:Map())
	buffers.prototype_data = ffi.cast(ffi.typeof("$ *", ScatterPrototype), buffers.prototypes:Map())
	buffers.batch_data = ffi.cast(ffi.typeof("$ *", ScatterBatch), buffers.batches:Map())
	buffers.demand_data = ffi.cast("uint32_t *", buffers.demand:Map())
	buffers.unit_counts_data = ffi.cast("uint32_t *", buffers.unit_counts_readback:Map())
	buffers.proxy_data = ffi.cast("float *", buffers.proxy_staging:Map())
	buffers.units_data = ffi.cast("uint32_t *", buffers.units:Map())
	buffers.blocks_data = ffi.cast("uint32_t *", buffers.blocks:Map())
	return buffers
end

local function storage_buffer(binding_index, name, stage)
	return {
		type = "storage_buffer",
		binding_index = binding_index,
		stageFlags = stage,
		set_index = 0,
		args = function()
			local buffer = get_buffers()[name]
			return {buffer, buffer.size}
		end,
	}
end

local BINDING_SURFACES = 4
local BINDING_JOBS = 5
local BINDING_PROTOTYPES = 6
local BINDING_ARGS = 7
local BINDING_SCENE = 8
local BINDING_INSTANCES = 9
local BINDING_BATCHES = 10
local BINDING_COMMANDS = 11
local BINDING_SHADOW_COMMANDS = 12
local BINDING_OUTPUT = 13
local BINDING_UNITS = 14
local BINDING_BLOCKS = 15
local BINDING_UNIT_COUNTS = 16
local RAY_QUERY = render.GetDevice().ray_query_supported
local COMMON_GLSL = glsl_common.GetNoiseGLSL() ..
glsl_common.GetLuminanceGLSL() .. [[
	#define SCATTER_TILE_CELLS ]] .. scatter.TILE_CELLS .. [[

	#define SCATTER_MAX_LEVEL ]] .. scatter.MAX_LEVEL .. [[

	#define SCATTER_MAX_JOBS ]] .. scatter.MAX_JOBS .. [[u
	#define SCATTER_JOB_ROW ]] .. scatter.JOB_ROW .. [[u
	#define SCATTER_TILE_GROUPS_PER_ROW ]] .. scatter.TILE_GROUPS_PER_ROW .. [[u

	struct ScatterSurface {
		mat4 world;
		// vertex buffer address, index buffer address (0 when not indexed)
		uvec4 addresses;
		// triangle count, 32 bit indices, albedo texture, layer mask texture
		uvec4 info;
		vec4 color;
		// how much each channel of the layer mask grows
		vec4 layers;
		// the layers' albedo textures and how the terrain applies them, see TerrainLayer* in material.lua
		ivec4 layer_textures;
		vec4 layer_scales;
		vec4 layer_detail;
		vec4 layer_additive_detail;
		// where the layers are by the slope and the height of the ground, see terrain_layer_rules.lua
		vec4 slope_min;
		vec4 slope_max;
		vec4 slope_blend;
		vec4 cover_slope;
		vec4 cover_start;
		vec4 cover_range;
		vec4 cover_power;
		vec4 cover_blend;
		// grows on the first texture of a displacement blend: 1 when the material blends two, and its blend modulate texture
		ivec4 blend;
		// first prototype, prototype count
		ivec4 set;
		// density multiplier
		vec4 params;
	};

	struct ScatterPrototype {
		// density, max distance, full density distance, how much the size grows as the density thins
		vec4 placement;
		// scale, amount, tint scale, tint amount
		vec4 cluster;
		// min, max, fade, align
		vec4 slope;
		// min, max, fade, tilt
		vec4 altitude;
		// scale min, max, height min, max
		vec4 scale;
		// sink min, max, yaw
		vec4 sink;
		// surface, saturation, brightness, variation
		vec4 color;
		vec4 tint_a;
		vec4 tint_b;
		// how much each channel of the layer mask grows it
		vec4 layers;
		// radius, height, billboard distance (0 for none), billboard fade
		vec4 bounds;
		// first instance, capacity, loaded, casts shadows
		uvec4 info;
		// first billboard instance, billboard capacity
		uvec4 info2;
		// first shadow instance, shadow capacity
		uvec4 info3;
		// first instance of the billboard that casts shadows, its capacity
		uvec4 info4;
		// unused, animation distance, footprint to conform to the ground with (0 for not), the share of align left on steep slopes
		vec4 limits;
	};

	// the counters of a prototype: its model, its billboard, what casts shadows with its model and with its billboard
	uint scatter_counter(uint proto_index, uint kind) {
		return proto_index * 4u + kind;
	}

	uint scatter_pcg(uint v) {
		uint state = v * 747796405u + 2891336453u;
		uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
		return (word >> 22u) ^ word;
	}

	uint scatter_hash2(ivec2 c) {
		return scatter_pcg(uint(c.x) ^ scatter_pcg(uint(c.y) + 0x9e3779b9u));
	}

	// non harmonic octaves so the pattern never visibly repeats
	float scatter_fbm(vec2 p) {
		return value_noise2(p) * 0.55 +
			value_noise2(p * 2.13 + vec2(17.1, -3.7)) * 0.3 +
			value_noise2(p * 4.37 + vec2(-9.3, 21.4)) * 0.15;
	}

	// 1 inside [lo, hi], falling to 0 over fade outside of it
	float scatter_range(float x, float lo, float hi, float fade) {
		if (fade <= 0.0) return x >= lo && x <= hi ? 1.0 : 0.0;

		return smoothstep(lo - fade, lo, x) * (1.0 - smoothstep(hi, hi + fade, x));
	}

	// how far a cell's point may be moved off its corner, in cells at most 2^level. the levels are what thins
	// a field out with distance, but a sparse prototype (cells of meters) has no use for them, and the further an
	// instance can move off its cell the more cells a triangle has to look at to know it has none
	int scatter_max_level(float cell_size) {
		return cell_size > 2.0 ? 0 : (cell_size > 0.7 ? 2 : SCATTER_MAX_LEVEL);
	}

	// the point of a cell, its priority (the cell is kept when it is under the density), and the hash the rest of
	// its random numbers come from. every prototype has a stream of its own, or two of them would grow in the same places
	vec2 scatter_cell_point(ivec2 cell, uint proto_index, float cell_size, int max_level, out float priority, out uint h) {
		int lx = cell.x == 0 ? max_level : findLSB(cell.x);
		int lz = cell.y == 0 ? max_level : findLSB(cell.y);
		int cell_level = min(min(lx, lz), max_level);
		h = scatter_hash2(cell) ^ scatter_pcg(proto_index + 0x51ed270bu);
		float level_scale = exp2(-2.0 * float(cell_level + 1));
		priority = cell_level == max_level ?
			pcg_unorm(h) * level_scale * 4.0 :
			level_scale * (1.0 + 3.0 * pcg_unorm(h));
		h = scatter_pcg(h);
		vec2 jitter = vec2(pcg_unorm(h), pcg_unorm(scatter_pcg(h ^ 0x68bc21ebu)));
		return (vec2(cell) + jitter * float(1 << cell_level)) * cell_size;
	}

	// the density that is left at a distance, 1 up to the full density distance and then thinning
	float scatter_keep(ScatterPrototype proto, float d) {
		float r = proto.placement.z / max(d, 0.001);
		return min(r * r, 1.0) * (1.0 - smoothstep(proto.placement.y * 0.7, proto.placement.y, d));
	}
]]
local PROTOTYPES_GLSL = [[
	layout(std430, set = 0, binding = ]] .. BINDING_PROTOTYPES .. [[) readonly buffer ScatterPrototypes {
		ScatterPrototype scatter_prototypes[];
	};
]]
local COMPUTE_GLSL = COMMON_GLSL .. PROTOTYPES_GLSL .. [[
	layout(std430, set = 0, binding = ]] .. BINDING_SURFACES .. [[) readonly buffer ScatterSurfaces {
		ScatterSurface scatter_surfaces[];
	};

	layout(buffer_reference, scalar) readonly buffer ScatterVertexData {
		float v[];
	};

	layout(buffer_reference, scalar) readonly buffer ScatterIndexData {
		uint i[];
	};

	layout(std430, set = 0, binding = ]] .. BINDING_JOBS .. [[) buffer ScatterJobs {
		// surface | prototype << 12 | level << 24, triangle, tile x, tile z
		uvec4 scatter_jobs[];
	};

	layout(std430, set = 0, binding = ]] .. BINDING_ARGS .. [[) buffer ScatterArgs {
		uint scatter_dispatch[3];
		uint scatter_job_counter;
		uint scatter_counts[];
	};

	uint scatter_index(ScatterSurface s, uint i) {
		uint64_t address = packUint2x32(s.addresses.zw);

		if (address == 0ul) return i;

		ScatterIndexData data = ScatterIndexData(address);

		if (s.info.y != 0u) return data.i[i];

		uint word = data.i[i >> 1];
		return (i & 1u) != 0u ? word >> 16 : word & 0xFFFFu;
	}

	struct ScatterTriangle {
		vec3 p0;
		vec3 p1;
		vec3 p2;
		vec3 n0;
		vec3 n1;
		vec3 n2;
		vec2 uv0;
		vec2 uv1;
		vec2 uv2;
		vec3 blend;
	};

	// polygon_3d's vertex: position, normal, uv, tangent, texture blend, color
	#define SCATTER_VERTEX_FLOATS 17u

	ScatterTriangle scatter_load_triangle(ScatterSurface s, uint tri) {
		ScatterVertexData data = ScatterVertexData(packUint2x32(s.addresses.xy));
		uint a = scatter_index(s, tri * 3u) * SCATTER_VERTEX_FLOATS;
		uint b = scatter_index(s, tri * 3u + 1u) * SCATTER_VERTEX_FLOATS;
		uint c = scatter_index(s, tri * 3u + 2u) * SCATTER_VERTEX_FLOATS;
		ScatterTriangle t;
		t.p0 = (s.world * vec4(data.v[a], data.v[a + 1u], data.v[a + 2u], 1.0)).xyz;
		t.p1 = (s.world * vec4(data.v[b], data.v[b + 1u], data.v[b + 2u], 1.0)).xyz;
		t.p2 = (s.world * vec4(data.v[c], data.v[c + 1u], data.v[c + 2u], 1.0)).xyz;
		t.n0 = normalize(mat3(s.world) * vec3(data.v[a + 3u], data.v[a + 4u], data.v[a + 5u]));
		t.n1 = normalize(mat3(s.world) * vec3(data.v[b + 3u], data.v[b + 4u], data.v[b + 5u]));
		t.n2 = normalize(mat3(s.world) * vec3(data.v[c + 3u], data.v[c + 4u], data.v[c + 5u]));
		t.uv0 = vec2(data.v[a + 6u], data.v[a + 7u]);
		t.uv1 = vec2(data.v[b + 6u], data.v[b + 7u]);
		t.uv2 = vec2(data.v[c + 6u], data.v[c + 7u]);
		t.blend = vec3(data.v[a + 12u], data.v[b + 12u], data.v[c + 12u]);
		return t;
	}

	// a surface with a layer mask (terrain splat weights) only grows where its layers are, and
	// blends the amount across the transitions to other layers
	]] .. terrain_layer_rules .. [[

	// the layers' rules (slope, cover) apply like they do to the terrain's own layers, with the ground's normal and height
	// at the point
	vec4 scatter_layer_weights(ScatterSurface s, int mask_texture, vec2 uv, vec3 normal, float height) {
		vec4 weights = max(textureLod(TEXTURE(mask_texture), uv, 0.0), vec4(0.0));
		float steepness = 1.0 - (normal.y * 0.5 + 0.5);
		return apply_terrain_layer_rules(weights, steepness, height, s.slope_min, s.slope_max, s.slope_blend, s.cover_slope, s.cover_start, s.cover_range, s.cover_power, s.cover_blend);
	}

	// how much of the surface's first texture shows at a point of a displacement blend, like get_texture_blend_uv in model_pipeline.lua
	float scatter_blend_amount(ScatterSurface s, vec2 uv, float blend) {
		if (s.blend.x == 0) return 1.0;

		if (s.blend.y >= 0) {
			vec2 modulate = textureLod(TEXTURE(s.blend.y), uv, 0.0).rg;
			blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
		}

		return 1.0 - smoothstep(0.1, 0.6, blend);
	}

	// the terrain's albedo under an instance from one layer, like get_terrain_layer_sample in model_pipeline.lua
	// but from a blurrier mip, since an instance covers more ground than a texel
	vec3 scatter_terrain_layer_albedo(ScatterSurface s, int layer, vec3 base, vec2 xz) {
		int tex = s.layer_textures[layer];

		if (tex < 0) return base;

		vec3 albedo = textureLod(TEXTURE(tex), xz / max(s.layer_scales[layer], 0.0001), 0.0).rgb;
		float detail = s.layer_detail[layer];

		if (detail <= 0.0) return albedo * base;

		float additive = s.layer_additive_detail[layer];

		if (additive > 0.0) {
			return pow(max(pow(base, vec3(1.0 / 2.2)) + (albedo - 0.5) * detail, vec3(0.0)), vec3(2.2)) * additive;
		}

		vec3 average = textureLod(TEXTURE(tex), vec2(0.5), 16.0).rgb;
		return base * mix(vec3(1.0), albedo / max(average, vec3(0.01)), detail);
	}

	// two vectors that with n make an orthonormal basis (Duff et al.)
	void scatter_basis(vec3 n, out vec3 b1, out vec3 b2) {
		float sign_z = n.z >= 0.0 ? 1.0 : -1.0;
		float a = -1.0 / (sign_z + n.z);
		float b = n.x * n.y * a;
		b1 = vec3(1.0 + sign_z * n.x * n.x * a, sign_z * b, -sign_z * n.x);
		b2 = vec3(b, sign_z + n.y * n.y * a, -n.y);
	}
]]
-- the bake passes work on one unit of a surface at a time
local bake_block = {
	{"surface_index", "int"},
	{"triangle_count", "int"},
	{"mask_texture", "int"},
	{"unit_slot", "int"},
	{"unit_offset", "int"},
	{"unit_capacity", "int"},
	{"unit_min", "vec2"},
	{"unit_max", "vec2"},
	{"band_distance", "float"},
}
local cull_block = {
	{"view_projection", "mat4"},
	{"camera_position", "vec3"},
	{"block_count", "int"},
	{"unit_base", "int"},
	{"block_base", "int"},
}

local function write_bake_block(self, block)
	block.surface_index = self.surface_index or 0
	block.triangle_count = self.triangle_count or 0
	block.mask_texture = self.mask_texture or -1
	block.unit_slot = self.unit_slot or 0
	block.unit_offset = self.unit_offset or 0
	block.unit_capacity = self.unit_capacity or 0
	block.unit_min[0] = self.unit_min_x or 0
	block.unit_min[1] = self.unit_min_z or 0
	block.unit_max[0] = self.unit_max_x or 0
	block.unit_max[1] = self.unit_max_z or 0
	block.band_distance = self.band_distance or 0
	return block
end

local function write_cull_block(self, block)
	local camera = render3d.GetCamera()
	local view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	view_projection:CopyToFloatPointer(block.view_projection)
	local position = camera:GetPosition()
	block.camera_position[0] = position.x
	block.camera_position[1] = position.y
	block.camera_position[2] = position.z
	block.block_count = self.block_count or 0
	block.unit_base = self.unit_base or 0
	block.block_base = self.block_base or 0
	return block
end

local compute_passes = nil

local function get_compute_passes()
	if compute_passes then return compute_passes end

	local descriptor_sets = {
		storage_buffer(BINDING_SURFACES, "surfaces", "compute"),
		storage_buffer(BINDING_JOBS, "jobs", "compute"),
		storage_buffer(BINDING_PROTOTYPES, "prototypes", "compute"),
		storage_buffer(BINDING_ARGS, "args", "compute"),
	}
	local instance_descriptor_sets = {unpack(descriptor_sets)}
	instance_descriptor_sets[#instance_descriptor_sets + 1] = storage_buffer(BINDING_INSTANCES, "baked", "compute")
	instance_descriptor_sets[#instance_descriptor_sets + 1] = storage_buffer(BINDING_UNIT_COUNTS, "unit_counts", "compute")

	if RAY_QUERY then
		instance_descriptor_sets[#instance_descriptor_sets + 1] = {
			type = "acceleration_structure_khr",
			binding_index = BINDING_SCENE,
			stageFlags = "compute",
			set_index = 0,
		}
	end

	compute_passes = {
		tiles = EasyPipeline.Compute{
			name = "scatter_tiles",
			DescriptorSetCount = 1,
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = descriptor_sets,
			block = bake_block,
			write = write_bake_block,
			shader = COMPUTE_GLSL .. [[
				shared uint scatter_hit;

				// a workgroup is a triangle, which its invocations share the tiles of. a big triangle covers
				// thousands of tiles, which one invocation would go through one after the other. the tiles
				// become jobs for the instance pass, one for each prototype of the surface's set
				void main() {
					uint tri = gl_WorkGroupID.y * SCATTER_TILE_GROUPS_PER_ROW + gl_WorkGroupID.x;

					if (tri >= uint(compute.triangle_count)) return;

					uint surface_index = uint(compute.surface_index);
					ScatterSurface s = scatter_surfaces[surface_index];
					ScatterTriangle t = scatter_load_triangle(s, tri);

					if (s.blend.x != 0 && s.blend.y < 0 && scatter_blend_amount(s, t.uv0, min(min(t.blend.x, t.blend.y), t.blend.z)) <= 0.0) return;

					bool masked = compute.mask_texture >= 0;

					// the skirts under terrain tiles are vertical strips that copy the edge vertices, normals included, so by
					// those they read as flat ground. no heightfield triangle is vertical, so by the face they are known
					if (masked) {
						vec3 face = cross(t.p1 - t.p0, t.p2 - t.p0);

						if (abs(face.y) <= 0.02 * length(face)) return;
					}

					vec4 weights[7];

					if (masked) {
						weights[0] = scatter_layer_weights(s, compute.mask_texture, t.uv0, t.n0, t.p0.y);
						weights[1] = scatter_layer_weights(s, compute.mask_texture, t.uv1, t.n1, t.p1.y);
						weights[2] = scatter_layer_weights(s, compute.mask_texture, t.uv2, t.n2, t.p2.y);
						weights[3] = scatter_layer_weights(s, compute.mask_texture, (t.uv0 + t.uv1 + t.uv2) / 3.0, normalize(t.n0 + t.n1 + t.n2), (t.p0.y + t.p1.y + t.p2.y) / 3.0);
						weights[4] = scatter_layer_weights(s, compute.mask_texture, (t.uv0 + t.uv1) * 0.5, normalize(t.n0 + t.n1), (t.p0.y + t.p1.y) * 0.5);
						weights[5] = scatter_layer_weights(s, compute.mask_texture, (t.uv1 + t.uv2) * 0.5, normalize(t.n1 + t.n2), (t.p1.y + t.p2.y) * 0.5);
						weights[6] = scatter_layer_weights(s, compute.mask_texture, (t.uv2 + t.uv0) * 0.5, normalize(t.n2 + t.n0), (t.p2.y + t.p0.y) * 0.5);
					}

					// the flattest and the steepest the triangle gets
					float flattest = acos(clamp(max(max(t.n0.y, t.n1.y), t.n2.y), -1.0, 1.0));
					float steepest = acos(clamp(min(min(t.n0.y, t.n1.y), t.n2.y), -1.0, 1.0));
					vec3 bmin = min(min(t.p0, t.p1), t.p2);
					vec3 bmax = max(max(t.p0, t.p1), t.p2);

					for (int p = 0; p < s.set.y; p++) {
						uint proto_index = uint(s.set.x + p);
						ScatterPrototype proto = scatter_prototypes[proto_index];

						if (proto.info.z == 0u) continue;

						if (flattest > proto.slope.y + proto.slope.z || steepest < proto.slope.x - proto.slope.z) continue;

						if (bmax.y < proto.altitude.x - proto.altitude.z || bmin.y > proto.altitude.y + proto.altitude.z) continue;

						if (masked) {
							vec4 amounts = s.layers * proto.layers;
							float amount = 0.0;

							for (int i = 0; i < 7; i++) {
								amount = max(amount, dot(weights[i], amounts));
							}

							if (amount <= 0.0) continue;
						}

						float cell = 1.0 / sqrt(proto.placement.x * s.params.x);
						float tile_size = cell * float(SCATTER_TILE_CELLS);
						int max_level = scatter_max_level(cell);
						// instances jitter up to 2^max_level cells past their cell's
						// corner, so cells that far before the triangle can land in it
						float reach = cell * float(1 << max_level);
						// what the unit is baked for: every instance that any distance in its band keeps
						float keep = scatter_keep(proto, compute.band_distance);

						if (keep <= 0.0) continue;

						vec2 lo = max(bmin.xz - reach, compute.unit_min);
						vec2 hi = min(bmax.xz, compute.unit_max);

						if (any(greaterThan(lo, hi))) continue;

						// a triangle of a sparse prototype mostly has no cell point in it, and a job for each would
						// fill the job buffer, so the cells a point can come from are looked at first. the whole
						// workgroup is here or none of it is, so the barriers are fine
						if (max_level == 0) {
							vec2 a = t.p0.xz;
							vec2 e0 = t.p1.xz - a;
							vec2 e1 = t.p2.xz - a;
							float det = e0.x * e1.y - e1.x * e0.y;

							if (abs(det) < 1e-10) continue;

							barrier();

							if (gl_LocalInvocationID.x == 0u) scatter_hit = 0u;

							barrier();
							ivec2 c0 = ivec2(floor(max(bmin.xz, compute.unit_min) / cell));
							ivec2 c1 = ivec2(floor(min(bmax.xz, compute.unit_max) / cell));
							int cell_width = c1.x - c0.x + 1;
							int cell_count = (c1.y - c0.y + 1) * cell_width;

							for (int n = int(gl_LocalInvocationID.x); n < cell_count; n += int(gl_WorkGroupSize.x)) {
								float candidate_priority;
								uint candidate_hash;
								vec2 q = scatter_cell_point(c0 + ivec2(n % cell_width, n / cell_width), proto_index, cell, 0, candidate_priority, candidate_hash) - a;
								float w1 = (q.x * e1.y - e1.x * q.y) / det;
								float w2 = (e0.x * q.y - q.x * e0.y) / det;

								if (w1 >= 0.0 && w2 >= 0.0 && w1 + w2 <= 1.0) atomicOr(scatter_hit, 1u);
							}

							barrier();

							if (scatter_hit == 0u) continue;
						}

						ivec2 t0 = ivec2(floor(lo / tile_size));
						ivec2 t1 = ivec2(floor(hi / tile_size));
						int level = min(int(floor(0.5 * log2(1.0 / keep))), max_level);
						int width = t1.x - t0.x + 1;
						int count = (t1.y - t0.y + 1) * width;

						for (int n = int(gl_LocalInvocationID.x); n < count; n += int(gl_WorkGroupSize.x)) {
							int x = t0.x + n % width;
							int z = t0.y + n / width;
							uint slot = atomicAdd(scatter_job_counter, 1u);

							if (slot >= SCATTER_MAX_JOBS) break;

							scatter_jobs[slot] = uvec4(surface_index | (proto_index << 12) | (uint(level) << 24), tri, uint(x), uint(z));
							atomicMax(scatter_dispatch[0], min(slot + 1u, SCATTER_JOB_ROW));
							atomicMax(scatter_dispatch[1], slot / SCATTER_JOB_ROW + 1u);
						}
					}
				}
			]],
		},
		instances = EasyPipeline.Compute{
			name = "scatter_instances",
			DescriptorSetCount = render.GetSwapchainImageCount(),
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = instance_descriptor_sets,
			block = bake_block,
			write = write_bake_block,
			shader = (
					RAY_QUERY and
					[[
				#extension GL_EXT_ray_query : require
				layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT scatter_scene;
			]] or
					""
				) .. COMPUTE_GLSL .. [[
				// what is baked of a unit stays where it is until the unit is baked again. the instance matrix has
				// the number a cell needs the density to be over to exist in the bottom row, with the tint and the prototype
				layout(std430, set = 0, binding = ]] .. BINDING_INSTANCES .. [[) writeonly buffer ScatterBaked {
					mat4 scatter_baked[];
				};

				layout(std430, set = 0, binding = ]] .. BINDING_UNIT_COUNTS .. [[) buffer ScatterUnitCounts {
					uint scatter_unit_counts[];
				};

				void main() {
					uint job_index = gl_WorkGroupID.y * SCATTER_JOB_ROW + gl_WorkGroupID.x;

					if (job_index >= min(scatter_job_counter, SCATTER_MAX_JOBS)) return;

					uvec4 job = scatter_jobs[job_index];
					uint surface_index = job.x & 0xFFFu;
					uint proto_index = (job.x >> 12) & 0xFFFu;
					int level = int(job.x >> 24);
					ScatterSurface s = scatter_surfaces[surface_index];
					ScatterPrototype proto = scatter_prototypes[proto_index];
					ScatterTriangle t = scatter_load_triangle(s, job.y);
					ivec2 tile = ivec2(job.zw);
					float cell_size = 1.0 / sqrt(proto.placement.x * s.params.x);
					vec2 a = t.p0.xz;
					vec2 e0 = t.p1.xz - a;
					vec2 e1 = t.p2.xz - a;
					float det = e0.x * e1.y - e1.x * e0.y;

					if (abs(det) < 1e-10) return;

					float inv_det = 1.0 / det;
					int max_level = scatter_max_level(cell_size);
					int step_cells = 1 << level;
					int per_axis = SCATTER_TILE_CELLS >> level;
					int albedo_texture = int(s.info.z);
					int mask_texture = int(s.info.w);
					vec4 layer_amounts = s.layers * proto.layers;

					for (int n = int(gl_LocalInvocationID.x); n < per_axis * per_axis; n += 64) {
						ivec2 cell = tile * SCATTER_TILE_CELLS + ivec2(n % per_axis, n / per_axis) * step_cells;
						float priority;
						uint h;
						vec2 xz = scatter_cell_point(cell, proto_index, cell_size, max_level, priority, h);

						// a point belongs to the unit it is in
						if (any(lessThan(xz, compute.unit_min)) || any(greaterThanEqual(xz, compute.unit_max))) continue;
						vec2 q = xz - a;
						float w1 = (q.x * e1.y - e1.x * q.y) * inv_det;
						float w2 = (e0.x * q.y - q.x * e0.y) * inv_det;
						float w0 = 1.0 - w1 - w2;

						if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) continue;

						vec3 root = t.p0 * w0 + t.p1 * w1 + t.p2 * w2;
						float lod_keep = scatter_keep(proto, compute.band_distance);

						// the cheapest reasons to drop a cell first, the texture reads come last
						if (lod_keep <= 0.0 || priority >= lod_keep) continue;

						// low frequency patches, so a uniform density doesn't read as a carpet
						float patches = scatter_fbm(xz / max(proto.cluster.x, 0.01));
						float clustering = mix(1.0, smoothstep(0.25, 0.65, patches), proto.cluster.y);

						if (priority >= lod_keep * clustering) continue;

						vec3 ground_normal = normalize(t.n0 * w0 + t.n1 * w1 + t.n2 * w2);
						float slope = acos(clamp(ground_normal.y, -1.0, 1.0));
						float terrain_amount = scatter_range(slope, proto.slope.x, proto.slope.y, proto.slope.z) *
							scatter_range(root.y, proto.altitude.x, proto.altitude.y, proto.altitude.z);

						if (priority >= lod_keep * clustering * terrain_amount) continue;

						vec2 uv = t.uv0 * w0 + t.uv1 * w1 + t.uv2 * w2;
						vec4 layer_weights = mask_texture >= 0 ? scatter_layer_weights(s, mask_texture, uv, ground_normal, root.y) : vec4(0.0);
						float amount = (mask_texture >= 0 ? dot(layer_weights, layer_amounts) : 1.0) * scatter_blend_amount(s, uv, dot(t.blend, vec3(w0, w1, w2)));
						float ground_amount = clustering * terrain_amount * amount;
						float keep = lod_keep * ground_amount;

						if (priority >= keep) continue;

						h = scatter_pcg(h + 0x2545f491u);
						float r_size = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_stretch = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_yaw = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_tilt = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_tilt_direction = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_sink = pcg_unorm(h);
						h = scatter_pcg(h);
						float r_variation = pcg_unorm(h);
						float size = mix(proto.scale.x, proto.scale.y, r_size);
						float size_y = size * mix(proto.scale.z, proto.scale.w, r_stretch);

						]] .. (
					RAY_QUERY and
					[[
						// a brush over the ground, like a road laid on a displacement, would have instances poking through it.
						// not for terrain (a layer mask), whose tiles of different levels of detail overlap while they are
						// swapped, and would cover each other
						if (mask_texture < 0) {
							rayQueryEXT cover;
							rayQueryInitializeEXT(cover, scatter_scene, gl_RayFlagsOpaqueEXT, 0xFF, root + vec3(0.0, 0.005, 0.0), 0.0, vec3(0.0, 1.0, 0.0), proto.bounds.y * size_y);

							while (rayQueryProceedEXT(cover)) {}

							if (rayQueryGetIntersectionTypeEXT(cover, true) != gl_RayQueryCommittedIntersectionNoneEXT) continue;
						}
						]] or
					""
				) .. [[

						vec3 up = normalize(mix(vec3(0.0, 1.0, 0.0), ground_normal, proto.slope.w * mix(1.0, proto.limits.w, smoothstep(0.5236, 0.9599, slope))));
						vec3 b1, b2;
						scatter_basis(up, b1, b2);
						float tilt_direction = r_tilt_direction * 6.2831853;
						up = normalize(up + (b1 * cos(tilt_direction) + b2 * sin(tilt_direction)) * tan(proto.altitude.w * r_tilt));
						scatter_basis(up, b1, b2);
						float yaw = r_yaw * proto.sink.z;
						vec3 x_axis = b1 * cos(yaw) + b2 * sin(yaw);
						vec3 z_axis = cross(x_axis, up);
						vec3 position = root - up * mix(proto.sink.x, proto.sink.y, r_sink) * size;
						// 1.0 is what a scene instance has in the corner of its matrix. a conforming one has the sign bit set, the
						// radius it was measured at (6 bits, log scale) and the height of the ground over the plane through its root
						// at the four edges of the footprint (5 bits each, in radii and along its up axis), see the vertex stage
						float conform_word = 1.0;

						]] .. (
					RAY_QUERY and
					[[
						if (proto.limits.z > 0.0) {
							uint radius_code = uint(clamp(round(log(proto.limits.z / 0.02) / log(1.12)), 0.0, 63.0));
							float radius = 0.02 * pow(1.12, float(radius_code));
							float reach = radius * size;
							float window = reach * 1.5;
							vec3 sample_directions[4] = vec3[4](x_axis, -x_axis, z_axis, -z_axis);
							uint offsets = 0u;
							float worst = 0.0;

							for (int i = 0; i < 4; i++) {
								vec3 edge = root + sample_directions[i] * reach;
								rayQueryEXT ground;
								rayQueryInitializeEXT(ground, scatter_scene, gl_RayFlagsOpaqueEXT, 0xFF, edge + up * window, 0.0, -up, window * 2.0);

								while (rayQueryProceedEXT(ground)) {}

								float height = 0.0;

								if (rayQueryGetIntersectionTypeEXT(ground, true) != gl_RayQueryCommittedIntersectionNoneEXT) {
									height = window - rayQueryGetIntersectionTEXT(ground, true);
								}

								worst = max(worst, abs(height) / (radius * size_y));
								offsets |= uint(int(clamp(round(height / (radius * size_y) * 15.0), -15.0, 15.0)) + 16) << uint(i * 5);
							}

							// ground that far off under the footprint (the foot of a cliff, a rock) is more than a patch bends to, it
							// would arch over it instead
							if (worst < 0.6) conform_word = uintBitsToFloat(0x80000000u | (radius_code << 24) | offsets);
						}
						]] or
					""
				) .. [[

						vec3 color = albedo_texture >= 0 ? textureLod(TEXTURE(albedo_texture), uv, 3.0).rgb : vec3(1.0);

						if (mask_texture >= 0) {
							vec3 ground = vec3(0.0);

							for (int i = 0; i < 4; i++) {
								if (layer_weights[i] > 0.001) {
									ground += scatter_terrain_layer_albedo(s, i, color, xz) * layer_weights[i];
								}
							}

							color = ground;
						}

						color *= s.color.rgb;
						// the ground's color without its brightness, pushed away from grey, and some of the brightness back
						float color_luma = luminance(color);
						vec3 chroma = color_luma > 0.0001 ? color / color_luma : vec3(1.0);
						chroma = max(mix(vec3(1.0), chroma, proto.color.y), vec3(0.0));
						vec3 tint = mix(vec3(1.0), chroma * mix(1.0, clamp(color_luma / 0.25, 0.4, 2.0), proto.color.z), proto.color.x);
						float patch_mix = smoothstep(0.35, 0.65, scatter_fbm(xz / max(proto.cluster.z, 0.01) + vec2(3.1, 11.9)));
						tint *= mix(vec3(1.0), mix(proto.tint_a.rgb, proto.tint_b.rgb, patch_mix), proto.cluster.w);
						tint *= 1.0 + (r_variation * 2.0 - 1.0) * proto.color.w;
						uint tint_bits = packUnorm4x8(vec4(clamp(tint * 0.5, 0.0, 1.0), 1.0));

						// priority / ground_amount is what the density at the camera's distance has to be over for the instance
						// to be there, the frame's cull pass reads it from the matrix' bottom row
						uint slot = atomicAdd(scatter_unit_counts[uint(compute.unit_slot)], 1u);

						if (slot < uint(compute.unit_capacity)) {
							scatter_baked[uint(compute.unit_offset) + slot] = mat4(
								vec4(x_axis * size, priority / ground_amount),
								vec4(up * size_y, uintBitsToFloat(tint_bits)),
								vec4(z_axis * size, uintBitsToFloat(proto_index)),
								vec4(position, conform_word)
							);
						}
					}
				}
			]],
		},
		cull = EasyPipeline.Compute{
			name = "scatter_cull",
			DescriptorSetCount = 1,
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = {
				storage_buffer(BINDING_PROTOTYPES, "prototypes", "compute"),
				storage_buffer(BINDING_ARGS, "args", "compute"),
				storage_buffer(BINDING_INSTANCES, "baked", "compute"),
				storage_buffer(BINDING_OUTPUT, "instances", "compute"),
				storage_buffer(BINDING_UNITS, "units", "compute"),
				storage_buffer(BINDING_BLOCKS, "blocks", "compute"),
				storage_buffer(BINDING_UNIT_COUNTS, "unit_counts", "compute"),
			},
			block = cull_block,
			write = write_cull_block,
			shader = COMMON_GLSL .. PROTOTYPES_GLSL .. [[
				layout(std430, set = 0, binding = ]] .. BINDING_ARGS .. [[) buffer ScatterArgs {
					uint scatter_dispatch[3];
					uint scatter_job_counter;
					uint scatter_counts[];
				};

				layout(std430, set = 0, binding = ]] .. BINDING_INSTANCES .. [[) readonly buffer ScatterBaked {
					mat4 scatter_baked[];
				};

				layout(std430, set = 0, binding = ]] .. BINDING_OUTPUT .. [[) writeonly buffer ScatterOutput {
					mat4 scatter_output[];
				};

				// offset, capacity and the counter of a unit
				layout(std430, set = 0, binding = ]] .. BINDING_UNITS .. [[) readonly buffer ScatterUnits {
					uvec4 scatter_units[];
				};

				// the unit of a block of 64 instances, and which block of it
				layout(std430, set = 0, binding = ]] .. BINDING_BLOCKS .. [[) readonly buffer ScatterBlocks {
					uvec2 scatter_blocks[];
				};

				layout(std430, set = 0, binding = ]] .. BINDING_UNIT_COUNTS .. [[) readonly buffer ScatterUnitCounts {
					uint scatter_unit_counts[];
				};

	vec4 scatter_frustum_plane(int i) {
		mat4 m = compute.view_projection;
		vec4 w = vec4(m[0][3], m[1][3], m[2][3], m[3][3]);
		int axis = i >> 1;
		vec4 r = vec4(m[0][axis], m[1][axis], m[2][axis], m[3][axis]);
		return (i & 1) == 0 ? w + r : w - r;
	}

	bool scatter_box_visible(vec3 lo, vec3 hi) {
		for (int i = 0; i < 4; i++) {
			vec4 plane = scatter_frustum_plane(i);
			vec3 p = mix(lo, hi, step(0.0, plane.xyz));

			if (dot(plane.xyz, p) + plane.w < 0.0) return false;
		}

		return true;
	}

	bool scatter_sphere_visible(vec3 center, float radius) {
		for (int i = 0; i < 4; i++) {
			vec4 plane = scatter_frustum_plane(i);

			if (dot(plane.xyz, center) + plane.w < -radius * length(plane.xyz)) return false;
		}

		return true;
	}


				// every frame, what is baked is thinned by the distance, culled by the view and sorted into the regions
				// the draws read: a prototype's model, or its billboard, with the fade between them
				void main() {
					uint block = gl_WorkGroupID.x;

					if (block >= uint(compute.block_count)) return;

					uvec2 b = scatter_blocks[uint(compute.block_base) + block];
					uvec4 unit = scatter_units[uint(compute.unit_base) + b.x];
					uint i = b.y * 64u + gl_LocalInvocationID.x;

					if (i >= min(scatter_unit_counts[unit.z], unit.y)) return;

					mat4 world = scatter_baked[unit.x + i];
					float need = world[0][3];
					uint proto_index = floatBitsToUint(world[2][3]);
					ScatterPrototype proto = scatter_prototypes[proto_index];

					if (proto.info.z == 0u) return;

					vec3 position = world[3].xyz;
					float d = distance(position, compute.camera_position);
					float lod_keep = scatter_keep(proto, d);

					if (lod_keep <= need) return;

					// thinner with distance, so what is left is wider
					float widen = mix(1.0, clamp(inversesqrt(lod_keep), 1.0, 4.0), proto.placement.w);
					float size_xz = length(world[0].xyz) * widen;
					float size_y = length(world[1].xyz);
					world[0].xyz *= widen;
					world[2].xyz *= widen;
					// the vertex stage does not animate an instance that has this set
					world[2][3] = d > proto.limits.y ? 1.0 : 0.0;
					bool in_view = scatter_sphere_visible(position + vec3(0.0, proto.bounds.y * size_y * 0.5, 0.0), proto.bounds.x * max(size_xz, size_y));

					// only the thinning with distance fades instances, they come and go as the camera moves
					float lod_fade = lod_keep >= 0.999 ? 0.0 : 1.0 - clamp((lod_keep - need) / (lod_keep * 0.3), 0.0, 1.0);
					// the model gives way to the billboard over a band around the billboard's distance, the two dither
					// into each other with patterns that complement
					float switch_distance = proto.bounds.z;
					float band = proto.bounds.w;
					float blend = switch_distance > 0.0 ? clamp((d - switch_distance * (1.0 - band)) / (2.0 * switch_distance * band), 0.0, 1.0) : 0.0;

					// the shadow maps have their own list, of what is near enough, in view or not
					if (proto.info.w != 0u) {
						// the model up close, the billboard further out when there is one
						bool billboard_shadow = switch_distance > 0.0 && d >= switch_distance;
						uint slot = atomicAdd(scatter_counts[scatter_counter(proto_index, billboard_shadow ? 3u : 2u)], 1u);

						if (slot < (billboard_shadow ? proto.info4.y : proto.info3.y)) {
							world[0][3] = 0.0;
							scatter_output[(billboard_shadow ? proto.info4.x : proto.info3.x) + slot] = world;
						}
					}

					if (!in_view) return;

					// the fade and the tint are in the bottom row that the vertex stage reads them from
					if (switch_distance == 0.0 || blend < 1.0) {
						uint slot = atomicAdd(scatter_counts[scatter_counter(proto_index, 0u)], 1u);

						if (slot < proto.info.y) {
							world[0][3] = switch_distance > 0.0 ? blend : lod_fade;
							scatter_output[proto.info.x + slot] = world;
						}
					}

					if (switch_distance > 0.0 && blend > 0.0) {
						uint slot = atomicAdd(scatter_counts[scatter_counter(proto_index, 1u)], 1u);

						if (slot < proto.info2.y) {
							world[0][3] = blend < 1.0 ? blend - 1.0 : lod_fade;
							scatter_output[proto.info2.x + slot] = world;
						}
					}
				}
			]],
		},
		commands = EasyPipeline.Compute{
			name = "scatter_commands",
			DescriptorSetCount = 1,
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = {
				storage_buffer(BINDING_PROTOTYPES, "prototypes", "compute"),
				storage_buffer(BINDING_ARGS, "args", "compute"),
				storage_buffer(BINDING_BATCHES, "batches", "compute"),
				storage_buffer(BINDING_COMMANDS, "commands", "compute"),
				storage_buffer(BINDING_SHADOW_COMMANDS, "shadow_commands", "compute"),
			},
			block = {{"batch_count", "int"}},
			write = function(self, block)
				block.batch_count = self.batch_count
				return block
			end,
			shader = COMMON_GLSL .. PROTOTYPES_GLSL .. [[
				layout(std430, set = 0, binding = ]] .. BINDING_ARGS .. [[) readonly buffer ScatterArgs {
					uint scatter_dispatch[3];
					uint scatter_job_counter;
					uint scatter_counts[];
				};

				// index count, first index, prototype, double sided
				layout(std430, set = 0, binding = ]] .. BINDING_BATCHES .. [[) readonly buffer ScatterBatches {
					uvec4 scatter_batches[];
				};

				struct ScatterDrawCommand {
					uint index_count;
					uint instance_count;
					uint first_index;
					int vertex_offset;
					uint first_instance;
				};

				layout(std430, set = 0, binding = ]] .. BINDING_COMMANDS .. [[) writeonly buffer ScatterCommands {
					ScatterDrawCommand scatter_commands[];
				};

				// the shadow maps draw without indices through the index buffer's address, vertex count and all
				layout(std430, set = 0, binding = ]] .. BINDING_SHADOW_COMMANDS .. [[) writeonly buffer ScatterShadowCommands {
					uvec4 scatter_shadow_commands[];
				};

				// one draw for each batch, the single sided ones in the first half of the commands and the double
				// sided in the second, the other half's get no instances
				void main() {
					uint id = gl_GlobalInvocationID.x;
					uint batch_count = uint(compute.batch_count);

					if (id >= batch_count * 2u) return;

					uint batch = id % batch_count;
					uvec4 info = scatter_batches[batch];
					// the counter of a batch is its prototype's, or its billboard's
					ScatterPrototype proto = scatter_prototypes[info.z >> 1u];
					bool billboard = (info.z & 1u) != 0u;
					uint first = billboard ? proto.info2.x : proto.info.x;
					uint counter = scatter_counter(info.z >> 1u, info.z & 1u);
					uint count = min(scatter_counts[counter], billboard ? proto.info2.y : proto.info.y);

					if ((info.w != 0u) != (id >= batch_count)) count = 0u;

					scatter_commands[id] = ScatterDrawCommand(info.x, count, info.y, 0, first);

					if (id < batch_count) {
						uint shadow_count = 0u;

						if (proto.info.w != 0u) {
							shadow_count = billboard ?
								min(scatter_counts[scatter_counter(info.z >> 1u, 3u)], proto.info4.y) :
								min(scatter_counts[scatter_counter(info.z >> 1u, 2u)], proto.info3.y);
						}

						scatter_shadow_commands[id] = uvec4(info.x, shadow_count, 0u, billboard ? proto.info4.x : proto.info3.x);
					}
				}
			]],
		},
	}
	return compute_passes
end

local surfaces = {}
local surfaces_key = nil
local surface_count = 0

-- a component that is not shown yet (a terrain tile that waits for the one it replaces) can have its surfaces looked at
-- anyway: the units are baked and kept, but not drawn until the component is visible
scatter.preloaded = setmetatable({}, {__mode = "k"})
scatter.preload_version = 0
-- components that are about to be replaced (a terrain tile that is retiring): what they would grow is not worth baking
-- before what is wanted
scatter.retiring = setmetatable({}, {__mode = "k"})

function scatter.SetRetiring(component, retiring)
	scatter.retiring[component] = retiring or nil
end

function scatter.Preload(component)
	if scatter.preloaded[component] then return end

	scatter.preloaded[component] = true
	scatter.preload_version = scatter.preload_version + 1
end

local function collect_surfaces()
	local out = {}
	local have = {}

	for material, components in pairs(Visual.Library.GetSceneMaterialUsers()) do
		local set = material:GetScatterSet()

		if set then
			set:Use()

			for component in pairs(components) do
				for _, entry in ipairs(component:GetRenderEntries()) do
					if component:GetResolvedMaterial(entry) == material then
						have[entry] = true
						out[#out + 1] = {component = component, entry = entry, material = material, set = set}
					end
				end
			end
		end
	end

	for component in pairs(scatter.preloaded) do
		if component:IsValid() then
			for _, entry in ipairs(component:GetRenderEntries()) do
				local material = component:GetResolvedMaterial(entry)
				local set = material:GetScatterSet()

				if set and not have[entry] then
					set:Use()
					have[entry] = true
					out[#out + 1] = {component = component, entry = entry, material = material, set = set}
				end
			end
		end
	end

	return out
end

local function get_surfaces()
	local key = Visual.Library.GetSceneVersion() .. ":" .. Material.flags_generation .. ":" .. ScatterSet.version .. ":" .. scatter.preload_version

	if key ~= surfaces_key then
		surfaces = collect_surfaces()
		surfaces_key = key
	end

	return surfaces
end

local function write_surface(out, surface, pipeline)
	local component = surface.component
	local entry = surface.entry
	local material = surface.material
	local mesh = entry.polygon3d:GetMesh()
	local transform = entry.transform
	local world = transform and transform:GetWorldMatrix() or component:GetWorldMatrix()
	world:CopyToFloatPointer(out.world)
	local index_buffer = mesh.index_buffer
	ffi.cast(uint64_ptr, out.addresses)[0] = mesh:GetVertexBufferAddress()
	ffi.cast(uint64_ptr, out.addresses + 2)[0] = mesh:GetIndexBufferAddress()

	if index_buffer then
		out.info[0] = index_buffer:GetIndexCount() / 3
		out.info[1] = index_buffer:GetIndexType() == "uint32" and 1 or 0
	else
		out.info[0] = mesh:GetVertexCount() / 3
		out.info[1] = 0
	end

	ffi.cast(int32_ptr, out.info + 2)[0] = pipeline:GetTextureIndex(material:GetAlbedoTexture())
	ffi.cast(int32_ptr, out.info + 3)[0] = pipeline:GetTextureIndex(material:GetTerrainMaterialTexture())
	local color = material:GetColorMultiplier()
	out.color[0] = color.r
	out.color[1] = color.g
	out.color[2] = color.b
	out.color[3] = color.a
	local layers = material:GetTerrainLayerScatter()
	out.layers[0] = layers.r
	out.layers[1] = layers.g
	out.layers[2] = layers.b
	out.layers[3] = layers.a
	out.layer_textures[0] = pipeline:GetTextureIndex(material:GetTerrainLayer1Texture())
	out.layer_textures[1] = pipeline:GetTextureIndex(material:GetTerrainLayer2Texture())
	out.layer_textures[2] = pipeline:GetTextureIndex(material:GetTerrainLayer3Texture())
	out.layer_textures[3] = pipeline:GetTextureIndex(material:GetTerrainLayer4Texture())
	local scales = material:GetTerrainLayerScales()
	out.layer_scales[0] = scales.r
	out.layer_scales[1] = scales.g
	out.layer_scales[2] = scales.b
	out.layer_scales[3] = scales.a
	local detail = material:GetTerrainLayerDetailStrength()
	out.layer_detail[0] = detail.r
	out.layer_detail[1] = detail.g
	out.layer_detail[2] = detail.b
	out.layer_detail[3] = detail.a
	local additive_detail = material:GetTerrainLayerAdditiveDetail()
	out.layer_additive_detail[0] = additive_detail.r
	out.layer_additive_detail[1] = additive_detail.g
	out.layer_additive_detail[2] = additive_detail.b
	out.layer_additive_detail[3] = additive_detail.a
	for _, rule in ipairs(LAYER_RULES) do
		local value = material["GetTerrainLayer" .. rule[1]](material)
		out[rule[2]][0] = value.r
		out[rule[2]][1] = value.g
		out[rule[2]][2] = value.b
		out[rule[2]][3] = value.a
	end

	local albedo2 = material:GetAlbedo2Texture()
	out.blend[0] = albedo2 and not Material.IsGrassTexture(albedo2) and 1 or 0
	out.blend[1] = pipeline:GetTextureIndex(material:GetBlendTexture())
	out.set[0] = surface.set.protos[1].index
	out.set[1] = #surface.set.protos
	out.params[0] = material:GetScatterDensity()
end

local function write_prototype(out, proto, instance_base, far_base, shadow_base, shadow_billboard_base)
	out.placement[0] = proto.density * proto.density_multiplier
	out.placement[1] = proto.max_distance * proto.distance_multiplier
	out.placement[2] = proto.full_density_distance * proto.distance_multiplier
	out.placement[3] = proto.distance_scale
	out.cluster[0] = proto.cluster_scale
	out.cluster[1] = proto.cluster_amount
	out.cluster[2] = proto.tint_scale
	out.cluster[3] = proto.tint_amount
	out.slope[0] = proto.slope_min
	out.slope[1] = proto.slope_max
	out.slope[2] = proto.slope_fade
	out.slope[3] = proto.align
	out.altitude[0] = proto.altitude_min
	out.altitude[1] = proto.altitude_max
	out.altitude[2] = proto.altitude_fade
	out.altitude[3] = proto.tilt
	out.scale[0] = proto.scale_min
	out.scale[1] = proto.scale_max
	out.scale[2] = proto.height_min
	out.scale[3] = proto.height_max
	out.sink[0] = proto.sink_min
	out.sink[1] = proto.sink_max
	out.sink[2] = proto.yaw
	out.color[0] = proto.color_surface
	out.color[1] = proto.color_saturation
	out.color[2] = proto.color_brightness
	out.color[3] = proto.color_variation

	for i = 0, 2 do
		out.tint_a[i] = proto.tint_a[i + 1]
		out.tint_b[i] = proto.tint_b[i + 1]
	end

	for i = 0, 3 do
		out.layers[i] = proto.layers[i + 1]
	end

	out.bounds[0] = proto.radius or 0
	out.bounds[1] = proto.height or 0
	out.info[0] = instance_base
	out.info[1] = proto.room
	out.bounds[2] = proto.sized_switch
	out.bounds[3] = proto.billboard_fade
	out.info2[0] = far_base
	out.info2[1] = proto.far_room
	out.info3[0] = shadow_base
	out.info3[1] = proto.shadow_room
	out.info4[0] = shadow_billboard_base
	out.info4[1] = proto.shadow_billboard_room
	out.limits[1] = proto.animation_distance
	out.limits[3] = proto.align_steep
	-- the footprint is measured when the model has loaded
	out.limits[2] = RAY_QUERY and proto.conform and proto.state == "ready" and proto.footprint > 0.02 and proto.footprint or 0
	out.info[2] = proto.state == "ready" and 1 or 0
	out.info[3] = proto.shadow and 1 or 0
end

-- what the draws are made of, rebuilt when a prototype is added or its model arrives
local draw_batches = {}
local batch_table = nil
local batch_serial = 0
local draw_version = nil
local first_commands_frame = nil
local instance_bases = {}
local far_bases = {}
local shadow_bases = {}
local shadow_billboard_bases = {}
local layout_dirty = false
local BufferCopy = ffi.typeof("$[1]", vk.VkBufferCopy)
local demand_copy = BufferCopy()
local demand_versions = {}

-- where a prototype's model gives way to its billboard, 0 for never: when it has one that is baked, the pvar
-- allows it and it is nearer than the end of the prototype
local function get_switch(proto)
	if not (billboards_enabled:Get() and proto.billboard_part) then return 0 end

	return math.min(
		proto.billboard_distance * billboard_scale:Get() * proto.distance_multiplier,
		proto.max_distance * proto.distance_multiplier * 0.95
	)
end

-- how many instances of a prototype are about to be in view between two distances, from its rules: the density
-- over the ground that is left after the thinning with distance and the clusters, the part of the circle that is in
-- view (all of it for what casts shadows) and a margin. the gpu's own counts correct it from then on
local function estimate_room(proto, from, to, view)
	local set = proto.set
	local far = proto.max_distance * proto.distance_multiplier
	local full = proto.full_density_distance * proto.distance_multiplier
	local steps = 64
	local area = 0

	for i = 1, steps do
		local d = from + (i - 0.5) / steps * (to - from)
		local ratio = full / d
		local fade = math.clamp((d - far * 0.7) / (far * 0.3), 0, 1)
		area = area + math.min(ratio * ratio, 1) * (1 - fade * fade * (3 - 2 * fade)) * 2 * math.pi * d * (to - from) / steps
	end

	local count = area * view * proto.density * proto.density_multiplier * (1 - 0.5 * proto.cluster_amount)
	return math.max(math.ceil(count * scatter.GROW_MARGIN), scatter.MIN_ROOM)
end

local function size_prototype(proto)
	local set = proto.set
	local far = proto.max_distance * proto.distance_multiplier
	local switch = get_switch(proto)
	proto.sized_density = proto.density_multiplier
	proto.sized_distance = proto.distance_multiplier
	proto.sized_scale = billboard_scale:Get()
	proto.sized_switch = switch
	-- the model reaches a little past the billboard's distance, and the billboard from a little before it
	local model_end = switch > 0 and math.min(switch * (1 + proto.billboard_fade), far) or far

	if proto.max_instances then
		proto.capacity = proto.max_instances
	else
		proto.capacity = estimate_room(proto, 0, model_end, proto.shadow and 1 or 0.5)
		proto.peak = proto.capacity / scatter.GROW_MARGIN
	end

	proto.far_capacity = scatter.MIN_ROOM

	if switch > 0 then
		proto.far_capacity = estimate_room(proto, switch * (1 - proto.billboard_fade), far, 0.5)
	end

	proto.far_peak = proto.far_capacity / scatter.GROW_MARGIN
	proto.shadow_capacity = scatter.MIN_ROOM

	if proto.shadow then
		proto.shadow_capacity = estimate_room(proto, 0, switch > 0 and switch or far, 1)
	end

	proto.shadow_peak = proto.shadow_capacity / scatter.GROW_MARGIN
	proto.shadow_billboard_capacity = scatter.MIN_ROOM

	if proto.shadow and switch > 0 then
		proto.shadow_billboard_capacity = estimate_room(proto, switch, far, 1)
	end

	proto.shadow_billboard_peak = proto.shadow_billboard_capacity / scatter.GROW_MARGIN
	layout_dirty = true
end

-- the prototypes' room one after the other in the instance buffer, a model's and then its billboard's. when they want
-- more than there is the ones that are not held fixed are scaled down together
local function assign_bases()
	local protos = ScatterSet.GetPrototypes()
	local fixed, dynamic = 0, 0

	for _, proto in ipairs(protos) do
		dynamic = dynamic + proto.far_capacity + proto.shadow_capacity + proto.shadow_billboard_capacity

		if proto.max_instances then
			fixed = fixed + proto.capacity
		else
			dynamic = dynamic + proto.capacity
		end
	end

	local scale = dynamic > 0 and math.min((scatter.MAX_INSTANCES - fixed) / dynamic, 1) or 1
	assert(scale > 0, "the fixed scatter prototypes alone want more instances than the " .. scatter.MAX_INSTANCES .. " there is room for")
	local total = 0

	for i, proto in ipairs(protos) do
		proto.room = proto.max_instances and proto.capacity or math.max(math.floor(proto.capacity * scale), 1)
		proto.far_room = math.max(math.floor(proto.far_capacity * scale), 1)
		proto.shadow_room = math.max(math.floor(proto.shadow_capacity * scale), 1)
		instance_bases[i] = total
		far_bases[i] = total + proto.room
		proto.shadow_billboard_room = math.max(math.floor(proto.shadow_billboard_capacity * scale), 1)
		shadow_bases[i] = far_bases[i] + proto.far_room
		shadow_billboard_bases[i] = shadow_bases[i] + proto.shadow_room
		total = shadow_billboard_bases[i] + proto.shadow_billboard_room
	end

	layout_dirty = false
end

-- the counters the gpu counted past the room with, from the frame this slot was last written. a prototype that
-- peaked above its room grows, one that has been far under it for a long while shrinks
local function adjust_rooms(slot)
	if demand_versions[slot] ~= draw_version then return end

	local b = get_buffers()
	local counts = b.demand_data + slot * MAX_PROTOTYPES * 4

	for _, proto in ipairs(ScatterSet.GetPrototypes()) do
		if not proto.max_instances then
			proto.peak = math.max(counts[proto.index * 4], proto.peak * 0.995)
			local target = math.max(math.ceil(proto.peak * scatter.GROW_MARGIN), scatter.MIN_ROOM)

			if target > proto.capacity or target * 3 < proto.capacity then
				proto.capacity = target
				layout_dirty = true
			end
		end

		proto.far_peak = math.max(counts[proto.index * 4 + 1], proto.far_peak * 0.995)
		local target = math.max(math.ceil(proto.far_peak * scatter.GROW_MARGIN), scatter.MIN_ROOM)

		if target > proto.far_capacity or target * 3 < proto.far_capacity then
			proto.far_capacity = target
			layout_dirty = true
		end

		proto.shadow_peak = math.max(counts[proto.index * 4 + 2], proto.shadow_peak * 0.995)
		target = math.max(math.ceil(proto.shadow_peak * scatter.GROW_MARGIN), scatter.MIN_ROOM)

		if target > proto.shadow_capacity or target * 3 < proto.shadow_capacity then
			proto.shadow_capacity = target
			layout_dirty = true
		end

		proto.shadow_billboard_peak = math.max(counts[proto.index * 4 + 3], proto.shadow_billboard_peak * 0.995)
		target = math.max(math.ceil(proto.shadow_billboard_peak * scatter.GROW_MARGIN), scatter.MIN_ROOM)

		if target > proto.shadow_billboard_capacity or target * 3 < proto.shadow_billboard_capacity then
			proto.shadow_billboard_capacity = target
			layout_dirty = true
		end
	end
end

local function rebuild_draws()
	local b = get_buffers()
	local protos = ScatterSet.GetPrototypes()
	list.clear(draw_batches)

	for _, proto in ipairs(protos) do
		if not proto.capacity then size_prototype(proto) end

		if proto.state == "ready" then
			for _, part in ipairs(proto.parts) do
				assert(#draw_batches < scatter.MAX_BATCHES, "too many scatter meshes")
				local index_buffer = part.mesh.index_buffer
				draw_batches[#draw_batches + 1] = {
					mesh = part.mesh,
					material = part.material,
					first_polygon3d = part.polygon,
					prototype = proto.index * 2,
					first_index = index_pool.GetFirstIndex(index_buffer),
					index_count = index_buffer:GetIndexCount(),
					double_sided = part.material:GetDoubleSided() and 1 or 0,
				}
			end

			local part = proto.billboard_part

			if part then
				local index_buffer = part.mesh.index_buffer
				draw_batches[#draw_batches + 1] = {
					mesh = part.mesh,
					material = part.material,
					first_polygon3d = part.polygon,
					prototype = proto.index * 2 + 1,
					first_index = index_pool.GetFirstIndex(index_buffer),
					index_count = index_buffer:GetIndexCount(),
					double_sided = part.material:GetDoubleSided() and 1 or 0,
				}
			end
		end
	end

	for i, batch in ipairs(draw_batches) do
		local out = b.batch_data[i - 1]
		out.index_count = batch.index_count
		out.first_index = batch.first_index
		out.prototype = batch.prototype
		out.double_sided = batch.double_sided
	end

	batch_serial = batch_serial + 1
	draw_version = ScatterSet.version
	assign_bases()
end

local function barrier(cmd, buffer, src_stage, dst_stage, src_access, dst_access)
	cmd:PipelineBarrier{
		srcStage = src_stage,
		dstStage = dst_stage,
		bufferBarriers = {
			{
				buffer = buffer,
				size = buffer.size,
				srcAccessMask = src_access,
				dstAccessMask = dst_access,
			},
		},
	}
end

-- what the surfaces grow is baked in units, the cells of a world grid of a surface (BAKE_CELLS, bigger cells far from the camera), and
-- stays baked: placing instances on the surface is the expensive part and it does not depend on the camera
-- but for how thin the field is at a distance. a unit is baked for the band of distances its nearest point is in,
-- keeping every instance that the band's nearest distance keeps, and baked again when the camera comes into a
-- nearer band (or when what it was baked from changed). each frame a cull pass thins what is baked by the exact
-- distance, culls it by the view and sorts it into what the draws read
local units = {}
local surface_states = setmetatable({}, {__mode = "k"})
local bake_epoch = 1
local free_slots = {}
local next_slot = 0
local pool_top = 0
local pool_free = {}
local pool_pending = {}
local bake_list = {}
local unit_readback_frames = {}
local ZERO_WORD = ffi.new("uint32_t[1]")
local JOB_RESET = ffi.new("uint32_t[4]", {0, 1, 1, 0})
local MIN_CLASS = 6
local MAX_CLASS = 17
local last_signature = nil
local pool_warned = 0

local function next_class(count)
	local class = MIN_CLASS

	while 2 ^ class < count and class < MAX_CLASS do
		class = class + 1
	end

	return class
end

local function pool_alloc(class)
	local list = pool_free[class]

	if list and #list > 0 then return table.remove(list) end

	local size = 2 ^ class

	if pool_top + size > scatter.MAX_BAKED then return nil end

	pool_top = pool_top + size
	return pool_top - size
end

-- the memory goes back after the frames in flight that could still read it
local function pool_release(unit)
	if not unit.offset then return end

	pool_pending[#pool_pending + 1] = {offset = unit.offset, class = unit.class, frame = system.GetFrameNumber()}
	unit.offset = nil
	unit.baked_band = nil
	unit.count = nil
end

local function pool_collect()
	local frame = system.GetFrameNumber()

	while pool_pending[1] and frame - pool_pending[1].frame > scatter.SURFACE_RING + 1 do
		local entry = table.remove(pool_pending, 1)
		pool_free[entry.class] = pool_free[entry.class] or {}
		table.insert(pool_free[entry.class], entry.offset)
	end
end

local function band_of(distance)
	if distance < scatter.BAND_FIRST then return 0 end

	return math.floor(math.log(distance / scatter.BAND_FIRST) / math.log(scatter.BAND_RATIO)) + 1
end

local function band_distance(band)
	if band == 0 then return 0 end

	return scatter.BAND_FIRST * scatter.BAND_RATIO ^ (band - 1)
end

-- the share of a prototype's density that is left at a distance, the same as scatter_keep in the shaders
local function cpu_keep(proto, distance)
	local set = proto.set
	local far = proto.max_distance * proto.distance_multiplier
	local full = proto.full_density_distance * proto.distance_multiplier

	if distance >= far then return 0 end

	local ratio = full / math.max(distance, 0.001)
	local fade = math.clamp((distance - far * 0.7) / (far * 0.3), 0, 1)
	return math.min(ratio * ratio, 1) * (1 - fade * fade * (3 - 2 * fade))
end

-- how many instances a unit holds when baked for a distance, from the rules of the set
local function estimate_unit(set, material_density, distance, size)
	local total = 0

	for _, proto in ipairs(set.protos) do
		if proto.state == "ready" then
			total = total + proto.density * proto.density_multiplier * material_density * cpu_keep(proto, distance) * (1 - 0.5 * proto.cluster_amount) * size ^ 2
		end
	end

	return total * 1.3
end

-- the scene bvh is made of polygons, so the units near the camera get their instances made into polygons of the
-- stand-ins of their prototypes (see scatter_proxy.lua), in entities that are only in the bvh. the instances are on the
-- gpu, a few frames of copying to the host later they are made into the polygons
-- every bake of a unit makes new instances, but the bvh of its proxy is a sah build on the cpu that costs more than
-- the difference is worth, so a unit that has one waits this long before it is rebuilt
local PROXY_REBUILD_FRAMES = 180
local proxy_jobs = {}
local proxy_part_templates = setmetatable({}, {__mode = "k"})
local proxy_warned = false
local proxy_copy = BufferCopy()

local function remove_proxy(unit)
	if unit.proxy then
		if unit.proxy:IsValid() then unit.proxy:Remove() end

		unit.proxy = nil
	end
end

-- near units have the model's geometry in their proxy, far units billboards. a unit changes over some way past the
-- bvh distance so that one on the edge does not go back and forth
local PROXY_MODE_MARGIN = 1.15

local function get_unit_mode(unit)
	local range = gi_distance:Get()

	if unit.proxy_mode == "near" then
		return unit.dist < range * PROXY_MODE_MARGIN and "near" or "far"
	end

	return unit.dist < range and "near" or "far"
end

-- the parts a proxy copies for each instance of a prototype: with a billboard, the model's own geometry where the scene
-- draws the model (nearer than its switch distance from the camera) and the billboard beyond it, like the scene,
-- else the stand-in. `far` says which of the two
local function get_proxy_parts(proto, far)
	if proto.billboard_part and (far or get_switch(proto) == 0) then return {proto.billboard_part} end

	if proto.billboard_part then return proto.parts end

	return proto.lod_parts or proto.parts
end

local function build_proxy(unit, instances, count)
	local protos = ScatterSet.GetPrototypes()
	local bits = ffi.cast("uint32_t *", instances)
	local lists = {{}, {}}
	local counts = {{}, {}}
	local camera = render3d.GetCamera():GetPosition()
	local cx, cy, cz = camera.x, camera.y, camera.z
	local full_range = gi_distance:Get()
	local billboard_range = billboard_distance:Get()
	local near_unit = get_unit_mode(unit) == "near"

	for i = 0, count - 1 do
		local proto = protos[bits[i * 16 + 11] + 1]

		if proto and proto.bvh and proto.state == "ready" and instances[i * 16 + 3] < cpu_keep(proto, unit.dist) then
			local switch = get_switch(proto)
			-- a unit with the model's geometry in it, near the camera, has it for what is nearer than the prototype's
			-- switch distance, a unit past it has the billboards only, all of them, wherever the camera is in it: what
			-- is in a proxy then depends on the unit alone, not on the camera, and does not have to be built again
			-- when the camera moves
			local kind

			if near_unit then
				local dx, dy, dz = instances[i * 16 + 12] - cx, instances[i * 16 + 13] - cy, instances[i * 16 + 14] - cz
				local d2 = dx * dx + dy * dy + dz * dz

				if d2 < full_range * full_range and (switch == 0 or d2 < switch * switch) then
					kind = 1
				elseif switch > 0 and d2 < billboard_range * billboard_range then
					kind = 2
				end
			elseif switch > 0 then
				kind = 2
			end

			if kind then
				local list = lists[kind][proto]

				if not list then
					list = ffi.new("int32_t[?]", count)
					lists[kind][proto] = list
					counts[kind][proto] = 0
				end

				list[counts[kind][proto]] = i
				counts[kind][proto] = counts[kind][proto] + 1
			end
		end
	end

	remove_proxy(unit)
	unit.proxy_mode = near_unit and "near" or "far"

	if not next(lists[1]) and not next(lists[2]) then return end

	local entity = Entity.New{Name = string.format("scatter_proxy_%d_%d", unit.min_x, unit.min_z), Parent = Entity.World}
	entity:AddComponent("transform")
	local visual = entity:AddComponent("visual")
	visual:SetRaysOnly(true)
	visual:SetCastShadows(false)
	visual:SetReceivesDecals(false)
	visual:SetUseOcclusionCulling(false)
	visual:SetCullDistance(1e8)

	for kind = 1, 2 do
		for proto, list in pairs(lists[kind]) do
			for _, part in ipairs(get_proxy_parts(proto, kind == 2)) do
				local template = proxy_part_templates[part]

				if not template then
					template = scatter_proxy.GetTemplate(part.mesh)
					proxy_part_templates[part] = template
				end

				local vertices, vertex_count, indices, index_count = scatter_proxy.Build(template, instances, list, counts[kind][proto])
				local polygon = Polygon3D.New()
				polygon:UploadVertexArray(vertices, vertex_count, indices, index_count, false, "owned")
				local primitive = Entity.New{Name = entity:GetName() .. "_primitive", Parent = entity}
				primitive:AddComponent("transform")
				local visual_primitive = primitive:AddComponent("visual_primitive")
				visual_primitive:SetPolygon3D(polygon)
				visual_primitive:SetMaterial(part.material)
			end
		end
	end

	visual:BuildAABB()
	unit.proxy = entity
end

local function release_unit(unit)
	remove_proxy(unit)
	pool_release(unit)
	unit.state.units[unit.key] = nil
	free_slots[#free_slots + 1] = unit.slot
	unit.dead = true
end

local function acquire_slot()
	if free_slots[1] then return table.remove(free_slots) end

	assert(next_slot < scatter.MAX_UNITS, "too many scatter units")
	next_slot = next_slot + 1
	return next_slot - 1
end

-- the counts of the units the gpu got, from the frame this ring slot was written: a unit that has more than
-- it has room for is baked again with room, one with far less is baked again with less
local function apply_unit_counts(b, slot)
	local frame = unit_readback_frames[slot]

	if not frame then return end

	local counts = b.unit_counts_data + slot * scatter.MAX_UNITS

	for _, unit in ipairs(units) do
		if unit.offset and unit.bake_frame <= frame and unit.count_for ~= unit.bake_frame then
			unit.count_for = unit.bake_frame
			unit.count = counts[unit.slot]

			if unit.count > 2 ^ unit.class then
				-- at the biggest there is, it just stays over
				unit.hint = unit.class < MAX_CLASS and unit.count * 1.25 or nil
			elseif unit.class > 8 and unit.count * 4 < 2 ^ unit.class then
				unit.hint = math.max(unit.count * 1.5, 64)
			end
		end
	end
end

local function bake_unit(cmd, b, passes, unit, surface, surface_index, band)
	local distance = band_distance(band)
	local material_density = surface.material:GetScatterDensity()
	local wanted = unit.hint

	if not wanted and unit.count then
		-- baked before, for another band: what it held then is the best guess
		wanted = unit.count * 2
	elseif not wanted then
		-- from the density rules alone a cell of open sea gets as much room as one of jungle, so a big cell with a big
		-- estimate only gets a probe's room: the gpu counts what there is (past the room), and the unit is baked again to fit
		wanted = estimate_unit(surface.set, material_density, distance, unit.size)

		if unit.tier > 1 and wanted > scatter.PROBE_ABOVE then wanted = scatter.PROBE_ROOM end
	end

	local class = next_class(math.max(wanted, 1))
	pool_release(unit)
	local offset = pool_alloc(class)

	while not offset do
		local farthest

		for _, other in ipairs(units) do
			if other.offset and other.bake_frame ~= system.GetFrameNumber() and (not farthest or other.dist > farthest.dist) then
				farthest = other
			end
		end

		if not farthest or farthest.dist <= unit.dist then
			if system.GetFrameNumber() - pool_warned > 600 then
				pool_warned = system.GetFrameNumber()
				logf("scatter: the baked pool is full, units far away stay empty\n")
			end

			return false
		end

		remove_proxy(farthest)
		pool_release(farthest)
		pool_collect()
		-- what is released waits for the frames in flight, so it may not be there yet
		offset = pool_alloc(class)

		if not offset then return false end
	end

	unit.offset = offset
	unit.class = class
	unit.hint = nil
	unit.baked_band = band
	unit.set = surface.set
	unit.has_bvh = false

	for _, proto in ipairs(surface.set.protos) do
		if proto.bvh and proto.state == "ready" then unit.has_bvh = true end
	end

	unit.epoch = bake_epoch
	unit.stamp = unit.state.stamp
	unit.bake_frame = system.GetFrameNumber()
	unit.count = nil
	unit.count_for = nil
	for _, pass in ipairs{passes.tiles, passes.instances} do
		pass.surface_index = surface_index
		pass.mask_texture = pass:GetTextureIndex(surface.material:GetTerrainMaterialTexture())
		pass.triangle_count = b.surface_data[surface_index].info[0]
		pass.unit_slot = unit.slot
		pass.unit_offset = offset
		pass.unit_capacity = 2 ^ class
		pass.unit_min_x = unit.min_x
		pass.unit_min_z = unit.min_z
		pass.unit_max_x = unit.min_x + unit.size
		pass.unit_max_z = unit.min_z + unit.size
		pass.band_distance = distance
	end

	barrier(cmd, b.args, "compute", "transfer", {"shader_read", "shader_write"}, "transfer_write")
	barrier(cmd, b.unit_counts, "compute", "transfer", {"shader_read", "shader_write"}, "transfer_write")
	cmd:UpdateBuffer(b.args, 0, 16, JOB_RESET)
	cmd:UpdateBuffer(b.unit_counts, unit.slot * 4, 4, ZERO_WORD)
	barrier(cmd, b.args, "transfer", "compute", "transfer_write", {"shader_read", "shader_write"})
	barrier(cmd, b.unit_counts, "transfer", "compute", "transfer_write", {"shader_read", "shader_write"})

	if passes.tiles.triangle_count > 0 then
		passes.tiles:Dispatch(
			cmd,
			math.min(passes.tiles.triangle_count, scatter.TILE_GROUPS_PER_ROW),
			math.ceil(passes.tiles.triangle_count / scatter.TILE_GROUPS_PER_ROW),
			1,
			1
		)
	end

	barrier(cmd, b.jobs, "compute", "compute", "shader_write", "shader_read")
	barrier(
		cmd,
		b.args,
		"compute",
		{"draw_indirect", "compute"},
		"shader_write",
		{"indirect_command_read", "shader_read", "shader_write"}
	)
	passes.instances:DispatchIndirect(cmd, b.args, 0, render.GetCurrentFrame())
	return true
end

-- the units near enough get their instances copied to the host, a few frames later they are made into geometry
-- for the scene bvh, one unit a frame
local PROXY_SPEED_SCALE = 25
local proxy_last_x, proxy_last_y, proxy_last_z = 0, 0, 0
local proxy_last_time = 0
local proxy_speed = 0

local function update_proxies(cmd, b, frame, ring)
	local wanted = gi_enabled:Get()
	local range = math.max(gi_distance:Get(), billboard_distance:Get())
	local position = render3d.GetCamera():GetPosition()
	local now = system.GetElapsedTime()

	if now > proxy_last_time then
		local dx, dy, dz = position.x - proxy_last_x, position.y - proxy_last_y, position.z - proxy_last_z
		proxy_speed = math.lerp(0.1, proxy_speed, math.sqrt(dx * dx + dy * dy + dz * dz) / (now - proxy_last_time))
	end

	proxy_last_x, proxy_last_y, proxy_last_z = position.x, position.y, position.z
	proxy_last_time = now
	local job = proxy_jobs[ring]

	if job then
		proxy_jobs[ring] = nil
		local unit = job.unit
		unit.proxy_pending = nil

		if wanted and not unit.dead and unit.offset and unit.bake_frame == job.bake_frame then
			build_proxy(unit, b.proxy_data + ring * scatter.PROXY_MAX_INSTANCES * 16, job.count)
			unit.proxy_frame = job.bake_frame
			unit.proxy_built = frame
		end
	end

	for _, unit in ipairs(units) do
		if unit.proxy and (not wanted or not unit.offset or unit.dist > range * 1.25) then
			remove_proxy(unit)
			unit.proxy_frame = nil
			unit.proxy_built = nil
		elseif unit.proxy_frame and unit.proxy_mode ~= get_unit_mode(unit) then
			unit.proxy_frame = nil
		end
	end

	if not wanted then return end

	-- flying fast the units are passed before their proxy is of any use, and a proxy is a cpu bvh build of its triangles
	local build_range = math.max(range / (1 + proxy_speed / PROXY_SPEED_SCALE), 30)
	local best

	for _, unit in ipairs(units) do
		if
			unit.offset and
			unit.count and
			unit.count > 0 and
			unit.has_bvh and
			not unit.state.preload and
			not unit.proxy_pending and
			unit.proxy_frame ~= unit.bake_frame and
			(
				not unit.proxy_built or
				frame - unit.proxy_built >= PROXY_REBUILD_FRAMES
			)
			and
			unit.dist <= build_range and
			(
				not best or
				unit.dist < best.dist
			)
		then
			best = unit
		end
	end

	if not best then return end

	if best.count > scatter.PROXY_MAX_INSTANCES then
		best.proxy_frame = best.bake_frame

		if not proxy_warned then
			proxy_warned = true
			logf("scatter: a unit has more instances than the %d that the scene bvh geometry is made from, it has none\n", scatter.PROXY_MAX_INSTANCES)
		end

		return
	end

	barrier(cmd, b.baked, "compute", "transfer", "shader_write", "transfer_read")
	proxy_copy[0].srcOffset = best.offset * 64
	proxy_copy[0].dstOffset = ring * scatter.PROXY_MAX_INSTANCES * 64
	proxy_copy[0].size = best.count * 64
	cmd:CopyBuffer(b.baked, b.proxy_staging, proxy_copy, 1)
	best.proxy_pending = true
	proxy_jobs[ring] = {unit = best, bake_frame = best.bake_frame, count = best.count}
end

-- the units a surface wants this frame, found from the biggest cells down: a cell the camera is far from is a unit, a
-- cell it is near is the 16 cells under it. a unit that is not baked yet is drawn as whatever was baked of the
-- cells it covers (or of the cell around it) until it is
local visit_surface, visit_state, visit_frame, visit_dy, visit_camera_x, visit_camera_z, visit_reach
local visit_min_x, visit_max_x, visit_min_z, visit_max_z

local function unit_key(tier, cx, cz)
	return tier * 2 ^ 41 + (cx + 524288) * 1048576 + cz + 524288
end

local function visit_cell(tier, cx, cz)
	local size = scatter.BAKE_CELLS[tier]
	local x0, z0 = cx * size, cz * size

	if x0 > visit_max_x or x0 + size <= visit_min_x or z0 > visit_max_z or z0 + size <= visit_min_z then return end

	local dx = math.max(x0 - visit_camera_x, 0, visit_camera_x - (x0 + size))
	local dz = math.max(z0 - visit_camera_z, 0, visit_camera_z - (z0 + size))
	local distance = math.sqrt(dx * dx + visit_dy * visit_dy + dz * dz)

	if distance > visit_reach then return end

	if tier > 1 and distance < size * scatter.BAKE_SPLIT then
		for i = 0, 3 do
			for j = 0, 3 do
				visit_cell(tier - 1, cx * 4 + i, cz * 4 + j)
			end
		end

		return
	end

	local state = visit_state
	local key = unit_key(tier, cx, cz)
	local unit = state.units[key]

	if not unit then
		unit = {state = state, key = key, tier = tier, size = size, min_x = x0, min_z = z0, slot = acquire_slot()}
		scatter.units_created = (scatter.units_created or 0) + 1
		state.units[key] = unit
		units[#units + 1] = unit
		local fallbacks = {}

		for t = tier + 1, #scatter.BAKE_CELLS do
			local f = 4 ^ (t - tier)
			local other = state.units[unit_key(t, math.floor(cx / f), math.floor(cz / f))]

			if other then fallbacks[#fallbacks + 1] = other end
		end

		for t = tier - 1, 1, -1 do
			local f = 4 ^ (tier - t)

			for i = 0, f - 1 do
				for j = 0, f - 1 do
					local other = state.units[unit_key(t, cx * f + i, cz * f + j)]

					if other then fallbacks[#fallbacks + 1] = other end
				end
			end
		end

		unit.fallbacks = fallbacks
	end

	unit.seen = visit_frame
	unit.dist = distance
	state.wanted = state.wanted + 1

	if unit.offset then state.baked = state.baked + 1 end

	if not unit.offset then
		for _, other in ipairs(unit.fallbacks) do
			if other.offset and not other.dead then other.seen = visit_frame end
		end
	end

	local band = band_of(distance)
	local priority
	-- inside a class the ranking is the view's: the nearer of where the camera is and where it will be, farther the more it is out of view
	local rank = scatter.view_priority:Rank(x0, state.min_y, z0, x0 + size, state.max_y, z0 + size)

	if not unit.offset or unit.epoch ~= bake_epoch or unit.stamp ~= state.stamp or unit.hint then
		-- new or changed units first, what a surface that is about to go would grow after them, then a unit that is only baked for a nearer band
		priority = state.retiring and 1e6 + rank or rank
	elseif band < unit.baked_band then
		priority = 2e6 + rank
	elseif band > unit.baked_band + 1 then
		priority = 3e6 + rank
	end

	if priority then
		bake_list[#bake_list + 1] = {unit = unit, surface = visit_surface, band = band, priority = priority}
	end
end

local function by_priority(a, b)
	return a.priority < b.priority
end

-- how many units a surface wanted this frame (or the one before) and how many of them were baked, nil when it was not looked at
function scatter.GetSurfaceStatus(entry)
	local state = surface_states[entry]

	if not state or system.GetFrameNumber() - state.frame > 1 then return nil end

	return state.wanted, state.baked
end

-- a surface is ready when scatter looked at it this frame or the one before and all the units it wants are baked, or when scatter is
-- off. a surface that has no set is never looked at, ask only for those that have one
function scatter.IsSurfaceReady(entry)
	if not enabled:Get() then return true end

	local state = surface_states[entry]

	if not state or system.GetFrameNumber() - state.frame > 1 then return false end

	return state.baked == state.wanted
end

function scatter.PreDraw(cmd)
	surface_count = 0

	if not enabled:Get() then return end

	local candidates = get_surfaces()

	if not candidates[1] then return end

	local b = get_buffers()
	local passes = get_compute_passes()

	if draw_version ~= ScatterSet.version then
		rebuild_draws()
		local signature = {}

		for i, proto in ipairs(ScatterSet.GetPrototypes()) do
			signature[i] = proto.uid .. (proto.state == "ready" and "r" or "n")
		end

		signature = table.concat(signature, ",")

		-- what is baked has the index of the prototype in it
		if signature ~= last_signature then
			last_signature = signature
			bake_epoch = bake_epoch + 1
		end
	end

	local protos = ScatterSet.GetPrototypes()
	local ring = (render.GetCurrentFrame() - 1) % scatter.SURFACE_RING
	adjust_rooms(ring)
	apply_unit_counts(b, ring)

	for _, proto in ipairs(protos) do
		if proto.sized_density ~= proto.density_multiplier or proto.sized_distance ~= proto.distance_multiplier then
			bake_epoch = bake_epoch + 1
		end

		if
			proto.sized_density ~= proto.density_multiplier or
			proto.sized_distance ~= proto.distance_multiplier or
			proto.sized_scale ~= billboard_scale:Get() or
			proto.sized_switch ~= get_switch(proto)
		then
			size_prototype(proto)
		end
	end

	if layout_dirty then assign_bases() end

	for i, proto in ipairs(protos) do
		write_prototype(b.prototype_data[i - 1], proto, instance_bases[i], far_bases[i], shadow_bases[i], shadow_billboard_bases[i])
	end

	pool_collect()
	local frame = system.GetFrameNumber()
	local camera_object = render3d.GetCamera()
	local camera = camera_object:GetPosition()
	scatter.view_priority:Update(camera, camera_object:GetRotation():GetForward(), scatter.view_priority.GetHalfAngle(camera_object))
	local surface_base = ring * scatter.MAX_SURFACES
	local reach = 0

	for _, proto in ipairs(protos) do
		reach = math.max(reach, proto.max_distance * proto.distance_multiplier)
	end

	-- which units want baking
	list.clear(bake_list)

	for _, surface in ipairs(candidates) do
		local mesh = surface.entry.polygon3d:GetMesh()

		local visible = surface.component:GetVisible()

		if mesh:IsValid() and (visible or scatter.preloaded[surface.component]) then
			local aabb = surface.component:GetWorldAABB()
			local min_x, max_x = math.max(aabb.min_x, camera.x - reach), math.min(aabb.max_x, camera.x + reach)
			local min_z, max_z = math.max(aabb.min_z, camera.z - reach), math.min(aabb.max_z, camera.z + reach)
			local state = surface_states[surface.entry]

			if not state then
				state = {units = {}, stamp = 0}
				surface_states[surface.entry] = state
			end

			state.wanted, state.baked, state.frame = 0, 0, frame
			state.preload = not visible
			state.retiring = scatter.retiring[surface.component]
			state.min_y, state.max_y = aabb.min_y, aabb.max_y

			if min_x <= max_x and min_z <= max_z and camera.y > aabb.min_y - reach and camera.y < aabb.max_y + reach then
				-- what a unit is baked from, besides the set
				local signature = aabb.min_x + aabb.max_x * 3 + aabb.min_z * 7 + aabb.max_z * 11 + aabb.min_y * 13 + aabb.max_y * 17 + surface.material:GetScatterDensity() * 19

				if state.signature ~= signature then
					state.signature = signature
					state.stamp = state.stamp + 1
				end

				visit_surface, visit_state, visit_frame = surface, state, frame
				visit_dy = math.max(aabb.min_y - camera.y, 0, camera.y - aabb.max_y)
				visit_camera_x, visit_camera_z, visit_reach = camera.x, camera.z, reach
				visit_min_x, visit_max_x, visit_min_z, visit_max_z = min_x, max_x, min_z, max_z
				local top = scatter.BAKE_CELLS[#scatter.BAKE_CELLS]

				for cx = math.floor(min_x / top), math.floor(max_x / top) do
					for cz = math.floor(min_z / top), math.floor(max_z / top) do
						visit_cell(#scatter.BAKE_CELLS, cx, cz)
					end
				end
			end
		end
	end

	table.sort(bake_list, by_priority)
	-- for whoever measures: nothing is loading when this is zero
	scatter.pending_new, scatter.pending_nearer, scatter.pending_farther = 0, 0, 0

	for _, entry in ipairs(bake_list) do
		if entry.priority >= 3e6 then
			scatter.pending_farther = scatter.pending_farther + 1
		elseif entry.priority >= 2e6 then
			scatter.pending_nearer = scatter.pending_nearer + 1
		else
			scatter.pending_new = scatter.pending_new + 1
		end
	end

	scatter.pending_bakes = #bake_list
	scatter.unit_count = #units
	scatter.pool_top = pool_top

	-- the baking of this frame
	if bake_list[1] then
		if RAY_QUERY then
			passes.instances:UpdateDescriptorSet(
				"acceleration_structure_khr",
				render.GetCurrentFrame(),
				BINDING_SCENE,
				0,
				scene_rt.GetTLAS(cmd)
			)
		end

		for i = 1, math.min(#bake_list, scatter.BAKE_BUDGET) do
			local entry = bake_list[i]
			local surface = entry.surface

			if not surface.index_frame or surface.index_frame ~= frame then
				if surface_count < scatter.MAX_SURFACES then
					surface.index = surface_base + surface_count
					surface.index_frame = frame
					write_surface(b.surface_data[surface.index], surface, passes.instances)
					surface_count = surface_count + 1
				end
			end

			if surface.index_frame == frame then
				bake_unit(cmd, b, passes, entry.unit, surface, surface.index, entry.band)
				scatter.bakes_done = (scatter.bakes_done or 0) + 1
			end
		end

		barrier(cmd, b.baked, "compute", "compute", "shader_write", "shader_read")
		barrier(cmd, b.unit_counts, "compute", "compute", "shader_write", "shader_read")
	end

	update_proxies(cmd, b, frame, ring)

	-- the units nothing wanted for a while go
	local kept = 0

	for _, unit in ipairs(units) do
		if frame - unit.seen > 30 then
			release_unit(unit)
		else
			kept = kept + 1
			units[kept] = unit
		end
	end

	for i = kept + 1, #units do
		units[i] = nil
	end

	-- the units and the blocks of 64 instances that the cull pass goes through
	local unit_base = ring * scatter.MAX_UNITS
	local block_base = ring * (scatter.MAX_BAKED / 64)
	local unit_count, block_count = 0, 0

	for _, unit in ipairs(units) do
		-- a unit nothing wants this frame (its surface is gone or hidden) is not drawn, it is kept a while in case it is back
		if unit.offset and unit.seen == frame and not unit.state.preload then
			local capacity = 2 ^ unit.class
			local blocks = math.ceil((unit.count and math.min(unit.count, capacity) or capacity) / 64)
			local entry = (unit_base + unit_count) * 4
			b.units_data[entry] = unit.offset
			b.units_data[entry + 1] = capacity
			b.units_data[entry + 2] = unit.slot
			b.units_data[entry + 3] = 0

			for block = 0, blocks - 1 do
				local at = (block_base + block_count) * 2
				b.blocks_data[at] = unit_count
				b.blocks_data[at + 1] = block
				block_count = block_count + 1
			end

			unit_count = unit_count + 1
		end
	end

	surface_count = block_count
	barrier(
		cmd,
		b.args,
		{"draw_indirect", "compute", "transfer"},
		"transfer",
		{"indirect_command_read", "shader_read", "shader_write", "transfer_read"},
		"transfer_write"
	)
	cmd:UpdateBuffer(b.args, 0, ffi.sizeof(ARGS_RESET), ARGS_RESET)
	barrier(
		cmd,
		b.args,
		"transfer",
		"compute",
		"transfer_write",
		{"shader_read", "shader_write"}
	)
	barrier(cmd, b.instances, "vertex", "compute", "shader_read", "shader_write")
	barrier(cmd, b.commands, "draw_indirect", "compute", "indirect_command_read", "shader_write")
	barrier(cmd, b.shadow_commands, "draw_indirect", "compute", "indirect_command_read", "shader_write")

	if block_count > 0 then
		passes.cull.block_count = block_count
		passes.cull.unit_base = unit_base
		passes.cull.block_base = block_base
		passes.cull:Dispatch(cmd, block_count, 1, 1, 1)
	end

	barrier(cmd, b.args, "compute", "compute", "shader_write", "shader_read")

	if draw_batches[1] then
		passes.commands.batch_count = #draw_batches
		passes.commands:Dispatch(cmd, math.ceil(#draw_batches * 2 / 64), 1, 1, 1)
		barrier(cmd, b.commands, "compute", "draw_indirect", "shader_write", "indirect_command_read")
		barrier(cmd, b.shadow_commands, "compute", "draw_indirect", "shader_write", "indirect_command_read")
		first_commands_frame = first_commands_frame or system.GetFrameNumber()
	end

	barrier(cmd, b.args, "compute", "transfer", "shader_write", "transfer_read")
	demand_copy[0].srcOffset = 16
	demand_copy[0].dstOffset = ring * MAX_PROTOTYPES * 16
	demand_copy[0].size = MAX_PROTOTYPES * 16
	cmd:CopyBuffer(b.args, b.demand, demand_copy, 1)
	demand_versions[ring] = draw_version
	barrier(cmd, b.unit_counts, "compute", "transfer", "shader_write", "transfer_read")
	demand_copy[0].srcOffset = 0
	demand_copy[0].dstOffset = ring * scatter.MAX_UNITS * 4
	demand_copy[0].size = scatter.MAX_UNITS * 4
	cmd:CopyBuffer(b.unit_counts, b.unit_counts_readback, demand_copy, 1)
	unit_readback_frames[ring] = frame
	barrier(cmd, b.instances, "compute", "vertex", "shader_write", "shader_read")
end

function scatter.Draw(pipeline, cmd)
	if not enabled:Get() or surface_count == 0 or not draw_batches[1] then return end

	local b = get_buffers()
	batch_table = batch_table or gbuffer_instancing.NewBatchTable("scatter_batches")
	pipeline.draw_batches_address = batch_table:Update(pipeline, draw_batches, batch_serial, system.GetFrameNumber())
	pipeline.draw_instances_address = b.instances:GetDeviceAddress()
	pipeline.draw_prev_instances_address = pipeline.draw_instances_address
	pipeline:UploadConstants()
	cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")
	cmd:SetCullMode(orientation.CULL_MODE)
	cmd:DrawIndexedIndirect(b.commands, 0, #draw_batches, DRAW_COMMAND_SIZE)
	cmd:SetCullMode("none")
	cmd:DrawIndexedIndirect(b.commands, #draw_batches * DRAW_COMMAND_SIZE, #draw_batches, DRAW_COMMAND_SIZE)
end

-- the shadow maps draw what the last PreDraw wrote. the shadow pass may run before this frame's PreDraw,
-- in which case the commands are the last frame's, and there is nothing to draw yet in the first frame
event.AddListener("DrawAllShadows", "scatter", function(shadow_map, cascade_index)
	-- the cascades that draw the bvh's soup get what is near from the geometry in it
	if
		gi_enabled:Get() and
		shadow_map.UsesSoup and
		shadow_map:UsesSoup(cascade_index) and
		scene_bvh.IsReady()
	then
		return
	end

	if not enabled:Get() or not draw_batches[1] or not first_commands_frame or first_commands_frame >= system.GetFrameNumber() then
		return
	end

	local b = get_buffers()
	shadow_map:DrawBatches(
		cascade_index,
		scatter,
		draw_batches,
		batch_serial,
		b.instances:GetDeviceAddress(),
		b.shadow_commands,
		DRAW_COMMAND_SIZE_SHADOW
	)
end)

return scatter
