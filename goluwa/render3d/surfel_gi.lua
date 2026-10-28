local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local surfel_gi = {}

event.AddListener("Render3DPassToggled", "surfel_gi", function(name, value)
	if name == "surfel_gi" and value then surfel_gi.ResetHistory() end
end)

surfel_gi.CASCADES = 4
surfel_gi.BASE_DIRECTIONS = 4
surfel_gi.CAPACITY_BITS = 16
surfel_gi.SLOTS_PER_ROW = 256
surfel_gi.PROBES = 8
surfel_gi.TOUCH_SAMPLES = 65536
surfel_gi.MAX_LEVEL = 15
surfel_gi.MIN_WEIGHT = "0.05"

function surfel_gi.GetCapacity(c)
	return 2 ^ (surfel_gi.CAPACITY_BITS - 2 * c)
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

surfel_gi.SLOT_COUNT = surfel_gi.GetOffset(surfel_gi.CASCADES)
surfel_gi.SLOT_ROWS = math.ceil(surfel_gi.SLOT_COUNT / surfel_gi.SLOTS_PER_ROW)
surfel_gi.ATLAS_WIDTH = surfel_gi.SLOTS_PER_ROW * surfel_gi.BASE_DIRECTIONS
surfel_gi.ATLAS_CASCADE_HEIGHT = surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW * surfel_gi.BASE_DIRECTIONS
pvars.StartGroup("Lighting", "Surfel GI", {store = false, prefix = "surfel_"})
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
	help = "how far the rays of cascade 0 reach, in its cells. the rays of each cascade start where the ones before ended and reach 4 times as far, the last cascade's reach to the end of the scene",
}
local hysteresis = pvars.Setup2{
	key = "surfel_hysteresis",
	default = 0.95,
	min = 0,
	max = 0.995,
	help = "how much of a surfel direction's history survives an update, a new surfel weighs its first updates 1/n",
}
local lifetime = pvars.Setup2{
	key = "surfel_lifetime",
	default = 240,
	integer = true,
	min = 8,
	help = "frames a surfel the screen no longer touches keeps being traced, after that its slot can be taken by a new one",
}
local update_interval_max = pvars.Setup2{
	key = "surfel_update_interval_max",
	default = 4,
	integer = true,
	min = 1,
	max = 16,
	help = "cascade n traces every 2^n frames, at most this many",
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
	default = "0.25mp",
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
	help = "show the cascade 0 surfels a pixel reads (a colour per surfel, dimmed where coverage is partial), how much of the pixel's lookup found surfels, or their sky visibility",
}
local debug_gi = pvars.Setup2{
	key = "surfel_debug_gi",
	default = false,
	help = "show only the gi irradiance",
}
pvars.EndGroup()

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
	local state = {frame = -1, reset = false}

	function surfel_gi.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		state.reset = surfel_gi.reset_requested == true
		surfel_gi.reset_requested = false
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
			byte_size = surfel_gi.SLOT_COUNT * 16,
			buffer_usage = {"storage_buffer"},
			memory_property = {"device_local"},
			label = "surfel_table",
		},
		key = texture("keys", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r32g32b32a32_sfloat"),
		surfel = texture("positions", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r32g32b32a32_sfloat"),
		state = texture("state", surfel_gi.SLOTS_PER_ROW, surfel_gi.SLOT_ROWS, "r16g16b16a16_sfloat"),
		atlas = texture(
			"radiance",
			surfel_gi.ATLAS_WIDTH,
			surfel_gi.ATLAS_CASCADE_HEIGHT * surfel_gi.CASCADES,
			"r16g16b16a16_sfloat"
		),
		irradiance = texture(
			"irradiance",
			surfel_gi.SLOTS_PER_ROW * 4,
			surfel_gi.GetCapacity(0) / surfel_gi.SLOTS_PER_ROW,
			"r16g16b16a16_sfloat"
		),
	}
	owner.owned_textures = {
		resources.table,
		resources.key,
		resources.surfel,
		resources.state,
		resources.atlas,
		resources.irradiance,
	}
	owner.surfel_resources = resources
	surfel_gi.GetFrameState().reset = true
	return resources
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
		{"surfel_hysteresis", "float"},
		{"surfel_interval", "float"},
		{"surfel_max_ray_distance", "float"},
		{"surfel_cell_size", "float"},
		{"surfel_lod_distance", "float"},
		{"surfel_max_distance", "float"},
		{"surfel_state_tex", "int"},
		{"surfel_atlas_tex", "int"},
		{"surfel_bent_normal_tex", "int"},
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
	block.surfel_hysteresis = hysteresis:Get()
	block.surfel_interval = interval:Get()
	block.surfel_max_ray_distance = max_ray_distance:Get()
	block.surfel_cell_size = cell_size:Get()
	block.surfel_lod_distance = lod_distance:Get()
	block.surfel_max_distance = max_distance:Get()
	block.surfel_state_tex = -1
	block.surfel_atlas_tex = -1
	block.surfel_bent_normal_tex = -1
	return block
end

function surfel_gi.GetDefinesGLSL()
	return glsl_common.GetHashGLSL() .. glsl_common.GetOctahedralGLSL() .. string.format(
			[[
		#define SURFEL_CASCADES %d
		#define SURFEL_BASE_DIRECTIONS %d
		#define SURFEL_CAPACITY_BITS %d
		#define SURFEL_SLOTS_PER_ROW %d
		#define SURFEL_PROBES %d
		#define SURFEL_MAX_LEVEL %d
		#define SURFEL_ATLAS_CASCADE_HEIGHT %d
		#define SURFEL_TOP_LEVEL (SURFEL_MAX_LEVEL - SURFEL_CASCADES)
		#ifndef saturate
		#define saturate(x) clamp(x, 0.0, 1.0)
		#endif

		int surfel_capacity(int c) {
			return 1 << (SURFEL_CAPACITY_BITS - 2 * c);
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
			int per_row = SURFEL_SLOTS_PER_ROW >> c;
			return ivec2((local_slot %% per_row) * side, (local_slot / per_row) * side + c * SURFEL_ATLAS_CASCADE_HEIGHT) + dir;
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

		vec3 surfel_bucket_weights(vec3 N) {
			return max(abs(N) - 0.4, vec3(0.0));
		}

		int surfel_bucket(int axis, float n) {
			return axis * 2 + (n < 0.0 ? 1 : 0);
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
			surfel_gi.CAPACITY_BITS,
			surfel_gi.SLOTS_PER_ROW,
			surfel_gi.PROBES,
			surfel_gi.MAX_LEVEL,
			surfel_gi.ATLAS_CASCADE_HEIGHT
		)
end

function surfel_gi.GetLookupGLSL()
	return surfel_gi.GetDefinesGLSL() .. [[

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

		vec3 surfel_evaluate(int g, vec3 L, vec4 a) {
			vec3 bx = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 1), 0).rgb;
			vec3 by = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 2), 0).rgb;
			vec3 bz = texelFetch(TEXTURE(ddgi_data.surfel_irradiance_tex), surfel_irradiance_texel(g, 3), 0).rgb;
			return max(a.rgb + bx * L.x + by * L.y + bz * L.z, vec3(0.0));
		}

		vec4 surfel_sample_level(vec3 P, vec3 N, vec3 L, vec3 L2, int level, bool surface, out float weight, out vec3 second) {
			float size = surfel_cell_size(level);
			vec3 grid = P / size - 0.5;
			ivec3 base = ivec3(floor(grid));
			vec3 f = grid - vec3(base);
			vec3 buckets = surfel_bucket_weights(N);
			vec4 sum = vec4(0.0);
			vec3 sum2 = vec3(0.0);
			float found = 0.0;
			float possible = 0.0;

			for (int axis = 0; axis < 3; axis++) {
				if (buckets[axis] <= 0.0) continue;

				int packed = surfel_pack(level, surfel_bucket(axis, N[axis]));

				for (int i = 0; i < 8; i++) {
					ivec3 o = ivec3(i & 1, (i >> 1) & 1, i >> 2);
					vec3 k = mix(1.0 - f, f, vec3(o));
					float w = k.x * k.y * k.z * buckets[axis];
					possible += w;

					if (w <= 0.0) continue;

					int g = surfel_find(base + o, packed, 0);

					if (g < 0) continue;

					if (surface) {
						vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(g), 0);
						vec3 surfel_N = surfel_unpack_normal(surfel.w);
						w *= saturate(1.5 - abs(dot(P - surfel.xyz, surfel_N)) / size) * smoothstep(0.0, 0.5, dot(surfel_N, N));

						if (w <= 0.0) continue;
					}

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
			float blend = level < SURFEL_TOP_LEVEL ? smoothstep(0.75, 1.0, lod - float(level)) : 0.0;
			vec3 second_rgb;
			vec4 result = surfel_sample_level(P, N, L, L2, level, surface, weight, second_rgb);

			if (level < SURFEL_TOP_LEVEL && (blend > 0.0 || weight <= 0.0)) {
				float coarse_weight;
				vec3 coarse_second;
				vec4 coarse = surfel_sample_level(P, N, L, L2, level + 1, surface, coarse_weight, coarse_second);

				if (coarse_weight > 0.0) {
					float t = weight > 0.0 ? blend : 1.0;
					result = mix(result, coarse, t);
					second_rgb = mix(second_rgb, coarse_second, t);
					weight = mix(weight, coarse_weight, t);
				}
			}

			#ifndef SURFEL_UNSCALED
			result.rgb *= ddgi_data.surfel_params.z;
			second_rgb *= ddgi_data.surfel_params.z;
			#endif
			second = vec4(second_rgb, result.a);
			return result;
		}

		vec4 surfel_sample_medium(vec3 P, vec3 D, out float weight) {
			float front_weight;
			float back_weight;
			vec4 unused;
			vec4 front = surfel_sample_irradiance_pair(P, D, D, D, false, 2, front_weight, unused);
			vec4 back = surfel_sample_irradiance_pair(P, -D, -D, -D, false, 2, back_weight, unused);
			weight = 0.5 * (front_weight + back_weight);

			if (front_weight <= 0.0) front = back;

			if (back_weight <= 0.0) back = front;

			return 0.5 * (front + back);
		}
	]]
end

return surfel_gi
