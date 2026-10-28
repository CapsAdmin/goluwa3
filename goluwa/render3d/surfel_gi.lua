local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local surfel_gi = {}

event.AddListener("Render3DPassToggled", "surfel_gi", function(name, value)
	if name == "surfel_gi" and value then surfel_gi.ResetHistory() end
end)

surfel_gi.CASCADES = 4
surfel_gi.BASE_DIRECTIONS = 4
surfel_gi.SLOTS_PER_ROW = 256
surfel_gi.ATLAS_SLOTS_PER_ROW = 1024
surfel_gi.CASCADE_SHIFTS = {0, 2, 4, 5}
surfel_gi.PROBES = 8
surfel_gi.TOUCH_SAMPLES = 65536
surfel_gi.HIT_SAMPLES = 8192
surfel_gi.STATS_STRIDE = 16
surfel_gi.MAX_DIRTY_BOXES = 64
surfel_gi.MAX_LEVEL = 15

function surfel_gi.GetCapacity(c)
	return 2 ^ (surfel_gi.CAPACITY_BITS - surfel_gi.CASCADE_SHIFTS[c + 1])
end

function surfel_gi.GetOffset(c)
	local offset = 0

	for i = 0, c - 1 do
		offset = offset + surfel_gi.GetCapacity(i)
	end

	return offset
end

function surfel_gi.GetDirectionSide(c)
	return surfel_gi.BASE_DIRECTIONS * 2 ^ c
end

function surfel_gi.SetCapacity(capacity)
	surfel_gi.CAPACITY_BITS = math.floor(math.log(math.max(capacity, 4096)) / math.log(2) + 1e-6)
	surfel_gi.SLOT_COUNT = surfel_gi.GetOffset(surfel_gi.CASCADES)
	surfel_gi.SLOT_ROWS = math.ceil(surfel_gi.SLOT_COUNT / surfel_gi.SLOTS_PER_ROW)
	surfel_gi.ATLAS_WIDTH = surfel_gi.ATLAS_SLOTS_PER_ROW * surfel_gi.BASE_DIRECTIONS
	surfel_gi.ATLAS_HEIGHT = 0

	for c = 0, surfel_gi.CASCADES - 1 do
		surfel_gi.ATLAS_HEIGHT = surfel_gi.ATLAS_HEIGHT + surfel_gi.GetCapacity(c) / (
				surfel_gi.ATLAS_SLOTS_PER_ROW / 2 ^ c
			) * surfel_gi.GetDirectionSide(c)
	end
end

pvars.StartGroup("Lighting", "Surfel GI", {store = false, prefix = "surfel_"})
local capacity = pvars.Setup2{
	key = "surfel_capacity",
	default = 131072,
	integer = true,
	min = 4096,
	max = 262144,
	help = "most cascade 0 surfels, rounded down to a power of two. the coarser cascades hold 1/4, 1/16 and 1/32 of it (their cells are twice as large each, but small objects, edges and normal buckets keep needing their own coarse cells, so they shrink slower than the area). a full table fails to place new surfels (black patches in big or detailed views). changing it starts the gi over",
	callback = function(value, initial)
		if initial then return end

		surfel_gi.SetCapacity(value)
		local owner = render3d.pipelines and render3d.pipelines.surfel_update

		if not owner or not owner.surfel_resources then return end

		render.GetDevice():WaitIdle()

		for _, resource in ipairs(owner.owned_textures) do
			resource:Remove()
		end

		owner.owned_textures = nil
		owner.surfel_resources = nil
	end,
}
surfel_gi.SetCapacity(capacity:Get())
local cell_size = pvars.Setup2{
	key = "surfel_cell_size",
	default = 0.25,
	min = 0.02,
	help = "meters across a cascade 0 surfel near the camera, each cascade's surfels are twice as large as the one before",
}
local lod_distance = pvars.Setup2{
	key = "surfel_lod_distance",
	default = 6,
	min = 0.5,
	help = "meters from the camera where surfels start to grow, past it they are as large as the distance over this times the cell size, so they cover about the same part of the screen",
}
local interval = pvars.Setup2{
	key = "surfel_interval",
	default = 2,
	min = 0.25,
	help = "how far the rays of cascade 0 reach, in its cells. each cascade reaches 4 times as far, the last cascade's rays reach to the end of the scene",
}
local hysteresis = pvars.Setup2{
	key = "surfel_hysteresis",
	default = 0.85,
	min = 0,
	max = 0.995,
	help = "how much of a surfel direction's history survives a frame, a cascade that updates every n frames keeps this to the power n per update. a new surfel weighs its first updates 1/n",
}
local lifetime = pvars.Setup2{
	key = "surfel_lifetime",
	default = 30,
	integer = true,
	min = 8,
	help = "frames a surfel the screen no longer touches keeps being traced at its full rate, after that it is refreshed 16 times less often (lookups still read it) and its slot can be taken by a new one",
}
local hit_spawns = pvars.Setup2{
	key = "surfel_hit_spawns",
	default = true,
	help = "what the rays of the surfels the screen touches hit gets surfels too, so walls behind the camera are lit in reflections and bounces before they are seen. off only the screen spawns surfels",
}
local update_interval_max = pvars.Setup2{
	key = "surfel_update_interval_max",
	default = 4,
	integer = true,
	min = 1,
	max = 16,
	help = "cascade n traces every 2^n frames, at most this many",
}
local ray_budget = pvars.Setup2{
	key = "surfel_ray_budget",
	default = 2000000,
	integer = true,
	min = 100000,
	help = "rays the surfels may trace per frame, when the due surfels would trace more, surfels are skipped at random until it fits (their history is told the longer gap). new surfels and surfels around moved instances are never skipped",
}
local fog_gather_distance = pvars.Setup2{
	key = "surfel_fog_gather_distance",
	default = 100,
	min = 1,
	help = "meters from the camera the fog traces its own rays for surfel gi, past it (faded over the last quarter) the fog uses the sky ambient like it does outside the surfels' range",
}
local strength = pvars.Setup2{
	key = "surfel_strength",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the light the surfels give every surface, the surfels' own bounces are not scaled",
}
local max_distance = pvars.Setup2{
	key = "surfel_max_distance",
	default = 2000,
	min = 1,
	help = "meters from the camera past which nothing gets surfels and the light is the sky's",
}
local max_ray_distance = pvars.Setup2{
	key = "surfel_max_ray_distance",
	default = 4000,
	min = 1,
	help = "how far the rays of the last cascade travel before they see the sky",
}
local RESOLVE_MEGAPIXELS = {["0.25mp"] = 0.25, ["0.5mp"] = 0.5, ["1mp"] = 1, native = math.huge}
local resolve_resolution = pvars.Setup2{
	key = "surfel_resolve_resolution",
	default = "native",
	enums = {"0.25mp", "0.5mp", "1mp", "native"},
	help = "the pixel count the surfel gi seen by the screen is resolved at, in megapixels, it is upsampled to the screen with depth and normal weights",
	callback = function()
		local resolve = render3d.pipelines and render3d.pipelines.surfel_resolve

		if resolve then resolve:RecreateFramebuffers() end
	end,
}
local DEBUG = {off = 0, cells = 1, coverage = 2, sky = 3}
local debug = pvars.Setup2{
	key = "surfel_debug",
	default = "off",
	enums = {"off", "cells", "coverage", "sky"},
	help = "show the cascade 0 surfel a pixel reads (a colour per surfel), whether its lookup found surfels at any level (red falls back to the sky), or their sky visibility",
}
local debug_gi = pvars.Setup2{
	key = "surfel_debug_gi",
	default = false,
	help = "show only the gi irradiance",
}
surfel_gi.FEATURES = {
	{
		"FILL",
		"surfel_fill",
		"a lookup that finds too few surfels at its level fills the rest from the next two coarser levels before falling back to the sky",
	},
	{
		"FILL_VISIBILITY",
		"surfel_fill_visibility",
		"the coarser level fill traces a ray to each surfel it uses and skips the hidden ones (coarse cells reach across walls)",
	},
	{
		"NEIGHBOUR_MASKS",
		"surfel_neighbour_masks",
		"each surfel traces rays to its 26 neighbouring cells' surfels, and lookups and the filter skip the neighbours it cannot see",
	},
	{
		"OWN_CHECK",
		"surfel_own_check",
		"lookups at ray hits trace a ray to their own cell's surfel, and if it is hidden (the other side of a thin wall) trace every neighbour they use",
	},
	{
		"MERGE_VISIBILITY",
		"surfel_merge_visibility",
		"a cascade only merges the coarser surfels a short ray from the surfel reaches",
	},
	{
		"STICKY_POSITIONS",
		"surfel_sticky_positions",
		"a surfel only moves to a screen sample its current position can see, so a cell straddling a wall stays on one side",
	},
	{
		"POSITION_CONFIRM",
		"surfel_position_confirm",
		"a surfel the screen keeps landing on keeps its position instead of being re-elected every frame (far large cells flash otherwise)",
	},
	{
		"BURIED",
		"surfel_buried",
		"a surfel whose rays mostly hit backfaces (its position is inside geometry) is moved and restarted",
	},
	{
		"CURVATURE_LIFT",
		"surfel_curvature_lift",
		"visibility rays between surfels are lifted by how much their normals differ, so they do not clip curved surfaces (lines across spheres otherwise)",
	},
	{
		"FILTER",
		"surfel_filter",
		"the irradiance is averaged with the visible neighbouring surfels twice before lookups read it",
	},
	{
		"IDLE_REFRESH",
		"surfel_idle_refresh",
		"surfels no longer touched keep being refreshed 16 times less often instead of freezing with their old light",
	},
	{
		"MOVED_RESET",
		"surfel_moved_reset",
		"surfels around instances that moved this frame drop most of their history, update at once and retest their neighbours",
	},
	{
		"CHANGE_DETECTOR",
		"surfel_change_detector",
		"a surfel whose new rays keep disagreeing with its history takes a larger step toward them",
	},
	{
		"GRID_SHIFT",
		"surfel_grid_shift",
		"cells are shifted half a cell along the normal bucket, so surfaces on round coordinates sit in the middle of a cell instead of on its boundary",
		true,
	},
	{
		"RAYS_FROM_ORIGIN",
		"surfel_rays_from_origin",
		"every cascade's rays start at the surfel instead of where the finer cascade's ended, so thin walls inside the finer interval are not skipped",
	},
	{
		"SCREEN_PRIORITY",
		"surfel_screen_priority",
		"a screen sample may evict a surfel the screen no longer touches even while its rays still keep it alive",
	},
	{
		"TOUCH_SCRAMBLE",
		"surfel_touch_scramble",
		"touch threads take screen cells in a scrambled order, so a full table is not filled by the top rows of the screen",
	},
}

for i, feature in ipairs(surfel_gi.FEATURES) do
	feature.bit = bit.lshift(1, i - 1)
	feature.var = pvars.Setup2{
		key = feature[2],
		default = true,
		help = feature[3],
		callback = feature[4] and
			function(value, initial)
				if not initial then surfel_gi.ResetHistory() end
			end or
			nil,
	}
end

function surfel_gi.GetFeatures()
	local features = 0

	for _, feature in ipairs(surfel_gi.FEATURES) do
		if feature.var:Get() then features = bit.bor(features, feature.bit) end
	end

	return features
end

pvars.EndGroup()

function surfel_gi.GetFogGatherDistance()
	return fog_gather_distance:Get()
end

function surfel_gi.GetDebugMode()
	return DEBUG[debug:Get()]
end

function surfel_gi.IsDebugGI()
	return debug_gi:Get()
end

function surfel_gi.GetResolveScale()
	local size = render.GetRenderImageSize()
	return math.min(
		1,
		math.sqrt(RESOLVE_MEGAPIXELS[resolve_resolution:Get()] * 1000000 / (size.x * size.y))
	)
end

function surfel_gi.GetTouchSize()
	local size = render.GetRenderImageSize()
	local width = math.max(1, math.floor(math.sqrt(surfel_gi.TOUCH_SAMPLES * size.x / size.y)))
	return width, math.max(1, math.floor(surfel_gi.TOUCH_SAMPLES / width))
end

function surfel_gi.GetUpdateInterval(c)
	return math.min(2 ^ c, update_interval_max:Get())
end

function surfel_gi.ResetHistory()
	surfel_gi.reset_requested = true
end

do
	local state = {frame = -1, reset = false, dirty = {}}
	local dirty_queue = bridge.CreateDirtyQueue()

	function surfel_gi.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		state.features = surfel_gi.GetFeatures()
		state.reset = surfel_gi.reset_requested == true
		surfel_gi.reset_requested = false
		local all, boxes = bridge.ConsumeDirty(dirty_queue)
		state.dirty = all and {} or boxes
		return state
	end
end

function surfel_gi.GetResources()
	local owner = render3d.pipelines.surfel_update

	if owner.surfel_resources then return owner.surfel_resources end

	local function texture(name, width, height, format)
		local tex = Texture.New{
			width = width,
			height = height,
			format = format,
			image = {usage = {"storage", "sampled"}},
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		tex:SetDebugName("surfel " .. name)
		return tex
	end

	local resources = {
		table = render.CreateBuffer{
			byte_size = surfel_gi.SLOT_COUNT * 40,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "surfel_table",
		},
		stats = render.CreateBuffer{
			byte_size = 4 * surfel_gi.STATS_STRIDE * 4,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "surfel_stats",
			data = ffi.new("uint32_t[?]", 4 * surfel_gi.STATS_STRIDE),
		},
		hits = render.CreateBuffer{
			byte_size = 32 + surfel_gi.HIT_SAMPLES * 16,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "surfel_hits",
		},
		key = texture("keys", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r32g32b32a32_sfloat"),
		surfel = texture("positions", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r32g32b32a32_sfloat"),
		state = texture("state", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r16g16b16a16_sfloat"),
		atlas = texture("radiance", surfel_gi.ATLAS_WIDTH, surfel_gi.ATLAS_HEIGHT, "r16g16b16a16_sfloat"),
		irradiance = texture(
			"irradiance",
			surfel_gi.SLOTS_PER_ROW * 4,
			surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW,
			"r16g16b16a16_sfloat"
		),
		emitter = texture(
			"emitter irradiance",
			surfel_gi.SLOTS_PER_ROW * 4,
			surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW,
			"r16g16b16a16_sfloat"
		),
		irradiance_raw = texture(
			"unfiltered irradiance",
			surfel_gi.SLOTS_PER_ROW * 4,
			surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW,
			"r16g16b16a16_sfloat"
		),
		irradiance_blurred = texture(
			"half filtered irradiance",
			surfel_gi.SLOTS_PER_ROW * 4,
			surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW,
			"r16g16b16a16_sfloat"
		),
	}
	owner.owned_textures = {
		resources.table,
		resources.hits,
		resources.stats,
		resources.key,
		resources.surfel,
		resources.state,
		resources.atlas,
		resources.irradiance,
		resources.emitter,
		resources.irradiance_raw,
		resources.irradiance_blurred,
	}
	owner.surfel_resources = resources
	surfel_gi.GetFrameState().reset = true
	return resources
end

do
	local Pointer = ffi.typeof("uint32_t *")
	local stats = {}

	function surfel_gi.ReadStats()
		local buffer = surfel_gi.GetResources().stats
		local values = ffi.cast(Pointer, buffer:Map(0, buffer:GetSize())) + (
				system.GetFrameNumber() + 2
			) % 4 * surfel_gi.STATS_STRIDE

		for c = 0, surfel_gi.CASCADES - 1 do
			stats[c + 1] = stats[c + 1] or {}
			stats[c + 1].alive = values[c]
			stats[c + 1].failed = values[4 + c]
			stats[c + 1].screen = values[8 + c]
			stats[c + 1].capacity = surfel_gi.GetCapacity(c)
		end

		stats.hit_samples = values[12]
		return stats
	end
end

function surfel_gi.HasResources()
	local owner = render3d.pipelines and render3d.pipelines.surfel_update
	return owner ~= nil and owner.surfel_resources ~= nil
end

function surfel_gi.GetBlockLayout()
	return {
		{"surfel_key_tex", "int"},
		{"surfel_tex", "int"},
		{"surfel_irradiance_tex", "int"},
		{"surfel_camera", "vec4"},
		{"surfel_params", "vec4"},
		{"surfel_features", "int"},
		{"surfel_capacity_bits", "int"},
	}
end

function surfel_gi.WriteBlock(self, block, active)
	local resources = active and surfel_gi.HasResources() and surfel_gi.GetResources() or nil
	block.surfel_key_tex = resources and self:GetTextureIndex(resources.key) or -1
	block.surfel_tex = resources and self:GetTextureIndex(resources.surfel) or -1
	block.surfel_irradiance_tex = resources and self:GetTextureIndex(resources.irradiance) or -1
	local camera = render3d.GetCamera():GetPosition()
	block.surfel_camera[0] = camera.x
	block.surfel_camera[1] = camera.y
	block.surfel_camera[2] = camera.z
	block.surfel_camera[3] = max_distance:Get()
	block.surfel_params[0] = cell_size:Get()
	block.surfel_params[1] = lod_distance:Get()
	block.surfel_params[2] = strength:Get()
	block.surfel_params[3] = 0
	block.surfel_features = surfel_gi.GetFrameState().features
	block.surfel_capacity_bits = surfel_gi.CAPACITY_BITS
	return block
end

function surfel_gi.GetPassBlockLayout()
	return {
		{"surfel_touch_size", "vec2"},
		{"surfel_frame", "int"},
		{"surfel_cascade", "int"},
		{"surfel_reset", "int"},
		{"surfel_lifetime", "int"},
		{"surfel_update_interval_max", "int"},
		{"surfel_debug", "int"},
		{"surfel_hit_spawns", "int"},
		{"surfel_hysteresis", "float"},
		{"surfel_interval", "float"},
		{"surfel_max_ray_distance", "float"},
		{"surfel_cell_size", "float"},
		{"surfel_lod_distance", "float"},
		{"surfel_max_distance", "float"},
		{"surfel_ray_budget", "float"},
		{"surfel_state_tex", "int"},
		{"surfel_atlas_tex", "int"},
		{"surfel_emitter_tex", "int"},
		{"surfel_filter_tex", "int"},
		{"surfel_bent_normal_tex", "int"},
		{"surfel_features", "int"},
		{"surfel_capacity_bits", "int"},
		{"surfel_dirty_count", "int"},
		{"surfel_dirty_min", "vec4", surfel_gi.MAX_DIRTY_BOXES},
		{"surfel_dirty_max", "vec4", surfel_gi.MAX_DIRTY_BOXES},
	}
end

function surfel_gi.WritePassBlock(self, block)
	local state = surfel_gi.GetFrameState()
	local touch_width, touch_height = surfel_gi.GetTouchSize()
	block.surfel_touch_size[0] = touch_width
	block.surfel_touch_size[1] = touch_height
	block.surfel_frame = state.frame
	block.surfel_cascade = self.surfel_cascade or 0
	block.surfel_reset = state.reset and 1 or 0
	block.surfel_lifetime = lifetime:Get()
	block.surfel_update_interval_max = update_interval_max:Get()
	block.surfel_debug = DEBUG[debug:Get()]
	block.surfel_hit_spawns = hit_spawns:Get() and 1 or 0
	block.surfel_hysteresis = hysteresis:Get()
	block.surfel_interval = interval:Get()
	block.surfel_max_ray_distance = max_ray_distance:Get()
	block.surfel_cell_size = cell_size:Get()
	block.surfel_lod_distance = lod_distance:Get()
	block.surfel_max_distance = max_distance:Get()
	block.surfel_ray_budget = ray_budget:Get()
	block.surfel_state_tex = -1
	block.surfel_atlas_tex = -1
	block.surfel_emitter_tex = -1
	block.surfel_filter_tex = -1
	block.surfel_bent_normal_tex = -1
	block.surfel_features = state.features
	block.surfel_capacity_bits = surfel_gi.CAPACITY_BITS
	local dirty = state.dirty
	block.surfel_dirty_count = math.min(#dirty, surfel_gi.MAX_DIRTY_BOXES)

	for i = 1, block.surfel_dirty_count do
		local box = dirty[i]
		block.surfel_dirty_min[i - 1][0] = box[1]
		block.surfel_dirty_min[i - 1][1] = box[2]
		block.surfel_dirty_min[i - 1][2] = box[3]
		block.surfel_dirty_max[i - 1][0] = box[4]
		block.surfel_dirty_max[i - 1][1] = box[5]
		block.surfel_dirty_max[i - 1][2] = box[6]
	end

	return block
end

function surfel_gi.GetDefinesGLSL()
	return glsl_common.GetHashGLSL() .. glsl_common.GetOctahedralGLSL() .. string.format(
			[[
		#define SURFEL_CASCADES %d
		#define SURFEL_BASE_DIRECTIONS %d
		#define SURFEL_SLOTS_PER_ROW %d
		#define SURFEL_ATLAS_SLOTS_PER_ROW %d
		#define SURFEL_PROBES %d
		#define SURFEL_MAX_LEVEL %d
		#define SURFEL_TOP_LEVEL (SURFEL_MAX_LEVEL - SURFEL_CASCADES)
		#ifndef SURFEL_BLOCK
		#define SURFEL_BLOCK surfel_data
		#endif
		#define SURFEL_FEATURES (SURFEL_BLOCK.surfel_features)
		#define SURFEL_CAPACITY_BITS (SURFEL_BLOCK.surfel_capacity_bits)
		const int SURFEL_CASCADE_SHIFTS[SURFEL_CASCADES] = int[](%s);
		#define SURFEL_SLOT_COUNT surfel_offset(SURFEL_CASCADES)
		#define SURFEL_ON(feature) ((SURFEL_FEATURES & (feature)) != 0)
		%s
		#ifndef saturate
		#define saturate(x) clamp(x, 0.0, 1.0)
		#endif

		int surfel_capacity(int c) {
			return 1 << (SURFEL_CAPACITY_BITS - SURFEL_CASCADE_SHIFTS[c]);
		}

		int surfel_offset(int c) {
			int offset = 0;

			for (int i = 0; i < c; i++) offset += surfel_capacity(i);

			return offset;
		}

		int surfel_side(int c) {
			return SURFEL_BASE_DIRECTIONS << c;
		}

		ivec2 surfel_slot_texel(int g) {
			return ivec2(g %% SURFEL_SLOTS_PER_ROW, g / SURFEL_SLOTS_PER_ROW);
		}

		ivec2 surfel_atlas_texel(int c, int local_slot, ivec2 dir) {
			int side = surfel_side(c);
			int per_row = SURFEL_ATLAS_SLOTS_PER_ROW >> c;
			int row_offset = 0;

			for (int i = 0; i < c; i++) {
				row_offset += surfel_capacity(i) / (SURFEL_ATLAS_SLOTS_PER_ROW >> i) * surfel_side(i);
			}

			return ivec2((local_slot %% per_row) * side, (local_slot / per_row) * side + row_offset) + dir;
		}

		ivec2 surfel_irradiance_texel(int g, int i) {
			return ivec2((g %% SURFEL_SLOTS_PER_ROW) * 4 + i, g / SURFEL_SLOTS_PER_ROW);
		}

		uint surfel_key_hash(ivec3 cell, int packed, int c) {
			uvec4 h = pcg4d(uvec4(uvec3(cell), uint(packed) | (uint(c) << 8u)));
			return max(h.x ^ h.y ^ h.z ^ h.w, 1u);
		}

		int surfel_pack(int level, int bucket) {
			return level * 8 + bucket + 1;
		}

		int surfel_packed_level(int packed) {
			return (packed - 1) / 8;
		}

		int surfel_packed_bucket(int packed) {
			return (packed - 1) %% 8;
		}

		float surfel_pack_normal(vec3 n) {
			uvec2 q = uvec2(clamp((oct_encode(n) * 0.5 + 0.5) * 4095.0 + 0.5, vec2(0.0), vec2(4095.0)));
			return float(q.x | (q.y << 12u));
		}

		vec3 surfel_unpack_normal(float packed) {
			uint v = uint(packed);
			return oct_decode(vec2(v & 4095u, v >> 12u) / 4095.0 * 2.0 - 1.0);
		}

		// a straight ray between two points lifted off a curved surface clips it once they are far apart, lift both by about twice the bulge of a circle through them
		float surfel_curvature_lift(vec3 a, vec3 a_N, vec3 b, vec3 b_N) {
			return SURFEL_ON(SURFEL_FEATURE_CURVATURE_LIFT) ? distance(a, b) * length(a_N - b_N) * 0.25 : 0.0;
		}

		vec3 surfel_bucket_weights(vec3 N) {
			return max(abs(N) - 0.4, vec3(0.0));
		}

		int surfel_bucket(int axis, float n) {
			return axis * 2 + (n < 0.0 ? 1 : 0);
		}

		// surfaces on round coordinates lie exactly on cell boundaries along their normal, half a cell of shift puts them in the middle of a cell
		vec3 surfel_cell_position(vec3 P, int bucket, float size) {
			vec3 offset = vec3(0.0);
			offset[bucket / 2] = SURFEL_ON(SURFEL_FEATURE_GRID_SHIFT) ? (bucket %% 2 == 0 ? 0.5 : -0.5) * size : 0.0;
			return (P + offset) / size;
		}

		float surfel_lod(vec3 P, vec3 camera, float lod_distance) {
			return log2(max(distance(P, camera) / lod_distance, 1.0));
		}

		vec3 surfel_texel_direction(int side, vec2 texel) {
			return oct_decode(texel / float(side) * 2.0 - 1.0);
		}
	]],
			surfel_gi.CASCADES,
			surfel_gi.BASE_DIRECTIONS,
			surfel_gi.SLOTS_PER_ROW,
			surfel_gi.ATLAS_SLOTS_PER_ROW,
			surfel_gi.PROBES,
			surfel_gi.MAX_LEVEL,
			table.concat(surfel_gi.CASCADE_SHIFTS, ", "),
			surfel_gi.GetFeatureDefinesGLSL()
		)
end

function surfel_gi.GetFeatureDefinesGLSL()
	local lines = {}

	for _, feature in ipairs(surfel_gi.FEATURES) do
		lines[#lines + 1] = "#define SURFEL_FEATURE_" .. feature[1] .. " " .. feature.bit
	end

	return table.concat(lines, "\n\t\t")
end

function surfel_gi.GetLookupGLSL()
	return "#define SURFEL_BLOCK ddgi_data\n" .. surfel_gi.GetDefinesGLSL() .. [[

		float surfel_cell_size(int level) {
			return ddgi_data.surfel_params.x * exp2(float(level));
		}

		int surfel_find(ivec3 cell, int packed, int c) {
			int mask = surfel_capacity(c) - 1;
			int offset = surfel_offset(c);
			uint h = surfel_key_hash(cell, packed, c);
			vec4 want = vec4(vec3(cell), float(packed));

			for (int k = 0; k < SURFEL_PROBES; k++) {
				int g = offset + int((h + uint(k)) & uint(mask));
				vec4 key = texelFetch(TEXTURE(ddgi_data.surfel_key_tex), surfel_slot_texel(g), 0);

				if (key == want) return g;

				if (key.w == 0.0) return -1;
			}

			return -1;
		}

		bool surfel_in_range(vec3 P) {
			return ddgi_data.surfel_irradiance_tex >= 0 && distance(P, ddgi_data.surfel_camera.xyz) < ddgi_data.surfel_camera.w;
		}

		uint surfel_hidden_mask(int g) {
			uint low = uint(texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 1), 0).a);
			uint middle = uint(texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 2), 0).a);
			uint high = uint(texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 3), 0).a);
			return low | (middle << 9u) | (high << 18u);
		}

		vec3 surfel_evaluate(int g, vec3 L, vec4 a) {
			vec3 bx = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 1), 0).rgb;
			vec3 by = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 2), 0).rgb;
			vec3 bz = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 3), 0).rgb;
			return max(a.rgb + bx * L.x + by * L.y + bz * L.z, vec3(0.0));
		}

		vec4 surfel_sample_level(vec3 P, vec3 N, vec3 L, vec3 L2, int level, bool surface, bool check_visibility, out float weight, out vec3 second) {
			float size = surfel_cell_size(level);
			vec3 buckets = surfel_bucket_weights(N);
			vec4 sum = vec4(0.0);
			vec3 sum2 = vec3(0.0);
			float found = 0.0;
			float possible = 0.0;

			for (int axis = 0; axis < 3; axis++) {
				if (buckets[axis] <= 0.0) continue;

				int bucket = surfel_bucket(axis, N[axis]);
				int packed = surfel_pack(level, bucket);
				vec3 cell_position = surfel_cell_position(P, bucket, size);
				vec3 grid = cell_position - 0.5;
				ivec3 base = ivec3(floor(grid));
				vec3 f = grid - vec3(base);
				ivec3 own = ivec3(floor(cell_position));
				uint hidden = 0u;

				bool check_level = check_visibility && SURFEL_ON(SURFEL_FEATURE_FILL_VISIBILITY);
				bool own_hidden = false;

				if (surface) {
					int own_slot = surfel_find(own, packed, 0);

					if (own_slot >= 0) {
						hidden = SURFEL_ON(SURFEL_FEATURE_NEIGHBOUR_MASKS) ? surfel_hidden_mask(own_slot) : 0u;
						#if defined(DDGI_VISIBILITY_RAYS) && !defined(SURFEL_SCREEN_LOOKUP)
						vec4 own_surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(own_slot), 0);

						vec3 own_N = surfel_unpack_normal(own_surfel.w);
						float own_lift = surfel_curvature_lift(P, N, own_surfel.xyz, own_N);

						if (SURFEL_ON(SURFEL_FEATURE_OWN_CHECK) && ddgi_probe_hidden(P + N * own_lift, N, own_surfel.xyz + own_N * (0.01 + 0.05 * size + own_lift), size)) {
							hidden = 0u;
							own_hidden = true;
							check_level = true;
						}
						#endif
					}
				}

				for (int i = 0; i < 8; i++) {
					ivec3 o = ivec3(i & 1, (i >> 1) & 1, i >> 2);
					vec3 k = mix(1.0 - f, f, vec3(o));
					float w = k.x * k.y * k.z * buckets[axis];
					possible += w;

					if (w <= 0.0) continue;

					ivec3 delta = base + o - own;
					int neighbour = (delta.x + 1) + (delta.y + 1) * 3 + (delta.z + 1) * 9;

					if (neighbour == 13 ? own_hidden : (hidden & (1u << uint(neighbour < 13 ? neighbour : neighbour - 1))) != 0u) continue;

					int g = surfel_find(base + o, packed, 0);

					if (g < 0) continue;

					if (surface) {
						vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(g), 0);
						vec3 surfel_N = surfel_unpack_normal(surfel.w);
						w *= saturate(1.5 - abs(dot(P - surfel.xyz, surfel_N)) / size) * smoothstep(0.0, 0.5, dot(surfel_N, N));

						if (w <= 0.0) continue;
					}

					#ifdef DDGI_VISIBILITY_RAYS
					if (check_level) {
						vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(g), 0);

						vec3 neighbour_N = surfel_unpack_normal(surfel.w);
						float lift = surfel_curvature_lift(P, N, surfel.xyz, neighbour_N);

						if (ddgi_probe_hidden(P + N * lift, N, surfel.xyz + neighbour_N * (0.01 + 0.05 * size + lift), size)) continue;
					}
					#endif

					vec4 a = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 0), 0);
					sum += vec4(surfel_evaluate(g, L, a), a.a) * w;
					sum2 += surfel_evaluate(g, L2, a) * w;
					found += w;
				}
			}

			weight = found / max(possible, 1e-6);
			second = sum2 / max(found, 1e-6);
			return sum / max(found, 1e-6);
		}

		vec4 surfel_sample_irradiance_pair(vec3 P, vec3 N, vec3 L, vec3 L2, bool surface, int level_offset, out float weight, out vec4 second) {
			weight = 0.0;
			second = vec4(0.0);

			if (!surfel_in_range(P)) return vec4(0.0);

			float lod = min(surfel_lod(P, ddgi_data.surfel_camera.xyz, ddgi_data.surfel_params.y) + float(level_offset), float(SURFEL_TOP_LEVEL));
			int level = int(lod);
			float blend = level < SURFEL_TOP_LEVEL ? smoothstep(0.0, 1.0, lod - float(level)) : 0.0;
			float fine_coverage;
			vec3 fine_second;
			vec4 fine = surfel_sample_level(P, N, L, L2, level, surface, false, fine_coverage, fine_second);
			float filled = fine_coverage * (1.0 - blend);
			vec4 result = fine * filled;
			vec3 second_rgb = fine_second * filled;

			if (blend > 0.0) {
				float coverage;
				vec3 coarse_second;
				vec4 coarse = surfel_sample_level(P, N, L, L2, level + 1, surface, false, coverage, coarse_second);
				float share = coverage * blend;
				result += coarse * share;
				second_rgb += coarse_second * share;
				filled += share;
			}

			for (int coarser = level + 1; SURFEL_ON(SURFEL_FEATURE_FILL) && coarser <= min(level + 2, SURFEL_TOP_LEVEL) && filled < 0.999; coarser++) {
				float coverage;
				vec3 coarse_second;
				vec4 coarse = surfel_sample_level(P, N, L, L2, coarser, surface, true, coverage, coarse_second);
				float share = coverage * (1.0 - filled);
				result += coarse * share;
				second_rgb += coarse_second * share;
				filled += share;
			}

			if (filled <= 0.0) return vec4(0.0);

			result /= filled;
			second_rgb /= filled;
			weight = 1.0;
			#ifndef SURFEL_UNSCALED
			result.rgb *= ddgi_data.surfel_params.z;
			second_rgb *= ddgi_data.surfel_params.z;
			#endif
			second = vec4(second_rgb, result.a);
			return result;
		}
	]]
end

return surfel_gi
