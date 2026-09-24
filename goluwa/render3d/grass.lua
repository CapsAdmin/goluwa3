local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Material = import("goluwa/render3d/material.lua")
local grass = library()
-- Procedural grass blades on every surface whose material has the Grass flag.
-- Everything after picking the surfaces is on the GPU:
--
--   scatter_tiles: a thread per triangle cuts the triangle's footprint near
--   the camera into square tiles and appends the visible ones as jobs
--   scatter_blades: a workgroup per job places the blades inside the triangle
--   and appends them to the blade buffer and its indirect draw counts
--   draw: one indirect draw each for near and far blades, built from
--   gl_VertexIndex, written straight into the gbuffer
--
-- Blades sit on a world anchored grid of cells, cell size 1/sqrt(density),
-- one blade per cell jittered inside it. A cell's level is how many times its
-- index is divisible by two (up to MAX_LEVEL); a level m cell's blade jitters
-- over the 2^m cells it anchors and gets a priority in [4^-(m+1), 4^-m), so
-- the cells of level >= k alone form a jittered grid 2^k cells apart. Thinning
-- with distance keeps the blades whose priority is below the keep fraction,
-- which lets far tiles skip the low levels outright, and a blade fades by
-- shrinking as the keep fraction approaches its priority instead of popping.
grass.MAX_SURFACES = 512
grass.SURFACE_RING = 4
grass.MAX_JOBS = 65535
grass.MAX_BLADES = 2 ^ 19
grass.TILE_CELLS = 32
grass.MAX_LEVEL = 4
grass.NEAR_SEGMENTS = 7
grass.FAR_SEGMENTS = 3
-- blades are full density up to here, then thin with the square of distance
grass.full_density_distance = 8
-- near blades get NEAR_SEGMENTS, the rest FAR_SEGMENTS
grass.near_distance = 15
grass.max_distance = 150
grass.enabled = grass.enabled ~= false
local HALF_BLADES = grass.MAX_BLADES / 2
local BLADE_SIZE = 32
local SURFACE_FLOATS = 36
local GrassSurface = ffi.typeof([[struct {
	float world[16];
	uint32_t addresses[4];
	uint32_t info[4];
	float color[4];
	float params[4];
	float wind[4];
}]])
local uint64_ptr = ffi.typeof("uint64_t *")
local int32_ptr = ffi.typeof("int32_t *")
assert(ffi.sizeof(GrassSurface) == SURFACE_FLOATS * 4)
-- dispatch x y z, job counter, near draw, far draw, near counter, far counter
local ARGS_RESET = ffi.new(
	"uint32_t[16]",
	{
		0,
		1,
		1,
		0,
		grass.NEAR_SEGMENTS * 2 + 1,
		0,
		0,
		0,
		grass.FAR_SEGMENTS * 2 + 1,
		0,
		0,
		HALF_BLADES,
		0,
		0,
		0,
		0,
	}
)
local ARGS_DRAW_NEAR_OFFSET = 4 * 4
local ARGS_DRAW_FAR_OFFSET = 8 * 4
local buffers = nil

local function get_buffers()
	if buffers then return buffers end

	buffers = {
		surfaces = render.CreateBuffer{
			byte_size = ffi.sizeof(GrassSurface) * grass.MAX_SURFACES * grass.SURFACE_RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "grass surfaces",
		},
		jobs = render.CreateBuffer{
			byte_size = 16 * grass.MAX_JOBS,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "grass jobs",
		},
		blades = render.CreateBuffer{
			byte_size = BLADE_SIZE * grass.MAX_BLADES,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "grass blades",
		},
		args = render.CreateBuffer{
			byte_size = ffi.sizeof(ARGS_RESET),
			buffer_usage = {"storage_buffer", "indirect_buffer", "transfer_dst"},
			memory_property = {"device_local"},
			label = "grass args",
		},
	}
	buffers.surface_data = ffi.cast(ffi.typeof("$ *", GrassSurface), buffers.surfaces:Map())
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
local BINDING_BLADES = 6
local BINDING_ARGS = 7
local COMMON_GLSL = [[
	#define GRASS_TILE_CELLS ]] .. grass.TILE_CELLS .. [[

	#define GRASS_MAX_LEVEL ]] .. grass.MAX_LEVEL .. [[

	#define GRASS_MAX_JOBS ]] .. grass.MAX_JOBS .. [[u
	#define GRASS_HALF_BLADES ]] .. HALF_BLADES .. [[u
	#define GRASS_NEAR_SEGMENTS ]] .. grass.NEAR_SEGMENTS .. [[

	#define GRASS_FAR_SEGMENTS ]] .. grass.FAR_SEGMENTS .. [[

	// steeper than this and nothing grows
	#define GRASS_MIN_UP 0.5

	struct GrassSurface {
		mat4 world;
		// vertex buffer address, index buffer address (0 when not indexed)
		uvec4 addresses;
		// triangle count, 32 bit indices, albedo texture
		uvec4 info;
		vec4 color;
		// cell size, height, height variance, width
		vec4 params;
		// direction xz, strength, frequency
		vec4 wind;
	};

	// root xyz, height
	// uv (half2), width and facing angle (half2),
	// surface index | octahedral ground normal (unorm8 x2) << 16,
	// sqrt albedo rgb and lean (unorm8 x4)
	struct GrassBlade {
		vec4 root;
		uvec4 data;
	};

	layout(std430, set = 0, binding = ]] .. BINDING_SURFACES .. [[) readonly buffer GrassSurfaces {
		GrassSurface grass_surfaces[];
	};

	uint grass_pcg(uint v) {
		uint state = v * 747796405u + 2891336453u;
		uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
		return (word >> 22u) ^ word;
	}

	uint grass_hash2(ivec2 c) {
		return grass_pcg(uint(c.x) ^ grass_pcg(uint(c.y) + 0x9e3779b9u));
	}

	float grass_unorm(uint h) {
		return float(h >> 8) * (1.0 / 16777216.0);
	}

	float grass_value_noise(vec2 p) {
		ivec2 i = ivec2(floor(p));
		vec2 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		return mix(
			mix(grass_unorm(grass_hash2(i)), grass_unorm(grass_hash2(i + ivec2(1, 0))), f.x),
			mix(grass_unorm(grass_hash2(i + ivec2(0, 1))), grass_unorm(grass_hash2(i + ivec2(1, 1))), f.x),
			f.y
		);
	}

	// non harmonic octaves so the pattern never visibly repeats
	float grass_fbm(vec2 p) {
		return grass_value_noise(p) * 0.55 +
			grass_value_noise(p * 2.13 + vec2(17.1, -3.7)) * 0.3 +
			grass_value_noise(p * 4.37 + vec2(-9.3, 21.4)) * 0.15;
	}

	vec2 grass_oct_encode(vec3 n) {
		n /= abs(n.x) + abs(n.y) + abs(n.z);
		vec2 e = n.y >= 0.0 ? n.xz : (1.0 - abs(n.zx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.z >= 0.0 ? 1.0 : -1.0);
		return e * 0.5 + 0.5;
	}

	vec3 grass_oct_decode(vec2 e) {
		e = e * 2.0 - 1.0;
		vec3 n = vec3(e.x, 1.0 - abs(e.x) - abs(e.y), e.y);
		float t = max(-n.y, 0.0);
		n.x += n.x >= 0.0 ? -t : t;
		n.z += n.z >= 0.0 ? -t : t;
		return normalize(n);
	}
]]
local COMPUTE_GLSL = COMMON_GLSL .. [[
	layout(buffer_reference, scalar) readonly buffer GrassVertexData {
		float v[];
	};

	layout(buffer_reference, scalar) readonly buffer GrassIndexData {
		uint i[];
	};

	layout(std430, set = 0, binding = ]] .. BINDING_JOBS .. [[) buffer GrassJobs {
		// surface | level << 24, triangle, tile x, tile z
		uvec4 grass_jobs[];
	};

	layout(std430, set = 0, binding = ]] .. BINDING_BLADES .. [[) writeonly buffer GrassBlades {
		GrassBlade grass_blades[];
	};

	layout(std430, set = 0, binding = ]] .. BINDING_ARGS .. [[) buffer GrassArgs {
		uint grass_dispatch[3];
		uint grass_job_counter;
		uint grass_draw_near[4];
		uint grass_draw_far[4];
		uint grass_near_counter;
		uint grass_far_counter;
	};

	uint grass_index(GrassSurface s, uint i) {
		uint64_t address = packUint2x32(s.addresses.zw);

		if (address == 0ul) return i;

		GrassIndexData data = GrassIndexData(address);

		if (s.info.y != 0u) return data.i[i];

		uint word = data.i[i >> 1];
		return (i & 1u) != 0u ? word >> 16 : word & 0xFFFFu;
	}

	struct GrassTriangle {
		vec3 p0;
		vec3 p1;
		vec3 p2;
		vec2 uv0;
		vec2 uv1;
		vec2 uv2;
		vec3 normal;
	};

	// polygon_3d's vertex: position, normal, uv, tangent, texture blend, color
	#define GRASS_VERTEX_FLOATS 17u

	GrassTriangle grass_load_triangle(GrassSurface s, uint tri) {
		GrassVertexData data = GrassVertexData(packUint2x32(s.addresses.xy));
		uint a = grass_index(s, tri * 3u) * GRASS_VERTEX_FLOATS;
		uint b = grass_index(s, tri * 3u + 1u) * GRASS_VERTEX_FLOATS;
		uint c = grass_index(s, tri * 3u + 2u) * GRASS_VERTEX_FLOATS;
		GrassTriangle t;
		t.p0 = (s.world * vec4(data.v[a], data.v[a + 1u], data.v[a + 2u], 1.0)).xyz;
		t.p1 = (s.world * vec4(data.v[b], data.v[b + 1u], data.v[b + 2u], 1.0)).xyz;
		t.p2 = (s.world * vec4(data.v[c], data.v[c + 1u], data.v[c + 2u], 1.0)).xyz;
		t.uv0 = vec2(data.v[a + 6u], data.v[a + 7u]);
		t.uv1 = vec2(data.v[b + 6u], data.v[b + 7u]);
		t.uv2 = vec2(data.v[c + 6u], data.v[c + 7u]);
		vec3 n = vec3(data.v[a + 3u], data.v[a + 4u], data.v[a + 5u]) +
			vec3(data.v[b + 3u], data.v[b + 4u], data.v[b + 5u]) +
			vec3(data.v[c + 3u], data.v[c + 4u], data.v[c + 5u]);
		t.normal = normalize(mat3(s.world) * n);
		return t;
	}

	float grass_keep(float d) {
		float r = compute.full_density_distance / max(d, 0.001);
		return min(r * r, 1.0) * (1.0 - smoothstep(compute.max_distance * 0.7, compute.max_distance, d));
	}

	vec4 grass_frustum_plane(int i) {
		mat4 m = compute.view_projection;
		vec4 w = vec4(m[0][3], m[1][3], m[2][3], m[3][3]);
		int axis = i >> 1;
		vec4 r = vec4(m[0][axis], m[1][axis], m[2][axis], m[3][axis]);
		return (i & 1) == 0 ? w + r : w - r;
	}

	bool grass_box_visible(vec3 lo, vec3 hi) {
		for (int i = 0; i < 4; i++) {
			vec4 plane = grass_frustum_plane(i);
			vec3 p = mix(lo, hi, step(0.0, plane.xyz));

			if (dot(plane.xyz, p) + plane.w < 0.0) return false;
		}

		return true;
	}

	bool grass_sphere_visible(vec3 center, float radius) {
		for (int i = 0; i < 4; i++) {
			vec4 plane = grass_frustum_plane(i);

			if (dot(plane.xyz, center) + plane.w < -radius * length(plane.xyz)) return false;
		}

		return true;
	}

	// the tallest a blade gets, for bounds
	float grass_max_height(GrassSurface s) {
		return s.params.y * (1.0 + s.params.z) * 1.3;
	}
]]
local compute_block = {
	{"view_projection", "mat4"},
	{"camera_position", "vec3"},
	{"max_distance", "float"},
	{"full_density_distance", "float"},
	{"near_distance", "float"},
	{"surface_index", "int"},
	{"triangle_count", "int"},
}

local function write_compute_block(self, block)
	local camera = render3d.GetCamera()
	local view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	view_projection:CopyToFloatPointer(block.view_projection)
	local position = camera:GetPosition()
	block.camera_position[0] = position.x
	block.camera_position[1] = position.y
	block.camera_position[2] = position.z
	block.max_distance = grass.max_distance
	block.full_density_distance = grass.full_density_distance
	block.near_distance = grass.near_distance
	block.surface_index = self.surface_index or 0
	block.triangle_count = self.triangle_count or 0
	return block
end

local compute_passes = nil

local function get_compute_passes()
	if compute_passes then return compute_passes end

	local descriptor_sets = {
		storage_buffer(BINDING_SURFACES, "surfaces", "compute"),
		storage_buffer(BINDING_JOBS, "jobs", "compute"),
		storage_buffer(BINDING_BLADES, "blades", "compute"),
		storage_buffer(BINDING_ARGS, "args", "compute"),
	}
	compute_passes = {
		tiles = EasyPipeline.Compute{
			name = "grass_scatter_tiles",
			DescriptorSetCount = 1,
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = descriptor_sets,
			block = compute_block,
			write = write_compute_block,
			shader = COMPUTE_GLSL .. [[
				void main() {
					uint tri = gl_GlobalInvocationID.x;

					if (tri >= uint(compute.triangle_count)) return;

					uint surface_index = uint(compute.surface_index);
					GrassSurface s = grass_surfaces[surface_index];
					GrassTriangle t = grass_load_triangle(s, tri);

					if (t.normal.y < GRASS_MIN_UP) return;

					float cell = s.params.x;
					float tile_size = cell * float(GRASS_TILE_CELLS);
					// blades jitter up to 2^MAX_LEVEL cells past their cell's
					// corner, so cells that far before the triangle can land in it
					float reach = cell * float(1 << GRASS_MAX_LEVEL);
					vec3 bmin = min(min(t.p0, t.p1), t.p2);
					vec3 bmax = max(max(t.p0, t.p1), t.p2);
					vec3 cam = compute.camera_position;
					vec2 lo = max(bmin.xz - reach, cam.xz - compute.max_distance);
					vec2 hi = min(bmax.xz, cam.xz + compute.max_distance);

					if (any(greaterThan(lo, hi))) return;

					ivec2 t0 = ivec2(floor(lo / tile_size));
					ivec2 t1 = ivec2(floor(hi / tile_size));
					float top = bmax.y + grass_max_height(s);

					for (int z = t0.y; z <= t1.y; z++) {
						for (int x = t0.x; x <= t1.x; x++) {
							vec2 rmin = vec2(x, z) * tile_size;
							vec3 box_lo = vec3(max(rmin.x, bmin.x), bmin.y, max(rmin.y, bmin.z));
							vec3 box_hi = vec3(min(rmin.x + tile_size + reach, bmax.x), top, min(rmin.y + tile_size + reach, bmax.z));
							float keep = grass_keep(distance(clamp(cam, box_lo, box_hi), cam));

							if (keep <= 0.0) continue;

							if (!grass_box_visible(box_lo, box_hi)) continue;

							int level = min(int(floor(0.5 * log2(1.0 / keep))), GRASS_MAX_LEVEL);
							uint slot = atomicAdd(grass_job_counter, 1u);

							if (slot >= GRASS_MAX_JOBS) return;

							grass_jobs[slot] = uvec4(surface_index | (uint(level) << 24), tri, uint(x), uint(z));
							atomicMax(grass_dispatch[0], slot + 1u);
						}
					}
				}
			]],
		},
		blades = EasyPipeline.Compute{
			name = "grass_scatter_blades",
			DescriptorSetCount = 1,
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = descriptor_sets,
			block = compute_block,
			write = write_compute_block,
			shader = COMPUTE_GLSL .. [[
				void main() {
					uvec4 job = grass_jobs[gl_WorkGroupID.x];
					uint surface_index = job.x & 0xFFFFFFu;
					int level = int(job.x >> 24);
					GrassSurface s = grass_surfaces[surface_index];
					GrassTriangle t = grass_load_triangle(s, job.y);
					ivec2 tile = ivec2(job.zw);
					float cell_size = s.params.x;
					vec3 cam = compute.camera_position;
					vec2 a = t.p0.xz;
					vec2 e0 = t.p1.xz - a;
					vec2 e1 = t.p2.xz - a;
					float det = e0.x * e1.y - e1.x * e0.y;

					if (abs(det) < 1e-10) return;

					float inv_det = 1.0 / det;
					int step_cells = 1 << level;
					int per_axis = GRASS_TILE_CELLS >> level;
					int albedo_texture = int(s.info.z);
					vec2 packed_normal = grass_oct_encode(t.normal);
					uint normal_bits = (uint(packed_normal.x * 255.0 + 0.5) << 16) | (uint(packed_normal.y * 255.0 + 0.5) << 24);

					for (int n = int(gl_LocalInvocationID.x); n < per_axis * per_axis; n += 64) {
						ivec2 cell = tile * GRASS_TILE_CELLS + ivec2(n % per_axis, n / per_axis) * step_cells;
						int lx = cell.x == 0 ? GRASS_MAX_LEVEL : findLSB(cell.x);
						int lz = cell.y == 0 ? GRASS_MAX_LEVEL : findLSB(cell.y);
						int cell_level = min(min(lx, lz), GRASS_MAX_LEVEL);
						uint h = grass_hash2(cell);
						float level_scale = exp2(-2.0 * float(cell_level + 1));
						float priority = cell_level == GRASS_MAX_LEVEL ?
							grass_unorm(h) * level_scale * 4.0 :
							level_scale * (1.0 + 3.0 * grass_unorm(h));
						h = grass_pcg(h);
						vec2 jitter = vec2(grass_unorm(h), grass_unorm(grass_pcg(h ^ 0x68bc21ebu)));
						vec2 xz = (vec2(cell) + jitter * float(1 << cell_level)) * cell_size;
						vec2 q = xz - a;
						float w1 = (q.x * e1.y - e1.x * q.y) * inv_det;
						float w2 = (e0.x * q.y - q.x * e0.y) * inv_det;
						float w0 = 1.0 - w1 - w2;

						if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) continue;

						vec3 root = t.p0 * w0 + t.p1 * w1 + t.p2 * w2;
						float d = distance(root, cam);
						float lod_keep = grass_keep(d);
						// low frequency patches of thinner and thicker grass, so a
						// uniform density doesn't read as a carpet
						float patches = grass_fbm(xz * 0.09);
						float density = mix(0.3, 1.0, smoothstep(0.25, 0.65, patches));
						float keep = lod_keep * density;

						if (priority >= keep) continue;

						h = grass_pcg(h + 0x2545f491u);
						float r0 = grass_unorm(h);
						h = grass_pcg(h);
						float r1 = grass_unorm(h);
						h = grass_pcg(h);
						float r2 = grass_unorm(h);
						float fade = clamp((keep - priority) / (keep * 0.3), 0.0, 1.0);
						float tall = grass_fbm(xz * 0.31 + vec2(31.7, 5.3));
						float height = s.params.y * mix(1.0 - s.params.z, 1.0 + s.params.z, r0) * mix(0.55, 1.3, tall) * mix(0.7, 1.0, density) * fade;
						// fewer blades further away, so each covers more
						float width = s.params.w * clamp(inversesqrt(max(lod_keep, 0.0001)), 1.0, 5.0);

						if (!grass_sphere_visible(root + vec3(0.0, height * 0.5, 0.0), height * 0.6 + width)) continue;

						// neighbouring blades lean the same way in clumps
						float clump_angle = grass_value_noise(xz * 1.7 + vec2(-7.1, 3.3)) * 6.2831853 * 2.0;
						float facing = mix(r1 * 6.2831853, clump_angle, 0.5);
						vec2 uv = t.uv0 * w0 + t.uv1 * w1 + t.uv2 * w2;
						vec3 color = s.color.rgb;

						if (albedo_texture >= 0) {
							color *= textureLod(TEXTURE(albedo_texture), uv, 3.0).rgb;
						}

						float dry = smoothstep(0.45, 0.8, grass_fbm(xz * 0.05 + vec2(3.1, 11.9)));
						color = mix(color, color * vec3(1.35, 1.12, 0.6), dry * 0.6);
						color *= mix(0.8, 1.15, r2);
						uint slot;
						uint index;

						if (d < compute.near_distance) {
							slot = atomicAdd(grass_near_counter, 1u);

							if (slot >= GRASS_HALF_BLADES) continue;

							index = slot;
							atomicMax(grass_draw_near[1], slot + 1u);
						} else {
							slot = atomicAdd(grass_far_counter, 1u);

							if (slot >= GRASS_HALF_BLADES) continue;

							index = GRASS_HALF_BLADES + slot;
							atomicMax(grass_draw_far[1], slot + 1u);
						}

						grass_blades[index].root = vec4(root, height);
						grass_blades[index].data = uvec4(
							packHalf2x16(uv),
							packHalf2x16(vec2(width, facing)),
							surface_index | normal_bits,
							packUnorm4x8(vec4(sqrt(clamp(color, 0.0, 1.0)), r1 * 0.5 + 0.1))
						);
					}
				}
			]],
		},
	}
	return compute_passes
end

-- which surfaces grow grass is only looked for again when the scene or a
-- material's flags change
local surfaces = {}
local surfaces_key = nil
local surface_count = 0

local function collect_surfaces()
	local out = {}

	for _, component in ipairs(Visual.Instances) do
		for _, entry in ipairs(component:GetRenderEntries()) do
			local material = component:GetResolvedMaterial(entry)

			if material:GetGrass() then
				out[#out + 1] = {component = component, entry = entry, material = material}
			end
		end
	end

	return out
end

local function get_surfaces()
	local key = render3d.GetGPUCulling().scene_acceleration_generation .. ":" .. Material.flags_generation

	if key ~= surfaces_key then
		surfaces = collect_surfaces()
		surfaces_key = key
	end

	return surfaces
end

local function write_surface(out, surface, texture_index)
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

	ffi.cast(int32_ptr, out.info + 2)[0] = texture_index
	local color = material:GetColorMultiplier()
	out.color[0] = color.r
	out.color[1] = color.g
	out.color[2] = color.b
	out.color[3] = color.a
	out.params[0] = 1 / math.sqrt(material:GetGrassDensity())
	out.params[1] = material:GetGrassHeight()
	out.params[2] = material:GetGrassHeightVariance()
	out.params[3] = material:GetGrassWidth()
	local wind = material:GetWindDirection()
	local length = math.sqrt(wind.x * wind.x + wind.z * wind.z)
	out.wind[0] = wind.x / length
	out.wind[1] = wind.z / length
	out.wind[2] = 0.35
	out.wind[3] = 1.3
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

-- runs before the gbuffer begins rendering
function grass.Scatter(cmd)
	surface_count = 0

	if not grass.enabled then return end

	local candidates = get_surfaces()

	if not candidates[1] then return end

	local b = get_buffers()
	local passes = get_compute_passes()
	-- last frame's draws are done with the blades and their counts
	barrier(
		cmd,
		b.args,
		{"draw_indirect", "compute"},
		"transfer",
		{"indirect_command_read", "shader_read", "shader_write"},
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
	barrier(cmd, b.blades, "vertex", "compute", "shader_read", "shader_write")
	local camera = render3d.GetCamera():GetPosition()
	local ring_base = (system.GetFrameNumber() % grass.SURFACE_RING) * grass.MAX_SURFACES
	local reach = grass.max_distance

	for _, surface in ipairs(candidates) do
		if surface_count >= grass.MAX_SURFACES then break end

		local mesh = surface.entry.polygon3d:GetMesh()

		if mesh:IsValid() then
			local aabb = surface.component:GetWorldAABB()

			if
				camera.x > aabb.min_x - reach and
				camera.x < aabb.max_x + reach and
				camera.y > aabb.min_y - reach and
				camera.y < aabb.max_y + reach and
				camera.z > aabb.min_z - reach and
				camera.z < aabb.max_z + reach
			then
				local index = ring_base + surface_count
				write_surface(
					b.surface_data[index],
					surface,
					passes.blades:GetTextureIndex(surface.material:GetAlbedoTexture())
				)
				passes.tiles.surface_index = index
				passes.tiles.triangle_count = b.surface_data[index].info[0]

				if passes.tiles.triangle_count > 0 then
					passes.tiles:Dispatch(cmd, math.ceil(passes.tiles.triangle_count / 64), 1, 1, 1)
				end

				surface_count = surface_count + 1
			end
		end
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
	passes.blades:DispatchIndirect(cmd, b.args, 0, 1)
	barrier(
		cmd,
		b.args,
		"compute",
		"draw_indirect",
		"shader_write",
		"indirect_command_read"
	)
	barrier(cmd, b.blades, "compute", "vertex", "shader_write", "shader_read")
end

-- inside the gbuffer's rendering, after the scene's geometry
function grass.Draw(pipeline, cmd)
	if not grass.enabled or surface_count == 0 then return end

	local b = get_buffers()
	pipeline:UploadConstants()
	cmd:SetCullMode("none")
	cmd:SetPolygonMode(render3d.IsWireframeDebugMode() and "line" or "fill")
	cmd:DrawIndirect(b.args, ARGS_DRAW_NEAR_OFFSET, 1)
	cmd:DrawIndirect(b.args, ARGS_DRAW_FAR_OFFSET, 1)
end

-- the gbuffer's color and depth formats come from its base pass
function grass.BuildDrawPass(gbuffer_pass)
	local grass_block = {
		name = "grass_data",
		binding_index = 3,
		block = {
			render3d.camera_block,
			render3d.prev_camera_block,
			{
				{"time", "float"},
				{"prev_time", "float"},
			},
		},
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			render3d.WritePreviousCameraBlock(self, block)
			block.time = system.GetElapsedTime()
			block.prev_time = render3d.GetPreviousElapsedTime()
			return block
		end,
		upload_scope = "frame",
	}
	return {
		name = "grass",
		draw_in_prerender = false,
		dont_create_framebuffers = true,
		ColorFormat = gbuffer_pass.ColorFormat,
		DepthFormat = gbuffer_pass.DepthFormat,
		Topology = "triangle_strip",
		CullMode = "none",
		FrontFace = orientation.FRONT_FACE,
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "less_or_equal",
		vertex = {
			outputs = {
				{"position", "vec3"},
				{"prev_position", "vec3"},
				{"normal", "vec3"},
				{"ground_normal", "vec3"},
				{"color", "vec3"},
				-- height along the blade, across it (-1 to 1)
				{"blade", "vec2"},
			},
			uniform_buffers = {grass_block},
			descriptor_sets = {
				storage_buffer(BINDING_SURFACES, "surfaces", "vertex"),
				storage_buffer(BINDING_BLADES, "blades", "vertex"),
			},
			custom_declarations = COMMON_GLSL .. [[
				layout(std430, set = 0, binding = ]] .. BINDING_BLADES .. [[) readonly buffer GrassBlades {
					GrassBlade grass_blades[];
				};
			]],
			shader = [[
				// a travelling wave along the wind with gusts rolling through it
				vec3 grass_wind(GrassSurface s, vec2 xz, float time, float seed) {
					vec2 dir = s.wind.xy;
					float gust = grass_value_noise(xz * 0.07 - dir * time * 0.9);
					float wave = sin(dot(xz, dir) * 0.8 - time * s.wind.w * 2.0 + seed * 3.0) * 0.5 + 0.5;
					float flutter = sin(time * 7.0 + seed * 40.0) * 0.08;
					float amount = s.wind.z * (0.25 + gust * gust * 1.6) * (0.6 + wave * 0.4);
					return vec3(dir.x, 0.0, dir.y) * amount + vec3(-dir.y, 0.0, dir.x) * flutter * amount;
				}

				// quadratic bezier from the root to the tip, lengthened back to
				// the blade's height after the wind pushes the tip
				void grass_curve(vec3 root, float height, vec3 facing, float lean, vec3 wind, out vec3 p1, out vec3 p2) {
					vec3 tip_dir = normalize(vec3(0.0, 1.0, 0.0) + facing * lean + wind);
					p2 = root + tip_dir * height;
					p1 = root + vec3(0.0, (p2.y - root.y) * 0.75, 0.0) + facing * lean * height * 0.15;
					float len = (2.0 * distance(root, p2) + distance(root, p1) + distance(p1, p2)) / 3.0;
					float scale = height / max(len, 0.0001);
					p1 = root + (p1 - root) * scale;
					p2 = root + (p2 - root) * scale;
				}

				vec3 grass_bezier(vec3 p0, vec3 p1, vec3 p2, float t) {
					float it = 1.0 - t;
					return p0 * it * it + p1 * 2.0 * it * t + p2 * t * t;
				}

				void main() {
					GrassBlade blade = grass_blades[gl_InstanceIndex];
					int segments = uint(gl_InstanceIndex) >= GRASS_HALF_BLADES ? GRASS_FAR_SEGMENTS : GRASS_NEAR_SEGMENTS;
					GrassSurface s = grass_surfaces[blade.data.z & 0xFFFFu];
					vec3 root = blade.root.xyz;
					float height = blade.root.w;
					vec2 width_facing = unpackHalf2x16(blade.data.y);
					vec4 color_lean = unpackUnorm4x8(blade.data.w);
					float seed = color_lean.a * 7.31;
					vec3 facing = vec3(cos(width_facing.y), 0.0, sin(width_facing.y));
					vec3 side = vec3(-facing.z, 0.0, facing.x);
					int vid = gl_VertexIndex;
					float t = vid >= segments * 2 ? 1.0 : float(vid >> 1) / float(segments);
					float across = vid >= segments * 2 ? 0.0 : float(vid & 1) * 2.0 - 1.0;
					float half_width = width_facing.x * 0.5 * (1.0 - pow(t, 1.4));
					vec3 p1, p2;
					grass_curve(root, height, facing, color_lean.a, grass_wind(s, root.xz, grass_data.time, seed), p1, p2);
					vec3 position = grass_bezier(root, p1, p2, t) + side * across * half_width;
					vec3 tangent = normalize(2.0 * (1.0 - t) * (p1 - root) + 2.0 * t * (p2 - p1));
					// rounded across the blade
					vec3 normal = normalize(normalize(cross(tangent, side)) + side * across * 0.4);
					vec3 prev_p1, prev_p2;
					grass_curve(root, height, facing, color_lean.a, grass_wind(s, root.xz, grass_data.prev_time, seed), prev_p1, prev_p2);
					out_position = position;
					out_prev_position = grass_bezier(root, prev_p1, prev_p2, t) + side * across * half_width;
					out_normal = normal;
					vec2 packed_normal = vec2((blade.data.z >> 16) & 0xFFu, blade.data.z >> 24) / 255.0;
					out_ground_normal = grass_oct_decode(packed_normal);
					out_color = color_lean.rgb * color_lean.rgb;
					out_blade = vec2(t, across);
					gl_Position = grass_data.projection * grass_data.view * vec4(position, 1.0);
				}
			]],
		},
		fragment = {
			uniform_buffers = {grass_block},
			shader = [[
				void main() {
					float t = in_blade.x;
					vec3 N = normalize(in_normal);
					vec3 V = grass_data.camera_position - in_position;
					float dist = length(V);

					if (dot(N, V) < 0.0) N = -N;

					// towards the ground's normal at the root and far away, where
					// a blade's own normal is mostly noise
					N = normalize(mix(N, in_ground_normal, 0.25 + (1.0 - t) * 0.25 + smoothstep(15.0, 60.0, dist) * 0.4));
					// darker towards the root up close. further away a root is a
					// pixel peeking between tips and reads as a black speck
					float far = smoothstep(4.0, 20.0, dist);
					vec3 albedo = in_color * mix(mix(0.75, 1.1, t), 1.0, far);
					set_alpha(1.0);
					set_albedo(albedo);
					set_normal(N * 0.5 + 0.5);
					set_metallic(0.0);
					// ggx alpha
					set_roughness(0.4);
					set_ao(mix(mix(0.5, 1.0, smoothstep(0.0, 0.7, t)), 0.85, far));
					set_specular(0.35);
					set_subsurface(1.0);
					set_transmission_blocking(0.25);
					set_transmission_view_dep(0.5);
					// the transmission color, when subsurface is set
					set_emissive(clamp(albedo * vec3(1.6, 1.9, 0.9), 0.0, 1.0));

					vec4 clip = grass_data.projection * grass_data.view * vec4(in_position, 1.0);
					vec4 prev_view_pos = grass_data.prev_view * vec4(in_prev_position, 1.0);
					vec4 prev_clip = grass_data.prev_projection * prev_view_pos;

					if (clip.w <= 0.0001 || prev_clip.w <= 0.0001) {
						set_velocity(vec2(0.0));
					} else {
						set_velocity((clip.xy / clip.w) * 0.5 - (prev_clip.xy / prev_clip.w) * 0.5);
					}

					set_prev_view_depth(-prev_view_pos.z);
				}
			]],
		},
	}
end

return grass
