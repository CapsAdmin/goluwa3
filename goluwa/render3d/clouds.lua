local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local clouds = library()
clouds.MAX_LAYERS = 4
clouds.RADIANCE_SCALE = atmosphere.CLOUD_RADIANCE_SCALE
clouds.SHADOW_SIZE = 512
clouds.SHADOW_EXTENT = 32000
clouds.SKY_WIDTH = 512
clouds.SKY_HEIGHT = 256
clouds.BASE_NOISE_SIZE = 128
clouds.DETAIL_NOISE_SIZE = 32
clouds.WEATHER_SIZE = 512
clouds.SKY_REFRESH_INTERVAL = 2
clouds.SKY_CHANGE_INTERVAL = 0.5
clouds.enabled = true
clouds.layers = {}
clouds.cover = 0
clouds.sky_version = 0
clouds.layers_changed = false
clouds.light_direction = Vec3(0, 1, 0)
clouds.light_illuminance = Vec3(0, 0, 0)
clouds.shadow_direction = Vec3(0, 1, 0)
clouds.textures = clouds.textures or {}
clouds.LAYER_DEFAULTS = {
	name = false,
	bottom = 1500,
	thickness = 1500,
	coverage = 0.4,
	density = 0.06,
	type = 1,
	erosion = 0.4,
	anvil = 0,
	flat = false,
	weather_scale = 40000,
	shape_scale = 5000,
	detail_scale = 300,
	variation = 0.5,
	base_variation = 0,
	swirl = 0,
	wind_scale = 2.5,
	evolution = 0.6,
}

local function create_layer(params)
	local layer = table.copy(clouds.LAYER_DEFAULTS)

	for k, v in pairs(params) do
		if clouds.LAYER_DEFAULTS[k] == nil then
			error("unknown cloud layer field " .. tostring(k), 3)
		end

		layer[k] = v
	end

	layer.weather_offset = Vec2(0, 0)
	layer.shape_offset = Vec3(0, 0, 0)
	layer.detail_offset = Vec3(0, 0, 0)
	return layer
end

local function sort_layers(a, b)
	return a.bottom < b.bottom
end

function clouds.SetLayers(list)
	if #list > clouds.MAX_LAYERS then
		error("at most " .. clouds.MAX_LAYERS .. " cloud layers", 2)
	end

	local previous = {}

	for _, layer in ipairs(clouds.layers) do
		if layer.name then previous[layer.name] = layer end
	end

	local layers = {}

	for i, params in ipairs(list) do
		local layer = create_layer(params)
		local old = layer.name and previous[layer.name]

		if old then
			layer.weather_offset = old.weather_offset
			layer.shape_offset = old.shape_offset
			layer.detail_offset = old.detail_offset
			previous[layer.name] = nil
		else
			layer.weather_offset = Vec2(i * 7919, i * 3571)
			layer.shape_offset = Vec3(i * 4271, i * 1523, i * 2963)
			layer.detail_offset = Vec3(i * 613, i * 331, i * 877)
		end

		layers[i] = layer
	end

	table.sort(layers, sort_layers)
	clouds.layers = layers
	clouds.cover = clouds.EstimateCover()
	clouds.layers_changed = true
end

function clouds.GetLayers()
	return clouds.layers
end

function clouds.GetCover()
	return clouds.cover
end

local MEAN_SHAPE_DENSITY = 0.35

local function get_optical_depth(layer)
	if layer.flat then return layer.density end

	return layer.density * layer.thickness * MEAN_SHAPE_DENSITY
end

function clouds.EstimateCover()
	local clear = 1

	for _, layer in ipairs(clouds.layers) do
		clear = clear * (1 - layer.coverage * (1 - math.exp(-get_optical_depth(layer))))
	end

	return 1 - clear
end

function clouds.GetMeanTransmittance(dir)
	local mu = math.max(dir.y, 0.05)
	local t = 1

	for _, layer in ipairs(clouds.layers) do
		t = t * (1 - layer.coverage * (1 - math.exp(-get_optical_depth(layer) / mu)))
	end

	return t
end

function clouds.GetMaxTransmittance(dir)
	local mu = math.max(dir.y, 0.05)
	local t = 1

	for _, layer in ipairs(clouds.layers) do
		if layer.coverage >= 1 then
			t = t * math.exp(-get_optical_depth(layer) / mu)
		end
	end

	return t
end

function clouds.GetSunDiffusion()
	local clear = 1

	for _, layer in ipairs(clouds.layers) do
		local od = get_optical_depth(layer)

		if od < 4 then
			clear = clear * (1 - layer.coverage * (1 - math.exp(-od * 2)))
		end
	end

	return 1 - clear
end

function clouds.SetEnabled(enabled)
	clouds.enabled = enabled
	clouds.sky_version = clouds.sky_version + 1
end

function clouds.IsEnabled()
	return clouds.enabled
end

function clouds.IsActive()
	return clouds.enabled and atmosphere.IsEnabled() and #clouds.layers > 0
end

function clouds.SetLight(direction, illuminance)
	clouds.light_direction = direction
	clouds.light_illuminance = illuminance
end

function clouds.SetShadowDirection(direction)
	clouds.shadow_direction = direction
end

function clouds.GetSkyVersion()
	return clouds.sky_version
end

do
	local sky_time = 0
	local time = 0

	local function wrap(v, size)
		return v - math.floor(v / size) * size
	end

	function clouds.Update(dt)
		time = time + dt
		clouds.time = time
		local wind = atmosphere.GetWind()
		local moving = false
		sky_time = sky_time + dt

		for _, layer in ipairs(clouds.layers) do
			local vx = -wind.x * layer.wind_scale * dt
			local vz = -wind.z * layer.wind_scale * dt
			local rise = -layer.evolution * dt
			layer.weather_offset.x = wrap(layer.weather_offset.x + vx, layer.weather_scale)
			layer.weather_offset.y = wrap(layer.weather_offset.y + vz, layer.weather_scale)
			layer.shape_offset.x = wrap(layer.shape_offset.x + vx * 0.9, layer.shape_scale)
			layer.shape_offset.y = wrap(layer.shape_offset.y + rise, layer.shape_scale)
			layer.shape_offset.z = wrap(layer.shape_offset.z + vz * 0.9, layer.shape_scale)
			layer.detail_offset.x = wrap(layer.detail_offset.x + vx, layer.detail_scale)
			layer.detail_offset.y = wrap(layer.detail_offset.y + rise * 3, layer.detail_scale)
			layer.detail_offset.z = wrap(layer.detail_offset.z + vz, layer.detail_scale)
			moving = moving or vx ~= 0 or vz ~= 0 or rise ~= 0
		end

		if
			clouds.layers_changed and
			sky_time > clouds.SKY_CHANGE_INTERVAL or
			moving and
			sky_time > clouds.SKY_REFRESH_INTERVAL
		then
			sky_time = 0
			clouds.layers_changed = false
			clouds.sky_version = clouds.sky_version + 1
		end

		atmosphere.SetCloudSky(clouds.GetSkyTexture(), clouds.GetMeanTransmittance(clouds.shadow_direction))
	end
end

local function create_volume(size, name)
	local tex = Texture.New{
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		mip_map_levels = math.floor(math.log(size, 2)) + 1,
		image = {
			image_type = "3d",
			depth = size,
			usage = {"storage", "sampled", "transfer_src", "transfer_dst"},
		},
		view = {view_type = "3d"},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			mipmap_mode = "linear",
			wrap_s = "repeat",
			wrap_t = "repeat",
			wrap_r = "repeat",
		},
	}
	tex:SetDebugName("clouds " .. name)
	local image = tex:GetImage()
	local level0 = image:CreateView{
		view_type = "3d",
		format = tex.format,
		base_mip_level = 0,
		level_count = 1,
	}
	local storage = {
		GetImage = function()
			return image
		end,
		GetView = function()
			return level0
		end,
	}
	return tex, render.CreateSampler(tex:GetSamplerConfig()), storage
end

local function create_target(width, height, format, name, wrap_s, wrap_t)
	local tex = Texture.New{
		width = width,
		height = height,
		format = format,
		image = {usage = {"storage", "sampled"}},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = wrap_s or "clamp_to_edge",
			wrap_t = wrap_t or "clamp_to_edge",
		},
	}
	tex:SetDebugName("clouds " .. name)
	return tex
end

function clouds.EnsureResources()
	local t = clouds.textures

	if t.base_noise then return t end

	t.base_noise, t.base_noise_sampler, t.base_noise_storage = create_volume(clouds.BASE_NOISE_SIZE, "base noise")
	t.detail_noise, t.detail_noise_sampler, t.detail_noise_storage = create_volume(clouds.DETAIL_NOISE_SIZE, "detail noise")
	t.weather = create_target(
		clouds.WEATHER_SIZE,
		clouds.WEATHER_SIZE,
		"r8g8b8a8_unorm",
		"weather",
		"repeat",
		"repeat"
	)
	t.shadow = create_target(clouds.SHADOW_SIZE, clouds.SHADOW_SIZE, "r16g16b16a16_sfloat", "shadow")
	t.sky = create_target(
		clouds.SKY_WIDTH,
		clouds.SKY_HEIGHT,
		"r16g16b16a16_sfloat",
		"sky",
		"repeat",
		"clamp_to_edge"
	)
	t.noise_ready = false
	t.noise_mipped = false
	t.shadow_ready = false
	t.sky_ready = false
	return t
end

function clouds.GenerateNoiseMips(cmd)
	local t = clouds.textures

	if not t.noise_ready or t.noise_mipped then return end

	t.base_noise:GenerateMipmaps(
		"shader_read_only_optimal",
		{cmd = cmd, src_stage = "compute", dst_stage = "compute"}
	)
	t.detail_noise:GenerateMipmaps(
		"shader_read_only_optimal",
		{cmd = cmd, src_stage = "compute", dst_stage = "compute"}
	)
	t.noise_mipped = true
end

function clouds.EnsureViewResources(size)
	local t = clouds.textures
	local width = math.ceil(size.x / 2)
	local height = math.ceil(size.y / 2)

	if t.view_width == width and t.view_height == height then return t end

	for _, key in ipairs{"trace", "trace_depth", "view1", "view2", "view_depth1", "view_depth2"} do
		if t[key] then t[key]:Remove() end
	end

	local trace_width = math.ceil(width / 2)
	local trace_height = math.ceil(height / 2)
	t.trace = create_target(trace_width, trace_height, "r16g16b16a16_sfloat", "trace")
	t.trace_depth = create_target(trace_width, trace_height, "r32_sfloat", "trace depth")

	for i = 1, 2 do
		t["view" .. i] = create_target(width, height, "r16g16b16a16_sfloat", "view " .. i)
		t["view_depth" .. i] = create_target(width, height, "r32_sfloat", "view depth " .. i)
	end

	t.view_width = width
	t.view_height = height
	t.trace_width = trace_width
	t.trace_height = trace_height
	t.view_current = 1
	t.view_valid = false
	return t
end

function clouds.GetViewTextures()
	local t = clouds.textures

	if not t.view_valid or not clouds.IsActive() then return nil end

	return t["view" .. t.view_current], t["view_depth" .. t.view_current]
end

function clouds.GetShadowTexture()
	local t = clouds.textures

	if not t.shadow_ready or not clouds.IsActive() then return nil end

	return t.shadow
end

function clouds.GetSkyTexture()
	local t = clouds.textures

	if not t.sky_ready or not clouds.IsActive() then return nil end

	return t.sky
end

do
	local shadow_frame = {
		right = Vec3(1, 0, 0),
		up = Vec3(0, 0, 1),
		dir = Vec3(0, 1, 0),
		center = Vec3(0, 0, 0),
		distance = 0,
	}

	function clouds.UpdateShadowFrame(camera_position)
		local dir = clouds.shadow_direction:GetNormalized()
		local ref = math.abs(dir.y) < 0.99 and Vec3(0, 1, 0) or Vec3(1, 0, 0)
		local right = dir:GetCross(ref):GetNormalized()
		local up = right:GetCross(dir):GetNormalized()
		local texel = clouds.SHADOW_EXTENT / clouds.SHADOW_SIZE
		local x = math.floor(camera_position:GetDot(right) / texel + 0.5) * texel
		local y = math.floor(camera_position:GetDot(up) / texel + 0.5) * texel
		local z = camera_position:GetDot(dir)
		local top = 0

		for _, layer in ipairs(clouds.layers) do
			top = math.max(top, layer.bottom + layer.thickness + layer.base_variation)
		end

		shadow_frame.right = right
		shadow_frame.up = up
		shadow_frame.dir = dir
		shadow_frame.center = right * x + up * y + dir * z
		shadow_frame.distance = (top + 500 - math.min(camera_position.y, 0)) / math.max(dir.y, 0.03)
		return shadow_frame
	end

	function clouds.GetShadowFrame()
		return shadow_frame
	end
end

function clouds.GetShadowBlockLayout()
	return {
		{"cloud_shadow_axes", "vec4", 3},
		{"cloud_shadow_tex", "int"},
		{"cloud_shadow_fallback", "float"},
	}
end

function clouds.WriteShadowBlock(self, block)
	local tex = clouds.GetShadowTexture()

	if not tex then
		block.cloud_shadow_tex = -1
		block.cloud_shadow_fallback = 1
		return
	end

	local frame = clouds.GetShadowFrame()
	local scale = 1 / clouds.SHADOW_EXTENT
	local right = frame.right * scale
	local up = frame.up * scale
	local axes = block.cloud_shadow_axes
	axes[0][0] = right.x
	axes[0][1] = right.y
	axes[0][2] = right.z
	axes[0][3] = 0.5 - frame.center:GetDot(right)
	axes[1][0] = up.x
	axes[1][1] = up.y
	axes[1][2] = up.z
	axes[1][3] = 0.5 - frame.center:GetDot(up)
	axes[2][0] = -frame.dir.x * 0.001
	axes[2][1] = -frame.dir.y * 0.001
	axes[2][2] = -frame.dir.z * 0.001
	axes[2][3] = (frame.distance + frame.center:GetDot(frame.dir)) * 0.001
	block.cloud_shadow_tex = self:GetTextureIndex(tex)
	block.cloud_shadow_fallback = clouds.GetMeanTransmittance(frame.dir)
end

function clouds.GetShadowGLSL(prefix)
	return [[
		#ifndef CLOUD_SHADOW_GLSL
		#define CLOUD_SHADOW_GLSL
		// a beer shadow map: the depth where the clouds start, their mean extinction and their optical
		// depth all the way through
		float get_cloud_shadow(vec3 world_pos) {
			if (]] .. prefix .. [[.cloud_shadow_tex < 0) return ]] .. prefix .. [[.cloud_shadow_fallback;

			vec3 s = vec3(
				dot(]] .. prefix .. [[.cloud_shadow_axes[0].xyz, world_pos) + ]] .. prefix .. [[.cloud_shadow_axes[0].w,
				dot(]] .. prefix .. [[.cloud_shadow_axes[1].xyz, world_pos) + ]] .. prefix .. [[.cloud_shadow_axes[1].w,
				dot(]] .. prefix .. [[.cloud_shadow_axes[2].xyz, world_pos) + ]] .. prefix .. [[.cloud_shadow_axes[2].w
			);
			vec2 edge = abs(s.xy - 0.5) * 2.0;
			float outside = smoothstep(0.85, 1.0, max(edge.x, edge.y));
			vec4 bsm = textureLod(TEXTURE(]] .. prefix .. [[.cloud_shadow_tex), s.xy, 0.0);
			float od = min(max(s.z - bsm.x, 0.0) * 1000.0 * bsm.y, bsm.z);
			return mix(exp(-od), ]] .. prefix .. [[.cloud_shadow_fallback, outside);
		}
		#endif
	]]
end

function clouds.GetBlockLayout()
	return {
		{"cloud_layer_count", "int"},
		{"cloud_weather_tex", "int"},
		{"cloud_frame", "int"},
		{"cloud_mean_transmittance", "float"},
		{"cloud_layer_shape", "vec4", clouds.MAX_LAYERS},
		{"cloud_layer_style", "vec4", clouds.MAX_LAYERS},
		{"cloud_layer_scale", "vec4", clouds.MAX_LAYERS},
		{"cloud_layer_offset", "vec4", clouds.MAX_LAYERS},
		{"cloud_layer_offset2", "vec4", clouds.MAX_LAYERS},
		{"cloud_layer_vary", "vec4", clouds.MAX_LAYERS},
		{"cloud_light_direction", "vec4"},
		{"cloud_light_illuminance", "vec4"},
	}
end

function clouds.WriteBlock(self, block)
	local layers = clouds.layers
	block.cloud_layer_count = #layers
	block.cloud_weather_tex = self:GetTextureIndex(clouds.EnsureResources().weather)
	block.cloud_frame = clouds.frame or 0
	block.cloud_mean_transmittance = clouds.GetMeanTransmittance(clouds.light_direction)

	for i, layer in ipairs(layers) do
		local k = i - 1
		local shape = block.cloud_layer_shape[k]
		shape[0] = layer.bottom
		shape[1] = layer.thickness
		shape[2] = layer.coverage
		shape[3] = layer.density
		local style = block.cloud_layer_style[k]
		style[0] = layer.type
		style[1] = layer.erosion
		style[2] = layer.anvil
		style[3] = layer.flat and 1 or 0
		local scale = block.cloud_layer_scale[k]
		scale[0] = layer.weather_scale
		scale[1] = layer.shape_scale
		scale[2] = layer.detail_scale
		scale[3] = layer.variation
		local offset = block.cloud_layer_offset[k]
		offset[0] = layer.weather_offset.x
		offset[1] = layer.weather_offset.y
		offset[2] = layer.shape_offset.x
		offset[3] = layer.shape_offset.z
		local offset2 = block.cloud_layer_offset2[k]
		offset2[0] = layer.shape_offset.y
		offset2[1] = layer.detail_offset.x
		offset2[2] = layer.detail_offset.y
		offset2[3] = layer.detail_offset.z
		local vary = block.cloud_layer_vary[k]
		vary[0] = layer.swirl
		vary[1] = layer.flat and 0 or layer.base_variation
	end

	local dir = clouds.light_direction
	block.cloud_light_direction[0] = dir.x
	block.cloud_light_direction[1] = dir.y
	block.cloud_light_direction[2] = dir.z
	block.cloud_light_direction[3] = 0
	local illuminance = clouds.light_illuminance
	block.cloud_light_illuminance[0] = illuminance.x
	block.cloud_light_illuminance[1] = illuminance.y
	block.cloud_light_illuminance[2] = illuminance.z
	block.cloud_light_illuminance[3] = 0
end

clouds.NOISE_GLSL = [[
	uvec3 cloud_pcg3d(uvec3 v) {
		v = v * 1664525u + 1013904223u;
		v.x += v.y * v.z;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		v ^= v >> 16u;
		v.x += v.y * v.z;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		return v;
	}

	// a random point in the cell, the cells wrap every period. c is never below -1
	vec3 cloud_random3(ivec3 c, ivec3 period, uint seed) {
		uvec3 w = uvec3((c + period * 64) % period);
		return vec3(cloud_pcg3d(w + uvec3(seed, seed * 7u, seed * 13u)) & 0xffffu) / 65535.0;
	}

	float cloud_gradient(ivec3 c, vec3 f, ivec3 o, ivec3 period, uint seed) {
		return dot(cloud_random3(c + o, period, seed) * 2.0 - 1.0, f - vec3(o));
	}

	// gradient noise, about -1 to 1
	float cloud_perlin(vec3 p, ivec3 period, uint seed) {
		ivec3 c = ivec3(floor(p));
		vec3 f = p - vec3(c);
		vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
		return mix(
			mix(
				mix(cloud_gradient(c, f, ivec3(0, 0, 0), period, seed), cloud_gradient(c, f, ivec3(1, 0, 0), period, seed), u.x),
				mix(cloud_gradient(c, f, ivec3(0, 1, 0), period, seed), cloud_gradient(c, f, ivec3(1, 1, 0), period, seed), u.x),
				u.y
			),
			mix(
				mix(cloud_gradient(c, f, ivec3(0, 0, 1), period, seed), cloud_gradient(c, f, ivec3(1, 0, 1), period, seed), u.x),
				mix(cloud_gradient(c, f, ivec3(0, 1, 1), period, seed), cloud_gradient(c, f, ivec3(1, 1, 1), period, seed), u.x),
				u.y
			),
			u.z
		);
	}

	// 1 at a cell's point, falling to 0 a cell away: round puffs
	float cloud_worley(vec3 p, ivec3 period, uint seed) {
		ivec3 c = ivec3(floor(p));
		vec3 f = p - vec3(c);
		float d = 1e9;

		for (int z = -1; z <= 1; z++) {
			for (int y = -1; y <= 1; y++) {
				for (int x = -1; x <= 1; x++) {
					ivec3 o = ivec3(x, y, z);
					vec3 r = vec3(o) + cloud_random3(c + o, period, seed) - f;
					d = min(d, dot(r, r));
				}
			}
		}

		return 1.0 - clamp(sqrt(d), 0.0, 1.0);
	}

	// p in tiles, freq cells per tile
	float cloud_perlin_fbm(vec3 p, ivec3 freq, int octaves, uint seed) {
		float sum = 0.0;
		float amplitude = 1.0;
		float total = 0.0;

		for (int i = 0; i < octaves; i++) {
			sum += cloud_perlin(p * vec3(freq), freq, seed + uint(i)) * amplitude;
			total += amplitude;
			amplitude *= 0.5;
			freq *= 2;
		}

		return sum / total;
	}

	float cloud_worley_fbm(vec3 p, ivec3 freq, uint seed) {
		return cloud_worley(p * vec3(freq), freq, seed) * 0.625 +
			cloud_worley(p * vec3(freq * 2), freq * 2, seed + 1u) * 0.25 +
			cloud_worley(p * vec3(freq * 4), freq * 4, seed + 2u) * 0.125;
	}

	float cloud_remap(float v, float l0, float h0, float l1, float h1) {
		return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
	}

	float cloud_saturate(float x) {
		return clamp(x, 0.0, 1.0);
	}
]]

function clouds.GetGLSL(block)
	return [[
		#define CLOUD_BLOCK ]] .. block .. [[

		const float CLOUD_PLANET_RADIUS = 6371000.0;
		const float CLOUD_EYE_HEIGHT = ]] .. string.format("%.4f", 1.75) .. [[;
		const int CLOUD_MAX_LAYERS = ]] .. clouds.MAX_LAYERS .. [[;
		const int CLOUD_MAX_SEGMENTS = ]] .. (
			clouds.MAX_LAYERS * 2
		) .. [[;
		// a march through empty space takes steps this many fine steps long, and falls back to them
		// after this many fine steps in the clear
		const float CLOUD_COARSE_STEPS = 4.0;
		const int CLOUD_EMPTY_STEPS = 6;
		// past this transmittance a march stops lighting its samples, what is further in adds no
		// light that shows
		const float CLOUD_LIT_TRANSMITTANCE = 0.003;
		// the sun's disc is ~1e5 times brighter than the sky and would show through much denser cloud,
		// but a real cloud that thick scatters so much light forward that the disc is lost in it (the
		// scattering approximation doesn't carry that light). what comes through fades out over the
		// tenfold above this and is gone below it, where the march stops. higher hides the sun behind
		// thinner cloud: 1e-3 is an optical depth of 6.9, 1e-4 9.2, 1e-5 11.5
		const float CLOUD_HIDDEN_TRANSMITTANCE = 1e-4;
		// the warp that breaks up the shape noise's tiling: its field repeats every 1 / (0.889 x
		// frequency) tiles, is read this coarse, and moves the lookup by up to half this many tiles
		const float CLOUD_WARP_FREQUENCY = 0.12;
		const float CLOUD_WARP_LOD = 1.0;
		const float CLOUD_WARP_AMOUNT = 1.6;
		// it starts this many tiles away from the camera and is in full this many tiles out
		const float CLOUD_WARP_NEAR = 2.0;
		const float CLOUD_WARP_FAR = 8.0;
		// how coarse the shape noise is read for how tall each heap grows
		const float CLOUD_TOP_CELL_LOD = 3.0;

		float cloud_saturate(float x) {
			return clamp(x, 0.0, 1.0);
		}

		float cloud_remap(float v, float l0, float h0, float l1, float h1) {
			return l1 + (v - l0) * (h1 - l1) / (h0 - l0);
		}

		// a ray against the planet's spheres, in meters without losing precision to the planet's
		// radius: h0 is the origin's altitude and b the ray's dot with the direction from the center
		struct cloud_ray_t {
			vec3 origin;
			vec3 dir;
			float h0;
			float b;
		};

		cloud_ray_t cloud_ray(vec3 origin, vec3 dir) {
			cloud_ray_t r;
			r.origin = origin;
			r.dir = dir;
			vec3 q = vec3(origin.x, origin.y + CLOUD_EYE_HEIGHT, origin.z);
			r.h0 = (dot(q, q) + 2.0 * CLOUD_PLANET_RADIUS * q.y) / (length(vec3(q.x, q.y + CLOUD_PLANET_RADIUS, q.z)) + CLOUD_PLANET_RADIUS);
			r.b = dot(q, dir) + CLOUD_PLANET_RADIUS * dir.y;
			return r;
		}

		float cloud_altitude(cloud_ray_t r, float t) {
			float k = t * (2.0 * r.b + t);
			float rh = CLOUD_PLANET_RADIUS + r.h0;
			return (r.h0 * (2.0 * CLOUD_PLANET_RADIUS + r.h0) + k) / (sqrt(max(rh * rh + k, 0.0)) + CLOUD_PLANET_RADIUS);
		}

		// where the ray is at altitude a, x > y when it never is
		vec2 cloud_sphere(cloud_ray_t r, float a) {
			float c = (r.h0 - a) * (2.0 * CLOUD_PLANET_RADIUS + r.h0 + a);
			float disc = r.b * r.b - c;

			if (disc < 0.0) return vec2(1e30, -1e30);

			float s = sqrt(disc);
			float q = r.b >= 0.0 ? -r.b - s : -r.b + s;

			if (abs(q) < 1e-6) return vec2(0.0);

			float t0 = q;
			float t1 = c / q;
			return vec2(min(t0, t1), max(t0, t1));
		}

		// the parts of [0, t_max] between altitudes a0 and a1, up to two
		int cloud_shell(cloud_ray_t r, float a0, float a1, float t_max, out vec4 seg) {
			seg = vec4(0.0);
			vec2 outer = cloud_sphere(r, a1);
			float s0 = max(outer.x, 0.0);
			float e0 = min(outer.y, t_max);

			if (e0 <= s0) return 0;

			vec2 inner = cloud_sphere(r, a0);

			if (inner.x > inner.y) {
				seg.xy = vec2(s0, e0);
				return 1;
			}

			int n = 0;
			vec2 a = vec2(s0, min(e0, inner.x));
			vec2 b = vec2(max(s0, inner.y), e0);

			if (a.y > a.x) {
				seg.xy = a;
				n = 1;
			}

			if (b.y > b.x) {
				if (n == 0) seg.xy = b; else seg.zw = b;
				n++;
			}

			return n;
		}

		vec3 cloud_up(vec3 p) {
			return normalize(vec3(p.x, p.y + CLOUD_EYE_HEIGHT + CLOUD_PLANET_RADIUS, p.z));
		}

		// the density profile by height within the layer, from flat stratus to domed cumulus
		float cloud_height_profile(float hf, float type) {
			float bottom = smoothstep(0.0, mix(0.08, 0.15, type), hf);
			float top = 1.0 - smoothstep(mix(0.7, 0.25, type), 1.0, hf);
			return bottom * top;
		}

		// the cloud's density at p (world meters, altitude alt), 0 to the layer's density. detail adds
		// the erosion by the detail noise
		// footprint is how many meters the sample stands for, the noise is read that coarse
		float cloud_density(int i, vec3 p, float alt, bool detail, float footprint) {
			vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
			vec4 vary = CLOUD_BLOCK.cloud_layer_vary[i];

			if (alt <= shape.x - vary.y || alt >= shape.x + shape.y + vary.y) return 0.0;

			vec4 style = CLOUD_BLOCK.cloud_layer_style[i];
			vec4 scale = CLOUD_BLOCK.cloud_layer_scale[i];
			vec4 offset = CLOUD_BLOCK.cloud_layer_offset[i];
			vec4 offset2 = CLOUD_BLOCK.cloud_layer_offset2[i];
			vec4 weather = textureLod(TEXTURE(CLOUD_BLOCK.cloud_weather_tex), (p.xz + offset.xy) / scale.x, 0.0);
			// the base rises and sinks from place to place, as the air is more or less humid
			float hf = (alt - shape.x - (weather.a * 2.0 - 1.0) * vary.y) / shape.y;

			if (hf <= 0.0 || hf >= 1.0) return 0.0;

			float coverage = cloud_saturate(shape.z + (weather.r - 0.5) * scale.w);
			// cumulonimbus spread out into an anvil near the top
			coverage = mix(coverage, cloud_saturate(coverage * 1.4 + 0.25), style.z * smoothstep(0.65, 0.9, hf));

			if (coverage <= 0.0) return 0.0;

			vec3 uvw = (vec3(p.x + offset.z, alt + offset2.x, p.z + offset.w)) / scale.y;
			float lod = log2(max(footprint * ]] .. clouds.BASE_NOISE_SIZE .. [[.0 / scale.y, 1.0));
			// the noise tiles, and toward the horizon the copies along a direction of its lattice would
			// line up into streaks. a smooth field read from a copy turned and scaled by irrational
			// amounts pushes the lookup around, differently for every copy. it would shear the clouds
			// overhead, where only a few copies are in view, so it comes in with distance, unless the
			// layer asks for swirls
			float warp = max(smoothstep(CLOUD_WARP_NEAR, CLOUD_WARP_FAR, distance(p.xz, CLOUD_BLOCK.camera_position.xz) / scale.y), vary.x);

			if (warp > 0.0) {
				vec3 turned = vec3(uvw.x * 0.6663 - uvw.z * 0.5891, uvw.y * 0.8889 + 0.37, uvw.x * 0.5891 + uvw.z * 0.6663 + 0.53) * CLOUD_WARP_FREQUENCY;
				uvw.xz += (textureLod(cloud_base_noise, turned, max(lod + log2(0.889 * CLOUD_WARP_FREQUENCY), CLOUD_WARP_LOD)).rg - 0.5) * (CLOUD_WARP_AMOUNT * warp);
			}

			// heaps grow to different heights: a region's weather sets how tall they get, and the
			// coarsest cells of the shape noise, about a cloud across, make neighbours differ.
			// stratus doesn't vary
			float heaps = style.x * (1.0 - style.z);
			float top = 1.0;

			if (heaps > 0.0) {
				float cell = cloud_saturate((textureLod(cloud_base_noise, vec3(uvw.x, offset2.x / scale.y, uvw.z), max(lod, CLOUD_TOP_CELL_LOD)).g - 0.3) / 0.4);
				top = mix(1.0, mix(0.3, 1.0, mix(weather.g, cell, 0.6)), heaps);
			}

			float h = hf / top;

			if (h >= 1.0) return 0.0;

			float profile = cloud_height_profile(h, style.x);
			profile = max(profile, style.z * smoothstep(0.6, 0.8, hf) * (1.0 - smoothstep(0.92, 1.0, hf)));
			vec4 n = textureLod(cloud_base_noise, uvw, lod);

			// the perlin-worley shape, dented by the finer worley octaves
			float fbm = dot(n.gba, vec3(0.625, 0.25, 0.125));
			float base = cloud_saturate(cloud_remap(n.r, (1.0 - fbm) * 0.3, 1.0, 0.0, 1.0));
			// thin at the edge and denser toward the core, so the detail erodes a soft rim instead of
			// carving a hard outline
			float d = pow(cloud_saturate(cloud_remap(base * profile, 1.0 - coverage, 1.0, 0.0, 1.0)), 0.7);
			// heaps are thin and ragged at the base, and denser up where they billow
			d *= mix(1.0, mix(0.6, 1.0, smoothstep(0.0, 0.5, hf)), style.x);
			// a full cover has no gaps
			d = mix(d, profile * (0.55 + 0.45 * base), smoothstep(0.9, 1.0, coverage));

			if (d <= 0.0) return 0.0;

			if (detail) {
				vec3 duvw = (vec3(p.x, alt, p.z) + offset2.yzw) / scale.z;
				float detail_lod = log2(max(footprint * ]] .. clouds.DETAIL_NOISE_SIZE .. [[.0 / scale.z, 1.0));
				vec3 dn = textureLod(cloud_detail_noise, duvw, detail_lod).rgb;
				float dfbm = dot(dn, vec3(0.625, 0.25, 0.125));
				// wispy at the base, billowing above
				float erode = mix(dfbm, 1.0 - dfbm, cloud_saturate(hf * 5.0));
				// once the detail is much finer than the sample it only greys the edges out. it eats the
				// thin rim and leaves the core
				d = cloud_saturate(cloud_remap(d, erode * style.y * (1.0 - smoothstep(2.0, 4.0, detail_lod)), 1.0, 0.0, 1.0));
			}

			return d * shape.w;
		}

		// a flat layer's optical depth straight through it at p
		float cloud_flat_optical_depth(int i, vec3 p) {
			vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
			vec4 scale = CLOUD_BLOCK.cloud_layer_scale[i];
			vec4 offset = CLOUD_BLOCK.cloud_layer_offset[i];
			vec4 offset2 = CLOUD_BLOCK.cloud_layer_offset2[i];
			vec4 weather = textureLod(TEXTURE(CLOUD_BLOCK.cloud_weather_tex), (p.xz + offset.xy) / scale.x, 0.0);
			float coverage = cloud_saturate(shape.z + (weather.r - 0.5) * scale.w);
			// the streaks, broken up by the base noise's fine octaves
			float streaks = cloud_saturate((weather.b - 0.1) / 0.6);
			vec3 n = textureLod(cloud_base_noise, vec3((p.xz + offset.zw) / scale.y, offset2.x / scale.y).xzy, 1.0).gba;
			float field = streaks * mix(0.55, 1.0, dot(n, vec3(0.5, 0.3, 0.2)));
			field = cloud_saturate(cloud_remap(field, 1.0 - coverage, 1.0, 0.0, 1.0));
			field = mix(field, 0.6 + 0.4 * field, smoothstep(0.9, 1.0, coverage));
			return field * shape.w;
		}

		float cloud_hg(float mu, float g) {
			float gg = g * g;
			return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
		}

		// water droplets: a strong forward peak and a little back scattering
		float cloud_phase(float mu, float scale) {
			return mix(cloud_hg(mu, -0.25 * scale), cloud_hg(mu, 0.8 * scale), 0.75);
		}

		// sunlight after the optical depth od toward it, scattered toward the viewer, summed over
		// scattering orders that each see less of the extinction and a softer phase (Wrenninge 2013)
		float cloud_scattering(float od, float mu) {
			float sum = 0.0;
			float a = 1.0;
			float b = 1.0;
			float c = 1.0;

			for (int o = 0; o < 5; o++) {
				sum += b * cloud_phase(mu, c) * exp(-od * a);
				a *= 0.45;
				b *= 0.65;
				c *= 0.5;
			}

			return sum;
		}

		// the optical depth of layer i toward the light from p, marched in growing steps
		float cloud_light_optical_depth(int i, vec3 p, float alt, vec3 L, float L_up, int steps) {
			vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
			float step_size = shape.y * 0.025;
			float t = 0.0;
			float od = 0.0;

			for (int k = 0; k < steps; k++) {
				float ds = step_size * (k < 2 ? 1.0 : pow(1.7, float(k - 1)));
				float s = t + ds * 0.5;
				float a = alt + L_up * s;

				if (a > shape.x + shape.y + CLOUD_BLOCK.cloud_layer_vary[i].y) break;

				od += cloud_density(i, p + L * s, a, k < 2, ds) * ds;
				t += ds;
			}

			return od;
		}

		// what the layers above layer i let through of the light, one sample through each
		float cloud_upper_transmittance(int i, vec3 p, float alt, vec3 L, float L_up) {
			// one sample stands for the whole column
			const float COLUMN_FOOTPRINT = 400.0;
			float top = CLOUD_BLOCK.cloud_layer_shape[i].x + CLOUD_BLOCK.cloud_layer_shape[i].y + CLOUD_BLOCK.cloud_layer_vary[i].y;
			float od = 0.0;

			for (int j = 0; j < CLOUD_BLOCK.cloud_layer_count; j++) {
				vec4 shape = CLOUD_BLOCK.cloud_layer_shape[j];

				if (j == i || shape.x - CLOUD_BLOCK.cloud_layer_vary[j].y < top) continue;

				float mid = shape.x + shape.y * 0.5;
				float s = (mid - alt) / L_up;
				vec3 q = p + L * s;

				if (CLOUD_BLOCK.cloud_layer_style[j].w > 0.5) {
					od += cloud_flat_optical_depth(j, q) / L_up;
				} else {
					// a layer's column is about a third as dense as its middle
					od += cloud_density(j, q, mid, false, COLUMN_FOOTPRINT) * shape.y * 0.6 / L_up;
				}
			}

			return exp(-od);
		}

		// premultiplied radiance (absolute) of the clouds along the ray up to t_max, and the share of
		// what is behind them that comes through. depth is the distance to what was seen, weighted by
		// how much of it was seen, or the end of the last layer the ray went through. quality scales
		// the number of steps
		vec4 cloud_march(vec3 origin, vec3 dir, float t_max, float jitter, float quality, out float depth) {
			cloud_ray_t r = cloud_ray(origin, dir);
			// the planet's surface hides what is past it, from high up the clouds on its far side too
			vec2 ground = cloud_sphere(r, 0.0);

			if (ground.x > 0.0 && ground.x <= ground.y) t_max = min(t_max, ground.x);
			int count = 0;
			vec2 segs[CLOUD_MAX_SEGMENTS];
			int seg_layer[CLOUD_MAX_SEGMENTS];

			for (int i = 0; i < CLOUD_BLOCK.cloud_layer_count; i++) {
				vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
				vec4 seg;
				float vary = CLOUD_BLOCK.cloud_layer_vary[i].y;
				int n = cloud_shell(r, shape.x - vary, shape.x + shape.y + vary, t_max, seg);

				for (int k = 0; k < n; k++) {
					vec2 s = k == 0 ? seg.xy : seg.zw;
					// sorted by distance as they come in
					int j = count;

					while (j > 0 && segs[j - 1].x > s.x) {
						segs[j] = segs[j - 1];
						seg_layer[j] = seg_layer[j - 1];
						j--;
					}

					segs[j] = s;
					seg_layer[j] = i;
					count++;
				}
			}

			depth = count > 0 ? segs[count - 1].y : t_max;

			if (count == 0) return vec4(0.0, 0.0, 0.0, 1.0);

			vec3 L = normalize(CLOUD_BLOCK.cloud_light_direction.xyz);
			float mu = dot(dir, L);
			// the light at the clouds, through the air above them
			vec3 first_point = origin + dir * segs[0].x;
			vec3 light = CLOUD_BLOCK.cloud_light_illuminance.rgb * sample_transmittance_lut(get_atmosphere_camera_origin(first_point), L);
			// the sky over the clouds and the ground under them, as radiance averaged over directions
			vec3 sky_origin = get_atmosphere_camera_origin(origin);
			vec3 sky_irradiance = get_sky_irradiance_clear(sky_origin);
			vec3 ambient_top = sky_irradiance / PI;
			float light_up = max(dot(normalize(sky_origin), L), 0.0);
			// vegetation and soil, darker than the sky model's ground
			vec3 ambient_bottom = 0.15 / PI * (light * light_up * CLOUD_BLOCK.cloud_mean_transmittance + sky_irradiance);
			vec3 radiance = vec3(0.0);
			float transmittance = 1.0;
			float depth_sum = 0.0;
			float depth_weight = 0.0;
			int light_steps = quality >= 1.0 ? 6 : 4;

			for (int s = 0; s < count && transmittance > CLOUD_HIDDEN_TRANSMITTANCE; s++) {
				int i = seg_layer[s];
				vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
				float t0 = segs[s].x;
				float t1 = segs[s].y;
				float length_ = t1 - t0;

				if (CLOUD_BLOCK.cloud_layer_style[i].w > 0.5) {
					float t = 0.5 * (t0 + t1);
					vec3 p = origin + dir * t;
					vec3 up = cloud_up(p);
					// through a slab of the layer's thickness along the ray
					float slant = clamp(length_ / shape.y, 1.0, 40.0);
					float od = cloud_flat_optical_depth(i, p) * slant;

					if (od > 1e-4) {
						float L_up = dot(up, L);
						float T = exp(-od);
						// ice crystals: forward peaked, and thin enough for single scattering
						float phase = mix(cloud_hg(mu, 0.75), cloud_hg(mu, -0.1), 0.3);
						float upper = L_up > 0.01 ? cloud_upper_transmittance(i, p, shape.x + shape.y * 0.5, L, L_up) : 0.0;
						vec3 S = light * phase * upper * smoothstep(-0.05, 0.05, L_up) + ambient_top;
						radiance += transmittance * (1.0 - T) * S;
						depth_sum += t * transmittance * (1.0 - T);
						depth_weight += transmittance * (1.0 - T);
						transmittance *= T;
					}

					continue;
				}

				// empty space is crossed in coarse steps without the detail. once one lands in a cloud the
				// ray steps back and goes on in fine steps with it, until it has been in the clear for a
				// while. steps shrink with the layer's depth, and grow with distance where the detail is
				// lost anyway
				float fine_size = clamp(shape.y / 120.0, 8.0, 30.0) / quality;
				float t = t0 + jitter * fine_size * CLOUD_COARSE_STEPS;
				int empty = CLOUD_EMPTY_STEPS;
				int budget = int(256.0 * quality);

				for (int k = 0; k < budget && t < t1; k++) {
					float dt = max(fine_size, t * 0.002 / quality);

					if (empty >= CLOUD_EMPTY_STEPS) {
						dt *= CLOUD_COARSE_STEPS;
						float tc = t + dt * 0.5;

						if (cloud_density(i, origin + dir * tc, cloud_altitude(r, tc), false, dt) <= 0.0) {
							t += dt;
							continue;
						}

						// the cloud starts somewhere within this coarse step
						empty = 0;
						dt /= CLOUD_COARSE_STEPS;
					}

					dt = min(dt, t1 - t);
					float ts = t + dt * 0.5;
					t += dt;
					vec3 p = origin + dir * ts;
					float alt = cloud_altitude(r, ts);
					float density = cloud_density(i, p, alt, true, dt);

					if (density <= 0.0) {
						empty++;
						continue;
					}

					empty = 0;

					// what is still to come adds no light that shows, but the sun behind is bright enough
					// to show through until the cloud is much denser
					if (transmittance < CLOUD_LIT_TRANSMITTANCE) {
						transmittance *= exp(-density * dt);

						if (transmittance < CLOUD_HIDDEN_TRANSMITTANCE) break;

						continue;
					}

					vec3 up = cloud_up(p);
					float L_up = dot(up, L);
					float light_od = cloud_light_optical_depth(i, p, alt, L, max(L_up, 0.02), light_steps);
					float upper = L_up > 0.01 ? cloud_upper_transmittance(i, p, alt, L, L_up) : 1.0;
					float hf = cloud_saturate((alt - shape.x) / shape.y);
					// light scattered deeper in comes out more often than at the very edge of a crease
					float powder = mix(1.0 - exp(-density * 60.0), 1.0, 0.5 + 0.5 * mu);
					vec3 sun = light * (cloud_scattering(light_od, mu) * upper * powder * smoothstep(-0.1, 0.02, L_up));
					// the ambient comes in through the top and the bottom, through the layer's column above
					// and below, and multiple scattering carries it much further than the direct light
					float column = shape.w * shape.y * ]] .. string.format("%.3f", MEAN_SHAPE_DENSITY * 0.05) .. [[;
					vec3 ambient = ambient_top * exp(-column * (1.0 - hf)) + ambient_bottom * exp(-column * hf);
					vec3 S = density * (sun + ambient);
					float T = exp(-density * dt);
					// the scattering within the step, attenuated on its way out (Hillaire 2015)
					radiance += transmittance * (S - S * T) / density;
					depth_sum += ts * transmittance * (1.0 - T);
					depth_weight += transmittance * (1.0 - T);
					transmittance *= T;
				}
			}

			if (depth_weight > 1e-3) depth = depth_sum / depth_weight;

			transmittance *= smoothstep(CLOUD_HIDDEN_TRANSMITTANCE, CLOUD_HIDDEN_TRANSMITTANCE * 10.0, transmittance);

			return vec4(radiance, transmittance);
		}

		// optical depth through every layer along the ray, for the shadow map. front is where the first
		// cloud is, back where the last one ends
		float cloud_march_optical_depth(vec3 origin, vec3 dir, float t_max, float jitter, out float front, out float back) {
			cloud_ray_t r = cloud_ray(origin, dir);
			float od = 0.0;
			front = 1e30;
			back = 0.0;

			for (int i = 0; i < CLOUD_BLOCK.cloud_layer_count; i++) {
				vec4 shape = CLOUD_BLOCK.cloud_layer_shape[i];
				vec4 seg;
				float vary = CLOUD_BLOCK.cloud_layer_vary[i].y;
				int n = cloud_shell(r, shape.x - vary, shape.x + shape.y + vary, t_max, seg);

				for (int k = 0; k < n; k++) {
					vec2 s = k == 0 ? seg.xy : seg.zw;

					if (CLOUD_BLOCK.cloud_layer_style[i].w > 0.5) {
						float t = 0.5 * (s.x + s.y);
						float layer_od = cloud_flat_optical_depth(i, origin + dir * t) * clamp((s.y - s.x) / shape.y, 1.0, 40.0);

						if (layer_od > 1e-4) {
							od += layer_od;
							front = min(front, s.x);
							back = max(back, s.y);
						}

						continue;
					}

					int steps = int(clamp(ceil((s.y - s.x) / (shape.y / 24.0)), 4.0, 48.0));
					float dt = (s.y - s.x) / float(steps);

					for (int j = 0; j < steps; j++) {
						float t = s.x + (float(j) + jitter) * dt;
						float density = cloud_density(i, origin + dir * t, cloud_altitude(r, t), false, dt);

						if (density > 0.0) {
							od += density * dt;
							front = min(front, t - dt * 0.5);
							back = max(back, t + dt * 0.5);
						}
					}
				}
			}

			return od;
		}
	]]
end

if HOTRELOAD then
	for _, tex in pairs(clouds.textures) do
		if type(tex) == "table" and tex.Remove then tex:Remove() end
	end

	clouds.textures = {}
end

return clouds
