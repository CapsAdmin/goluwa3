local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local ddgi = {}
pvars.StartGroup("Lighting", "DDGI", {store = false, prefix = "ddgi_"})

event.AddListener("Render3DPassToggled", "ddgi", function(name, value)
	if name == "ddgi" and value then ddgi.ResetHistory() end
end)

ddgi.PROBES_PER_AXIS = 24
local probe_spacing = pvars.Setup2{
	key = "ddgi_probe_spacing",
	default = 0.5,
	min = 0.1,
	help = "meters between the finest cascade's probes",
}
local cascade_ratio = pvars.Setup2{
	key = "ddgi_cascade_ratio",
	default = 2,
	min = 1.25,
	max = 8,
	help = "how many times further apart the probes of each cascade are than those of the one before, the coarsest is that ratio cubed times the spacing of the finest. a lower ratio keeps probes fine for longer but the cascades together reach less far",
}
ddgi.CASCADES = 10
ddgi.CASCADE_BLEND = 2.0
local update_interval_min = pvars.Setup2{
	key = "ddgi_update_interval_min",
	default = 1,
	integer = true,
	min = 1,
	max = 64,
	help = "frames between updates of the finest cascade. the cascades between it and the coarsest wait geometrically more",
}
local update_interval_max = pvars.Setup2{
	key = "ddgi_update_interval_max",
	default = 64,
	integer = true,
	min = 1,
	max = 64,
	help = "frames between updates of the coarsest cascade, the further cascades reach the longer they can wait, but lighting that changes shows up in them that much later",
}

function ddgi.GetUpdateInterval(c)
	local lowest = update_interval_min:Get()

	return math.max(1, math.floor(lowest * (update_interval_max:Get() / lowest) ^ ((c - 1) / (ddgi.CASCADES - 1)) + 0.5))
end

local min_coverage = pvars.Setup2{
	key = "ddgi_min_coverage",
	default = 4,
	min = 0,
	help = "least meters the fitted region reaches from its centre to each side",
}
local max_coverage = pvars.Setup2{
	key = "ddgi_max_coverage",
	default = 4000,
	min = 0,
	help = "most meters the fitted region reaches from the camera",
}
local change_threshold = pvars.Setup2{
	key = "ddgi_change_threshold",
	default = 0.05,
	min = 0,
	help = "how far the sun may move (radians, plus its relative brightness change) before a cascade updates ahead of its interval, 0 turns it off",
}
local change_min_interval = pvars.Setup2{
	key = "ddgi_change_min_interval",
	default = 2,
	integer = true,
	min = 1,
	help = "least frames between two updates of a cascade that were triggered by the lighting changing",
}
ddgi.MIN_PROBES_PER_AXIS = 4
ddgi.RAYS_PER_PROBE = 128
ddgi.HALF_PRECISION_RAYS = true
ddgi.ALPHA_TEST = scene_bvh.SOUP_UVS
ddgi.ALBEDO_UVS = scene_bvh.SOUP_UVS
ddgi.ALBEDO_UV_TEXELS = 8
ddgi.EMITTER_SAMPLES = 32
local emitters_enabled = pvars.Setup2{
	key = "ddgi_emitters",
	default = true,
	help = "emissive surfaces light the probes, off is for telling whether they cause noise",
}
local additive_emitters = pvars.Setup2{
	key = "ddgi_additive_emitters",
	default = false,
	help = "additive materials light the probes like emissive surfaces do",
}
ddgi.LIGHT_SAMPLES = 2
ddgi.IRRADIANCE_TEXELS = 8
ddgi.DISTANCE_TEXELS = 16
local hysteresis = pvars.Setup2{
	key = "ddgi_hysteresis",
	default = 0.99,
	min = 0,
	max = 1,
	help = "how much of a probe texel's history survives a frame at 60 fps, a cascade that updates less often keeps this to the power of the frames it was away",
}
local ray_clamp = pvars.Setup2{
	key = "ddgi_ray_clamp",
	default = 0,
	min = 0,
	help = "cap each ray's radiance at this many times the probe's mean ray luminance, 0 is off",
}
local guided_ray_fraction = pvars.Setup2{
	key = "ddgi_guided_rays",
	default = 0.7,
	min = 0,
	max = 0.75,
	help = "share of each probe's rays aimed by its own radiance map, 0 is uniform rays only",
}

function ddgi.GetUniformRays()
	return ddgi.RAYS_PER_PROBE - math.floor(ddgi.RAYS_PER_PROBE * guided_ray_fraction:Get() + 0.5)
end

local light_radius = pvars.Setup2{
	key = "ddgi_light_radius",
	default = 0.1,
	min = 0,
	help = "radius of local lights in probe spacings when lighting ray hits",
}
ddgi.DISTANCE_EXPONENT = 50.0
ddgi.NORMAL_BIAS = 0.1
ddgi.VIEW_BIAS = 0.3
ddgi.BACKFACE_THRESHOLD = 0.25
local relocation = pvars.Setup2{
	key = "ddgi_relocation",
	default = true,
	help = "move probes out of geometry",
	callback = function()
		ddgi.ResetHistory()
	end,
}
ddgi.RELOCATION_DISTANCE = 0.25
ddgi.PROBE_MAX_OFFSET = 0.45
local strength = pvars.Setup2{
	key = "ddgi_strength",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the light the probes give every surface (diffuse gi, the reflection fallback, translucent surfaces, traced hits, fog), the probes' own bounces are not scaled. 0 is no indirect light from them",
}
ddgi.SKY_INTENSITY = 1.0
ddgi.RANDOM_ROTATION = true
local RESOLVE_MEGAPIXELS = {["0.25mp"] = 0.25, ["0.5mp"] = 0.5, ["1mp"] = 1, native = math.huge}
local resolve_resolution = pvars.Setup2{
	key = "ddgi_resolve_resolution",
	default = "0.25mp",
	enums = {"0.25mp", "0.5mp", "1mp", "native"},
	help = "the pixel count the gi seen by the screen is resolved at, in megapixels, whatever the window size. it is upsampled to the screen with depth and normal weights. native resolves every pixel",
	callback = function()
		local resolve = render3d.pipelines and render3d.pipelines.ddgi_resolve

		if resolve then resolve:RecreateFramebuffers() end
	end,
}
local smooth_blend = pvars.Setup2{
	key = "ddgi_smooth_blend",
	default = true,
	help = "blend 3x3x3 probes with quadratic B-spline weights",
}
local VISIBILITY_RAYS = {none = 0, relocated = 1, all = 2}
local visibility_rays = pvars.Setup2{
	key = "ddgi_visibility_rays",
	default = "all",
	enums = {"none", "relocated", "all"},
	help = "probes checked with a ray: none, only the relocated ones, or all",
}
local visibility_front_faces_only = pvars.Setup2{
	key = "ddgi_visibility_front_faces_only",
	default = true,
	help = "visibility rays only hit front faces",
}
local DEBUG_PROBES = {off = 0, irradiance = 1, hit_distance = 2}
local debug_probes = pvars.Setup2{
	key = "ddgi_debug_probes",
	default = "off",
	enums = {"off", "irradiance", "hit_distance"},
	help = "what the probe debug markers show: the probe irradiance or its mean hit distance",
}
local DEBUG_SCENE = {off = 0, albedo = 1, normals = 2, hit_distance = 3}
local debug_scene = pvars.Setup2{
	key = "ddgi_debug_scene",
	default = "off",
	enums = {"off", "albedo", "normals", "hit_distance"},
	help = "show the scene the probe rays trace as its albedo, normals or hit distance",
}
local debug_gi = pvars.Setup2{
	key = "ddgi_debug_gi",
	default = false,
	help = "show only the gi irradiance",
}
local debug_scale = pvars.Setup2{
	key = "ddgi_debug_scale",
	default = 1.0,
	min = 0,
	help = "brightness of the debug markers",
}
local debug_cascade = pvars.Setup2{
	key = "ddgi_debug_cascade",
	default = 0,
	integer = true,
	min = 0,
	max = ddgi.CASCADES - 1,
	help = "the cascade whose probes the debug view draws",
}
local max_ray_distance = pvars.Setup2{
	key = "ddgi_max_ray_distance",
	default = 4000,
	integer = true,
	min = 0,
	help = "max distance a ray can travel",
}
pvars.EndGroup()
ddgi.MISS_DISTANCE = ddgi.HALF_PRECISION_RAYS and 60000 or 1e27

function ddgi.GetDebugProbes()
	return DEBUG_PROBES[debug_probes:Get()]
end

function ddgi.IsDebugGI()
	return debug_gi:Get()
end

function ddgi.GetCascadeSpacing(cascade)
	return probe_spacing:Get() * cascade_ratio:Get() ^ cascade
end

function ddgi.GetProbeCount()
	return ddgi.PROBES_PER_AXIS ^ 3 * ddgi.CASCADES
end

function ddgi.GetRayCount()
	return ddgi.GetProbeCount() * (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES)
end

function ddgi.GetScreenTexture()
	if not render3d.IsPassEnabled("ddgi") then return nil end

	local resolve = render3d.pipelines.ddgi_resolve
	return resolve and resolve:GetFramebuffer(1):GetAttachment(1) or nil
end

function ddgi.GetScreenGeometryTexture()
	if not render3d.IsPassEnabled("ddgi") then return nil end

	local resolve = render3d.pipelines.ddgi_resolve
	return resolve and resolve:GetFramebuffer(1):GetAttachment(2) or nil
end

function ddgi.GetScreenSpecularTexture()
	if not render3d.IsPassEnabled("ddgi") then return nil end

	local resolve = render3d.pipelines.ddgi_resolve
	return resolve and resolve:GetFramebuffer(1):GetAttachment(3) or nil
end

function ddgi.GetResolveScale()
	local size = render.GetRenderImageSize()
	return math.min(1, math.sqrt(RESOLVE_MEGAPIXELS[resolve_resolution:Get()] * 1000000 / (size.x * size.y)))
end

function ddgi.GetScreenSampleGLSL(block_name)
	return [[
		vec4 ddgi_screen_sample_texture(int screen_tex, vec2 uv, vec3 N, float view_depth) {
			ivec2 size = textureSize(TEXTURE(screen_tex), 0);
			vec2 position = uv * vec2(size) - 0.5;
			ivec2 base = ivec2(floor(position));
			vec2 fraction = position - vec2(base);
			vec4 sum = vec4(0.0);
			float total = 0.0;
			// a texel covers more pixels of thin geometry the further away it is, so its stand-in is matched less strictly
			float far = smoothstep(20.0, 200.0, view_depth);

			for (int i = 0; i < 4; i++) {
				ivec2 corner = ivec2(i & 1, i >> 1);
				float w = (corner.x == 1 ? fraction.x : 1.0 - fraction.x) * (corner.y == 1 ? fraction.y : 1.0 - fraction.y);

				if (w <= 0.0) continue;

				ivec2 texel = clamp(base + corner, ivec2(0), size - 1);
				vec4 geometry = texelFetch(TEXTURE(]] .. block_name .. [[.gi_screen_geometry_tex), texel, 0);
				float depth_weight = exp(-abs(view_depth - geometry.w) / max(view_depth * mix(0.02, 0.1, far), 0.02));
				float normal_weight = pow(max(dot(N, geometry.xyz), 0.0), mix(16.0, 4.0, far));
				w *= depth_weight * normal_weight + 1e-4;
				sum += texelFetch(TEXTURE(screen_tex), texel, 0) * w;
				total += w;
				}
				
				return sum / total;
				}
				
				vec4 ddgi_screen_sample(vec2 uv, vec3 N, float view_depth) {
				return ddgi_screen_sample_texture(]] .. block_name .. [[.gi_screen_tex, uv, N, view_depth);
				}
				
				// the gi along the reflection direction of a rough surface (see ddgi_resolve)
				vec4 ddgi_screen_specular_sample(vec2 uv, vec3 N, float view_depth) {
				return ddgi_screen_sample_texture(]] .. block_name .. [[.gi_screen_specular_tex, uv, N, view_depth);
				}
	]]
end

function ddgi.GetDebugSceneMode()
	return DEBUG_SCENE[debug_scene:Get()]
end

function ddgi.GetDebugOverlayTexture()
	if ddgi.GetDebugProbes() == 0 then return nil end

	return render3d.pipelines.ddgi_probe_debug:GetFramebuffer(1):GetAttachment(1)
end

function ddgi.RTSupported()
	return render.GetDevice().ray_tracing_supported
end

function ddgi.ResetHistory()
	ddgi.force_reset = true
end

do
	local state = {
		frame = -1,
		cascades = {},
		cascade_count = 0,
		region = {},
		rotation = {x = 0, y = 0, z = 0, w = 1},
		reset_mask = 0,
		update_mask = 0,
		rt_ready = false,
	}

	local function random_rotation(q)
		local u1, u2, u3 = math.random(), math.random() * 2 * math.pi, math.random() * 2 * math.pi
		local a, b = math.sqrt(1 - u1), math.sqrt(u1)
		q.x = a * math.sin(u2)
		q.y = a * math.cos(u2)
		q.z = b * math.sin(u3)
		q.w = b * math.cos(u3)
	end

	local function fit_region(axis, camera, bounds_min, bounds_max)
		local lo, hi = camera - min_coverage:Get(), camera + min_coverage:Get()

		if bounds_min then
			lo = math.max(bounds_min[axis], camera - max_coverage:Get())
			hi = math.min(bounds_max[axis], camera + max_coverage:Get())

			if hi < lo then
				lo, hi = camera - min_coverage:Get(), camera + min_coverage:Get()
			end
		end

		if hi - lo < min_coverage:Get() * 2 then
			local mid = (lo + hi) / 2
			lo, hi = mid - min_coverage:Get(), mid + min_coverage:Get()
		end

		return lo, hi
	end

	local function fit_need(size, spacing, current)
		local need = math.ceil(size / spacing) + 4

		if current and current >= need and current <= need + math.max(2, need * 0.25) then
			return current
		end

		return need
	end

	local function distribute(cascade)
		local budget = ddgi.PROBES_PER_AXIS ^ 3
		local a, b, c = "x", "y", "z"
		local need = cascade.need

		if need[a] > need[b] then a, b = b, a end

		if need[b] > need[c] then b, c = c, b end

		if need[a] > need[b] then a, b = b, a end

		local n = math.max(math.min(need[a], math.floor(budget ^ (1 / 3) + 1e-6)), ddgi.MIN_PROBES_PER_AXIS)
		cascade.size[a] = n
		budget = math.floor(budget / n)
		n = math.max(math.min(need[b], math.floor(math.sqrt(budget) + 1e-6)), ddgi.MIN_PROBES_PER_AXIS)
		cascade.size[b] = n
		budget = math.floor(budget / n)
		cascade.size[c] = math.max(math.min(need[c], budget), ddgi.MIN_PROBES_PER_AXIS)
	end

	local function fit_base(camera, lo, hi, spacing, count)
		local lo_cell, hi_cell = math.floor(lo / spacing) - 1, math.ceil(hi / spacing) + 1

		if hi_cell - lo_cell <= count - 1 then
			return lo_cell - math.floor((count - 1 - (hi_cell - lo_cell)) / 2), true
		end

		return math.clamp(
			math.floor(camera / spacing) - math.floor(count / 2),
			lo_cell,
			hi_cell - (count - 1)
		),
		false
	end

	function ddgi.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		local position = render3d.GetCamera():GetPosition()
		local bounds_min, bounds_max = scene_bvh.GetBounds()
		local region = state.region
		region.min_x, region.max_x = fit_region(0, position.x, bounds_min, bounds_max)
		region.min_y, region.max_y = fit_region(1, position.y, bounds_min, bounds_max)
		region.min_z, region.max_z = fit_region(2, position.z, bounds_min, bounds_max)
		local frame_time = system.GetFrameTime()
		local irradiance = render3d.pipelines.ddgi_irradiance
		local framebuffers = irradiance and irradiance.framebuffers
		local reset_mask = 0
		local update_mask = 0

		if ddgi.force_reset or framebuffers ~= state.history_framebuffers then
			reset_mask = bit.lshift(1, ddgi.CASCADES) - 1
		end

		local count = ddgi.CASCADES
		local lights = render3d.GetLights()
		local sun = directional_shadows.GetPrimarySunDirection(lights)
		local sun_x, sun_y, sun_z = sun.x, sun.y, sun.z
		local sun_luma = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, sun_y)
		local threshold = change_threshold:Get()
		local reference = state.sun_reference

		-- what the probes hold was lit by a sun that is gone (the sun moved or changed brightness by the same
		-- measure as above since a few frames ago), so their history gives way to the new rays for a short while
		if not reference or frame - reference.frame >= 8 then
			if reference and threshold > 0 then
				local luma_change = math.abs(sun_luma - reference.luma) / math.max(sun_luma, reference.luma, 1e-3)
				local moved = math.sqrt((sun_x - reference.x) ^ 2 + (sun_y - reference.y) ^ 2 + (sun_z - reference.z) ^ 2)

				if moved + luma_change > threshold then state.sun_fast_until = frame + 60 end
			end

			reference = reference or {}
			reference.x, reference.y, reference.z, reference.luma, reference.frame = sun_x, sun_y, sun_z, sun_luma, frame
			state.sun_reference = reference
		end

		for c = 1, ddgi.CASCADES do
			local spacing = ddgi.GetCascadeSpacing(c - 1)
			local cascade = state.cascades[c] or {need = {}, size = {}}
			local need, size = cascade.need, cascade.size
			local old_x, old_y, old_z = size.x, size.y, size.z

			if bounds_min then
				need.x = fit_need(region.max_x - region.min_x, spacing, need.x)
				need.y = fit_need(region.max_y - region.min_y, spacing, need.y)
				need.z = fit_need(region.max_z - region.min_z, spacing, need.z)
				distribute(cascade)
			else
				size.x, size.y, size.z = ddgi.PROBES_PER_AXIS, ddgi.PROBES_PER_AXIS, ddgi.PROBES_PER_AXIS
			end

			if
				c > state.cascade_count or
				spacing ~= cascade.spacing or
				size.x ~= old_x or
				size.y ~= old_y or
				size.z ~= old_z
			then
				reset_mask = bit.bor(reset_mask, bit.lshift(1, c - 1))
			end

			cascade.spacing = spacing
			local holds_x, holds_y, holds_z
			cascade.x, holds_x = fit_base(position.x, region.min_x, region.max_x, spacing, size.x)
			cascade.y, holds_y = fit_base(position.y, region.min_y, region.max_y, spacing, size.y)
			cascade.z, holds_z = fit_base(position.z, region.min_z, region.max_z, spacing, size.z)
			cascade.elapsed = (cascade.elapsed or 0) + frame_time
			local interval = ddgi.GetUpdateInterval(c)
			cascade.frames = (cascade.frames or 0) + 1
			local changed = false

			if threshold > 0 and cascade.sun_x and cascade.frames >= change_min_interval:Get() then
				local dx, dy, dz = sun_x - cascade.sun_x, sun_y - cascade.sun_y, sun_z - cascade.sun_z
				local old_luma = cascade.sun_luma
				local luma_change = math.abs(sun_luma - old_luma) / math.max(sun_luma, old_luma, 1e-3)
				changed = math.sqrt(dx * dx + dy * dy + dz * dz) + luma_change > threshold
			end

			if
				changed or
				(
					frame + c - 1
				) % interval == 0 or
				bit.band(reset_mask, bit.lshift(1, c - 1)) ~= 0 or
				cascade.x ~= cascade.updated_x or
				cascade.y ~= cascade.updated_y or
				cascade.z ~= cascade.updated_z
			then
				update_mask = bit.bor(update_mask, bit.lshift(1, c - 1))
				cascade.updated_x, cascade.updated_y, cascade.updated_z = cascade.x, cascade.y, cascade.z
				cascade.update_time = cascade.elapsed
				cascade.elapsed = 0
				cascade.frames = 0
				cascade.sun_x, cascade.sun_y, cascade.sun_z, cascade.sun_luma = sun_x, sun_y, sun_z, sun_luma
			end

			cascade.holds = bounds_min and
				(
					(
						holds_x and
						1 or
						0
					) + (
						holds_y and
						2 or
						0
					) + (
						holds_z and
						4 or
						0
					)
				)
				or
				0
			state.cascades[c] = cascade

			if
				bounds_min and
				c < count and
				size.x >= need.x and
				size.y >= need.y and
				size.z >= need.z
			then
				count = c
			end
		end

		state.cascade_count = count
		state.reset_mask = reset_mask
		state.update_mask = bit.band(update_mask, bit.lshift(1, count) - 1)

		if ddgi.RANDOM_ROTATION then
			random_rotation(state.rotation)
		else
			state.rotation.x, state.rotation.y, state.rotation.z, state.rotation.w = 0, 0, 0, 1
		end

		state.history_framebuffers = framebuffers
		state.rt_ready = false
		ddgi.force_reset = false
		return state
	end
end

function ddgi.GetRayDirection(index, n, rotation)
	local golden = (math.sqrt(5) - 1) / 2
	local phi = 2 * math.pi * ((index * golden) % 1)
	local cos_theta = 1 - (2 * index + 1) / n
	local sin_theta = math.sqrt(math.max(0, 1 - cos_theta * cos_theta))
	local x, y, z = math.cos(phi) * sin_theta, math.sin(phi) * sin_theta, cos_theta
	local qx, qy, qz, qw = rotation.x, rotation.y, rotation.z, rotation.w
	local cx = qy * z - qz * y + qw * x
	local cy = qz * x - qx * z + qw * y
	local cz = qx * y - qy * x + qw * z
	return x + 2 * (qy * cz - qz * cy),
	y + 2 * (qz * cx - qx * cz),
	z + 2 * (qx * cy - qy * cx)
end

function ddgi.GetDefinesGLSL()
	return (
		[[
		#define DDGI_P %d
		#define DDGI_CASCADES %d
		#define DDGI_RAYS %d
		#define DDGI_EMITTER_SAMPLES %d
		#define DDGI_EMITTER_CANDIDATES 16
		// ddgi_emitter.triangle: the soup index, and the material's double sidedness
		#define DDGI_EMITTER_DOUBLE_SIDED 0x80000000u
		// a probe's uniform rays followed by its emitter samples
		#define DDGI_RAY_STRIDE (DDGI_RAYS + DDGI_EMITTER_SAMPLES)
		#define DDGI_IRRADIANCE_TEXELS %d
		#define DDGI_DISTANCE_TEXELS %d
		#define DDGI_MISS_DISTANCE %.1e
		// what the ray texture can hold, and the bits per octahedral axis of an
		// emitter sample's direction, which has to sit exactly in one of its floats
		#define DDGI_RAY_MAX %.1e
		#define DDGI_DIRECTION_BITS %du
		#define DDGI_DIRECTION_OFFSET %.1f
		#define DDGI_SUN_VISIBLE_BIT 0x80000000u
		#define DDGI_SHADOW_OFFSET 0.02
		#define DDGI_LIGHT_SAMPLES %d
		#define DDGI_BACKFACE_SCALE 0.2
		// GLSL leaves %% undefined for negative operands (NVIDIA treats them
		// as unsigned), so shift into the positive range before wrapping
		#define DDGI_WRAP(v, n) (((v) + (n) * 65536) %% (n))
		// the instances a probe's visibility ray can hit, which leaves out foliage and refractive surfaces with ddgi.ALPHA_TEST
		#define DDGI_VISIBILITY_MASK %d
		// a settled probe inside geometry has nothing to light and is retraced about once in
		// DDGI_DISABLED_PROBE_FRAMES frames, to notice the geometry around it changing, whatever its
		// cascade's own update interval is. data_w is the probe data's w. neighbouring probes are
		// retraced together, so that the warps that work on them are idle or not as a whole
		#define DDGI_DISABLED_PROBE_FRAMES 8u

		bool ddgi_probe_idle(float data_w, bool current, int probe, int c, uint frame) {
			// disabled and not moved
			if (!current || (int((data_w - 1.0) * 0.5) & 3) != 2) return false;

			uint h = uint(probe >> 5) * 747796405u + uint(c) * 2891336453u + frame * 277803737u;
			h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
			h = (h >> 22u) ^ h;
			return h %% max(DDGI_DISABLED_PROBE_FRAMES >> uint(c), 1u) != 0u;
		}
	]]
	):format(
		ddgi.PROBES_PER_AXIS,
		ddgi.CASCADES,
		ddgi.RAYS_PER_PROBE,
		ddgi.EMITTER_SAMPLES,
		ddgi.IRRADIANCE_TEXELS,
		ddgi.DISTANCE_TEXELS,
		ddgi.MISS_DISTANCE,
		ddgi.HALF_PRECISION_RAYS and 65000 or 3e38,
		ddgi.HALF_PRECISION_RAYS and 6 or 12,
		ddgi.HALF_PRECISION_RAYS and 2048 or 0,
		ddgi.LIGHT_SAMPLES,
		ddgi.ALPHA_TEST and scene_bvh.RAY_MASK_SOLID or 0xFF
	)
end

function ddgi.GetRayDirectionGLSL()
	return glsl_common.GetOctahedralGLSL() .. [[
		#define DDGI_GUIDE_TEXELS 8
		#define DDGI_GUIDE_CELLS 64
		// how much of its previous value a guide cell keeps each frame
		#define DDGI_GUIDE_HISTORY 0.9
		// what reads the guide texel of a probe's tile, so that the ray generation
		// shader and the guide pass can use their own bindings
		#ifndef DDGI_GUIDE_FETCH
		#define DDGI_GUIDE_FETCH(texel) texelFetch(TEXTURE(ddgi_data.ddgi_guide_tex), texel, 0)
		#endif

		// index of count spherical fibonacci points, rotated by q
		vec3 ddgi_fibonacci(uint index, uint count, vec4 q) {
			const float golden = 0.61803398875;
			float phi = 6.28318530718 * fract(float(index) * golden);
			float cos_theta = 1.0 - (2.0 * float(index) + 1.0) / float(count);
			float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
			vec3 v = vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
			return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
		}

		// The guide is one 8x8 octahedral tile per probe, in world space. Per
		// cell: r = mean radiance luminance, g = the probability a guided ray
		// picks the cell, b = cumulative probability up to and including it,
		// a = stamp of the probe that wrote it. A slot that a different probe
		// scrolled into has a stamp that does not match, and its rays are uniform.
		float ddgi_guide_stamp(ivec3 world, int c) {
			uint h = uint(world.x) * 73856093u ^ uint(world.y) * 19349663u ^ uint(world.z) * 83492791u ^ uint(c + 1) * 2654435761u;
			return float(h & 0xFFFFFFu) + 1.0;
		}

		ivec2 ddgi_guide_texel(ivec2 tile, int cell) {
			return tile * DDGI_GUIDE_TEXELS + ivec2(cell % DDGI_GUIDE_TEXELS, cell / DDGI_GUIDE_TEXELS);
		}

		bool ddgi_guide_valid(ivec2 tile, ivec3 world, int c) {
			return DDGI_GUIDE_FETCH(ddgi_guide_texel(tile, 0)).a == ddgi_guide_stamp(world, c);
		}

		// The first uniform_count rays of a probe are uniform, the rest are drawn
		// from the guide: stratified along its cumulative probability, then
		// anywhere in the cell. The jitter is derived from the frame's random
		// rotation.
		vec3 ddgi_ray_direction(uint index, uint uniform_count, vec4 q, ivec2 tile, bool guided) {
			if (index < uniform_count) return ddgi_fibonacci(index, uniform_count, q);

			uint k = index - uniform_count;
			uint guided_count = uint(DDGI_RAYS) - uniform_count;

			if (!guided) return ddgi_fibonacci(k, guided_count, q);

			vec3 jitter = fract(abs(q.xyz) * 1000.0 + q.w * 7.0);
			float u = fract((float(k) + 0.5) / float(guided_count) + jitter.x);
			int lo = 0;
			int hi = DDGI_GUIDE_CELLS - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (DDGI_GUIDE_FETCH(ddgi_guide_texel(tile, mid)).b < u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			vec2 inner = fract(vec2(0.7548776662, 0.5698402910) * float(k) + jitter.yz);
			vec2 p = (vec2(lo % DDGI_GUIDE_TEXELS, lo / DDGI_GUIDE_TEXELS) + inner) / float(DDGI_GUIDE_TEXELS) * 2.0 - 1.0;
			return oct_decode(p);
		}

		// What a ray of direction d counts for: the inverse of the density it was
		// drawn with (the uniform rays' and the guide's mixed by their share of
		// the rays), scaled so that uniform rays alone weigh 1. A cell's
		// probability spreads over its share of the octahedron's plane, and a
		// unit of that plane covers |d|_1^3 steradians.
		float ddgi_ray_weight(vec3 d, uint uniform_count, ivec2 tile, bool guided) {
			if (!guided || uniform_count >= uint(DDGI_RAYS)) return 1.0;

			ivec2 cell = clamp(ivec2((oct_encode(d) * 0.5 + 0.5) * float(DDGI_GUIDE_TEXELS)), ivec2(0), ivec2(DDGI_GUIDE_TEXELS - 1));
			float probability = DDGI_GUIDE_FETCH(tile * DDGI_GUIDE_TEXELS + cell).g;
			vec3 a = abs(d);
			float l1 = a.x + a.y + a.z;
			float density = probability * float(DDGI_GUIDE_TEXELS * DDGI_GUIDE_TEXELS) * 0.25 / (l1 * l1 * l1);
			float share = float(uniform_count) / float(DDGI_RAYS);
			return 1.0 / (share + (1.0 - share) * density * 12.5663706144);
		}
	]]
end

local MIN_WEIGHT = "0.05"
ddgi.MIN_WEIGHT = MIN_WEIGHT

function ddgi.GetEmitterDeclarationsGLSL(binding)
	return (
		[[
		// The emitters as words, built by ddgi.GetEmitters: 0 total power (float), 1 emitter
		// count, then the emitters, 3 words each: the triangle (and the double sided
		// bit), the cdf over all emitters (float), the power (float).
		layout(set = 0, binding = %d) readonly buffer DDGIEmitters {
			uint ddgi_grid[];
		};
	]]
	):format(binding)
end

function ddgi.GetMaterialDeclarationsGLSL(binding)
	return [[
		struct ddgi_material {
			vec3 albedo;
			int albedo_tex;
			int double_sided;
			// terrain: the layer weights texture, -1 for other materials
			int terrain_tex;
			ivec4 terrain_layer_tex;
			// min x, min z, 1 / size of the square terrain_tex covers
			vec3 terrain_bounds;
			vec4 terrain_detail;
			vec4 terrain_additive_detail;
			// layers 5 to 8 of a chunk that has more than four, -1 without
			int terrain_tex2;
			ivec4 terrain_layer_tex2;
			vec4 terrain_detail2;
			vec4 terrain_additive_detail2;
			float alpha;
			float alpha_cutoff;
			// 0 solid, 1 alpha tested by alpha alone, 2 by the albedo texture's alpha times alpha
			int alpha_test;
			// the sun's shadow ray passes through it and lights are tinted by it (see glass_light.lua)
			int glass;
			// displacement blending: the second albedo and the blend modulate texture, -1 without
			int albedo2_tex;
			int blend_tex;
			// translucent or refractive, reflections look through it
			int transparent;
			// refracts, adds to or modulates what is behind it, so probe rays go on through
			int refractive;
			// what a glass lets through: the share refracted through the albedo, and how much of the rest is covered
			float glass_refraction;
			float glass_covering;
			// metals have no diffuse: the multiplier, and the texture it scales (-1 without) with the channel to read
			float metallic;
			int metallic_tex;
			int metallic_channel;
			// perceptual roughness: the multiplier alone, or with a texture (-1 without) its channel mixed between min and max and scaled by it
			float roughness;
			float roughness_min;
			float roughness_max;
			int roughness_tex;
			int roughness_channel;
			};
		layout(scalar, set = 0, binding = ]] .. binding .. [[) readonly buffer DDGIMaterials {
			ddgi_material ddgi_materials[];
		};
	]]
end

function ddgi.GetMaterialGLSL()
	return [[
		// no uvs at a hit, so textured surfaces use the texture's average
		// colour from its smallest mip. terrain finds its uv from where it was
		// hit and blends its layers' averages like the gbuffer blends the layers
		vec3 ddgi_albedo(ddgi_material material, vec3 P) {
			if (material.terrain_tex >= 0) {
				vec2 uv = (P.xz - material.terrain_bounds.xy) * material.terrain_bounds.z;
				vec4 weights = max(textureLod(TEXTURE(material.terrain_tex), uv, 0.0), vec4(0.0));
				vec4 weights2 = material.terrain_tex2 >= 0 ? max(textureLod(TEXTURE(material.terrain_tex2), uv, 0.0), vec4(0.0)) : vec4(0.0);
				float weight_sum = dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0));

				if (weight_sum <= 0.0001) return material.albedo;

				weights /= weight_sum;
				weights2 /= weight_sum;
				vec3 base = material.albedo_tex >= 0 ? textureLod(TEXTURE(material.albedo_tex), uv, 0.0).rgb : vec3(1.0);
				vec3 albedo = vec3(0.0);

				for (int i = 0; i < 8; i++) {
					vec3 layer = base;
					bool second = i >= 4;
					int slot = second ? i - 4 : i;
					int layer_tex = second ? material.terrain_layer_tex2[slot] : material.terrain_layer_tex[slot];
					float weight = second ? weights2[slot] : weights[slot];

					if (weight <= 0.0) continue;

					if (layer_tex >= 0) {
						vec3 average = textureLod(TEXTURE(layer_tex), vec2(0.5), 16.0).rgb;
						float detail = second ? material.terrain_detail2[slot] : material.terrain_detail[slot];
						float additive = second ? material.terrain_additive_detail2[slot] : material.terrain_additive_detail[slot];

						if (detail <= 0.0) {
							layer = average * base;
						} else if (additive > 0.0) {
							layer = pow(max(pow(base, vec3(1.0 / 2.2)) + (average - 0.5) * detail, vec3(0.0)), vec3(2.2)) * additive;
						}
						// a non additive detail layer only varies around base
					}

					albedo += layer * weight;
				}

				return albedo * material.albedo;
			}

			vec3 albedo = material.albedo;

			if (material.albedo_tex >= 0) {
				albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;
			}

			return albedo;
		}

		// the share of the albedo a hit bounces. a metal has no diffuse, but a rough one scatters its colour over
// a lobe as wide as a diffuse surface's, a mirror one sends it one way, which a probe cannot hold
float ddgi_bounce_share(ddgi_material material) {
	float metallic = material.metallic;

	if (material.metallic_tex >= 0) {
		metallic *= textureLod(TEXTURE(material.metallic_tex), vec2(0.5), 16.0)[material.metallic_channel];
	}

	metallic = clamp(metallic, 0.0, 1.0);

	if (metallic <= 0.0) return 1.0;

	float roughness = material.roughness;

	if (material.roughness_tex >= 0) {
		roughness *= mix(material.roughness_min, material.roughness_max, textureLod(TEXTURE(material.roughness_tex), vec2(0.5), 16.0)[material.roughness_channel]);
	}

	return mix(1.0, smoothstep(0.1, 0.9, roughness), metallic);
}

vec3 ddgi_emission(scene_bvh_triangle tri, vec3 albedo) {
			return min(tri.emissive * albedo * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
		}
	]]
end

function ddgi.GetHitAlbedoGLSL()
	if not ddgi.ALBEDO_UVS then
		return [[
			vec3 ddgi_hit_albedo(ddgi_material material, vec3 P, uint triangle) {
				return ddgi_albedo(material, P);
			}
		]]
	end

	return [[
		#define DDGI_ALBEDO_UV_TEXELS ]] .. string.format("%.1f", ddgi.ALBEDO_UV_TEXELS) .. [[

		vec3 ddgi_hit_albedo(ddgi_material material, vec3 P, uint triangle) {
			if (material.terrain_tex >= 0 || material.albedo_tex < 0) return ddgi_albedo(material, P);

			scene_bvh_triangle tri = bvh_tri(triangle);
			vec3 p = P - tri.v0;
			float d00 = dot(tri.e1, tri.e1);
			float d01 = dot(tri.e1, tri.e2);
			float d11 = dot(tri.e2, tri.e2);
			float d20 = dot(p, tri.e1);
			float d21 = dot(p, tri.e2);
			float inv = 1.0 / (d00 * d11 - d01 * d01);
			float v = (d11 * d20 - d01 * d21) * inv;
			float w = (d00 * d21 - d01 * d20) * inv;
			scene_bvh_uv uv = bvh_uv(triangle);
			vec2 coord = uv.uv0 * (1.0 - v - w) + uv.uv1 * v + uv.uv2 * w;
			ivec2 size = textureSize(TEXTURE(material.albedo_tex), 0);
			float lod = max(log2(float(max(size.x, size.y)) / DDGI_ALBEDO_UV_TEXELS), 0.0);
			vec3 rgb = textureLod(TEXTURE(material.albedo_tex), coord, lod).rgb;

			if (material.albedo2_tex >= 0) {
				float blend = uv.blend.x * (1.0 - v - w) + uv.blend.y * v + uv.blend.z * w;

				if (material.blend_tex >= 0) {
					// source blendmodulate: g is the transition center, r its half width
					vec2 modulate = textureLod(TEXTURE(material.blend_tex), coord, lod).rg;
					blend = smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), blend);
				}

				if (blend != 0.0) {
					ivec2 size2 = textureSize(TEXTURE(material.albedo2_tex), 0);
					float lod2 = max(log2(float(max(size2.x, size2.y)) / DDGI_ALBEDO_UV_TEXELS), 0.0);
					rgb = mix(rgb, textureLod(TEXTURE(material.albedo2_tex), coord, lod2).rgb, blend);
				}
			}

			return material.albedo * rgb;
		}
	]]
end

function ddgi.GetAlphaTestGLSL()
	return [[
		bool ddgi_alpha_passes(uint triangle, vec2 barycentrics) {
			ddgi_material material = ddgi_materials[bvh_tri(triangle).material];

			if (material.alpha_test == 0) return true;

			float alpha = material.alpha;

			if (material.alpha_test == 2) {
				scene_bvh_uv uv = bvh_uv(triangle);
				vec2 coord = uv.uv0 * (1.0 - barycentrics.x - barycentrics.y) + uv.uv1 * barycentrics.x + uv.uv2 * barycentrics.y;
				alpha *= textureLod(TEXTURE(material.albedo_tex), coord, 0.0).a;
			}

			return alpha >= material.alpha_cutoff;
		}
	]]
end

function ddgi.GetEmitterGLSL()
	return glsl_common.GetHashGLSL() .. [[
		vec4 ddgi_emitter_random(uint index, uint frame, uint candidate) {
			return vec4(pcg4d(uvec4(index, frame, candidate, 0x9E3779B9u)) >> 8u) / 16777216.0;
		}

		uint ddgi_emitter_triangle(int e) {
			return ddgi_grid[2u + uint(e) * 3u];
		}

		int ddgi_pick_emitter(float u, int count) {
			int lo = 0;
			int hi = count - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (uintBitsToFloat(ddgi_grid[2u + uint(mid) * 3u + 1u]) < u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			return lo;
		}

		vec3 ddgi_emitter_point(scene_bvh_triangle tri, vec2 u) {
			if (u.x + u.y > 1.0) u = 1.0 - u;

			return tri.v0 + tri.e1 * u.x + tri.e2 * u.y;
		}

		// An emitter sample seen from origin: an emitter drawn by its power, a point on its
		// triangle. Returns the light it would bring unshadowed, facing / distance^2 (inside
		// radius flattened like the local lights), over the density it was drawn with, which
		// times the emitter's colour over its luminance is the estimate; which emitter and
		// where it was drawn is written to emitter and point, the shade pass rebuilds
		// its point from the same random numbers.
		// The light one drawn candidate would bring unshadowed: facing / distance^2 (flattened
		// inside radius), over the density it was drawn with (the emitter's share of the power)
		float ddgi_emitter_candidate_weight(uint index, uint frame, uint candidate, int emitter_count, vec3 origin, float radius) {
			vec4 u = ddgi_emitter_random(index, frame, candidate);
			uint triangle = ddgi_emitter_triangle(ddgi_pick_emitter(u.x, emitter_count));
			scene_bvh_triangle tri = bvh_tri(triangle & ~DDGI_EMITTER_DOUBLE_SIDED);
			vec3 to_point = ddgi_emitter_point(tri, u.yz) - origin;
			float dist2 = dot(to_point, to_point);
			// tri.normal points away from the visible side
			float facing = dot(tri.normal, to_point) * inversesqrt(dist2);

			if ((triangle & DDGI_EMITTER_DOUBLE_SIDED) != 0u) facing = abs(facing);

			return max(facing, 0.0) / max(dist2, radius * radius) * uintBitsToFloat(ddgi_grid[0]);
		}

		// An emitter sample seen from origin, by resampled importance sampling: DDGI_EMITTER_CANDIDATES
		// emitters drawn by their power, one kept by the light it would bring at origin. Drawing by
		// power alone gives a probe next to a small emitter a single huge weight (a firefly), this
		// spends the weight on the emitters that matter to the probe. Returns the mean candidate
		// weight, which times the emitter's colour over its luminance is the estimate. emitter is
		// the emitter and, in its top 6 bits, the candidate it came from, the shade pass rebuilds
		// the point from that candidate's random numbers.
		float ddgi_pick_emitter_sample(uint index, uint frame, int emitter_count, vec3 origin, float radius, out int emitter, out vec3 point) {
			float weights[DDGI_EMITTER_CANDIDATES];
			float total = 0.0;

			for (uint k = 0u; k < uint(DDGI_EMITTER_CANDIDATES); k++) {
				weights[k] = ddgi_emitter_candidate_weight(index, frame, k, emitter_count, origin, radius);
				total += weights[k];
			}

			emitter = 0;
			point = origin;

			if (total <= 0.0) return 0.0;

			float pick = ddgi_emitter_random(index, frame ^ 0x5bd1e995u, 0u).x * total;
			uint chosen = uint(DDGI_EMITTER_CANDIDATES) - 1u;
			float running = 0.0;

			for (uint k = 0u; k < uint(DDGI_EMITTER_CANDIDATES); k++) {
				running += weights[k];

				if (pick < running) {
					chosen = k;
					break;
				}
			}

			vec4 u = ddgi_emitter_random(index, frame, chosen);
			int e = ddgi_pick_emitter(u.x, emitter_count);
			point = ddgi_emitter_point(bvh_tri(ddgi_emitter_triangle(e) & ~DDGI_EMITTER_DOUBLE_SIDED), u.yz);
			emitter = int(uint(e) | (chosen << 26u));
			return total / float(DDGI_EMITTER_CANDIDATES);
		}
	]]
end

function ddgi.GetCommonGLSL()
	return ddgi.GetDefinesGLSL() .. ddgi.GetRayDirectionGLSL() .. glsl_common.GetLuminanceGLSL() .. [[
		// atmosphere.lua's ground_fog_sun_transmittance, for the probes, which have no atmosphere code of their own
		float ddgi_ground_fog_sun_transmittance(float altitude, float sun_up, float fog_extinction, float precipitation_extinction) {
			const float scale_height = ]]..string.format("%.17g", atmosphere.GROUND_FOG_SCALE_HEIGHT)..[[;
			const float top = ]]..string.format("%.17g", atmosphere.GROUND_FOG_TOP_HEIGHT)..[[;

			if (altitude >= top) return 1.0;

			altitude = max(altitude, 0.0);
			float optical_depth = fog_extinction * scale_height * (exp(-altitude / scale_height) - exp(-top / scale_height)) + precipitation_extinction * (top - altitude);
			return exp(-optical_depth / max(sun_up, 0.05));
		}

		ivec3 ddgi_volume_base(int c) {
			return ivec3(ddgi_data.ddgi_cascades[c].xyz);
		}

		float ddgi_spacing(int c) {
			return ddgi_data.ddgi_cascades[c].w;
		}

		// probes along each axis
		ivec3 ddgi_volume_size(int c) {
			return ivec3(ddgi_data.ddgi_cascade_size[c].xyz);
		}

		int ddgi_probe_count(int c) {
			ivec3 n = ddgi_volume_size(c);
			return n.x * n.y * n.z;
		}

		ivec3 ddgi_slot(ivec3 world, int c) {
			return DDGI_WRAP(world, ddgi_volume_size(c));
		}

		// index of a slot within its cascade
		int ddgi_probe_index(ivec3 slot, int c) {
			ivec3 n = ddgi_volume_size(c);
			return slot.x + n.x * (slot.y + n.y * slot.z);
		}

		ivec3 ddgi_slot_from_index(int index, int c) {
			ivec3 n = ddgi_volume_size(c);
			return ivec3(index % n.x, (index / n.x) % n.y, index / (n.x * n.y));
		}

		// a ray's texel in the shade pass output: one column block per cascade
		ivec2 ddgi_ray_texel(uint ray, ivec3 slot, int c) {
			return ivec2(int(ray) + DDGI_RAY_STRIDE * c, ddgi_probe_index(slot, c));
		}

		// the probe of this frame's volume that is stored in slot
		ivec3 ddgi_world_from_slot(ivec3 slot, int c) {
			ivec3 base = ddgi_volume_base(c);
			return base + DDGI_WRAP(slot - ddgi_slot(base, c), ddgi_volume_size(c));
		}

		ivec2 ddgi_tile_from_index(int index, int c) {
			return ivec2(index % (DDGI_P * DDGI_P), index / (DDGI_P * DDGI_P) + DDGI_P * c);
		}

		ivec2 ddgi_tile(ivec3 slot, int c) {
			return ddgi_tile_from_index(ddgi_probe_index(slot, c), c);
		}

		// inside the outermost cascade in use
		bool ddgi_in_volume(vec3 P) {
			if (ddgi_data.ddgi_cascade_count == 0) return false;

			int c = ddgi_data.ddgi_cascade_count - 1;
			vec3 grid = P / ddgi_spacing(c) - vec3(ddgi_volume_base(c));
			return all(greaterThanEqual(grid, vec3(0.0))) && all(lessThanEqual(grid, vec3(ddgi_volume_size(c) - 1)));
		}

		float ddgi_pack_direction(vec3 d) {
			const float levels = float((1u << DDGI_DIRECTION_BITS) - 1u);
			uvec2 q = uvec2((oct_encode(d) * 0.5 + 0.5) * levels + 0.5);
			return float(q.x | (q.y << DDGI_DIRECTION_BITS)) - DDGI_DIRECTION_OFFSET;
		}

		vec3 ddgi_unpack_direction(float packed) {
			const uint mask = (1u << DDGI_DIRECTION_BITS) - 1u;
			uint v = uint(packed + DDGI_DIRECTION_OFFSET);
			return oct_decode(vec2(v & mask, v >> DDGI_DIRECTION_BITS) / float(mask) * 2.0 - 1.0);
		}

		// direction of texel (x, y) in a bordered octahedral tile; border texels
		// mirror the interior texel they duplicate so bilinear filtering across
		// an octahedron edge reads the right neighbour
		vec3 ddgi_texel_direction(ivec2 texel, int texels) {
			int last = texels - 1;
			ivec2 src = texel;

			if (texel.y == 0 || texel.y == last) {
				src.x = last - texel.x;
				src.y = texel.y == 0 ? 1 : last - 1;
			}

			if (texel.x == 0 || texel.x == last) {
				src.y = last - src.y;
				src.x = texel.x == 0 ? 1 : last - 1;
			}

			vec2 uv = (vec2(src - 1) + 0.5) / float(texels - 2);
			return oct_decode(uv * 2.0 - 1.0);
		}

		vec2 ddgi_atlas_uv(ivec3 slot, int c, vec3 dir, int texels) {
			vec2 atlas_size = vec2(DDGI_P * DDGI_P * texels, DDGI_P * DDGI_CASCADES * texels);
			vec2 oct = oct_encode(dir) * 0.5 + 0.5;
			vec2 pixel = vec2(ddgi_tile(slot, c) * texels) + 1.0 + oct * float(texels - 2);
			return pixel / atlas_size;
		}

		// xyz = world coordinate last written into the slot plus the probe's
		// relocation offset in spacings (under 0.5, so rounding recovers the
		// coordinate), w = 1 + back face ray fraction (0 when never written)
		vec4 ddgi_probe_data(ivec3 slot, int c) {
			return texelFetch(TEXTURE(ddgi_data.ddgi_probe_data_tex), ddgi_tile(slot, c), 0);
		}

		bool ddgi_probe_is_current(vec4 data, ivec3 world) {
			return data.w >= 1.0 && ivec3(round(data.xyz)) == world;
		}

		// w is 1 + the smoothed fraction of back face hits, plus 2 when the update
		// moved the probe (the rays it was last integrated from started somewhere
		// else), plus 4 when the probe is disabled (inside geometry)
		int ddgi_probe_flags(vec4 data) {
			return int((data.w - 1.0) * 0.5);
		}

		bool ddgi_probe_moved(vec4 data) {
			return (ddgi_probe_flags(data) & 1) != 0;
		}

		bool ddgi_probe_disabled(vec4 data) {
			return (ddgi_probe_flags(data) & 2) != 0;
		}

		float ddgi_probe_backfaces(vec4 data) {
			return data.w - 1.0 - 2.0 * float(ddgi_probe_flags(data));
		}

		// where the probe's rays start; one that just scrolled into its slot
		// sits on its grid point
		vec3 ddgi_probe_origin(ivec3 slot, int c, ivec3 world) {
			vec4 data = ddgi_probe_data(slot, c);
			return (ddgi_probe_is_current(data, world) ? data.xyz : vec3(world)) * ddgi_spacing(c);
		}

		vec3 ddgi_sky(vec3 dir) {
			return textureLod(
				TEXTURE(ddgi_data.ddgi_env_tex),
				dir_to_equirect_uv(correct_environment_lookup_dir(dir)),
				1.0
			).rgb * ddgi_data.ddgi_sky_intensity;
		}

		bool ddgi_cascade_reset(int c) {
			return (ddgi_data.ddgi_reset_mask & (1 << c)) != 0;
		}

		// see ddgi_probe_idle
		bool ddgi_probe_is_idle(ivec3 slot, ivec3 world, int probe, int c) {
			vec4 data = ddgi_probe_data(slot, c);
			return ddgi_probe_idle(data.w, !ddgi_cascade_reset(c) && ddgi_probe_is_current(data, world), probe, c, uint(ddgi_data.ddgi_frame));
		}

		// a probe's ray index, from its tile and whether its guide is usable
		vec3 ddgi_ray(uint index, ivec2 tile, bool guided) {
			return ddgi_ray_direction(index, uint(ddgi_data.ddgi_uniform_rays), ddgi_data.ddgi_rotation, tile, guided);
		}

		float ddgi_ray_q(vec3 d, ivec2 tile, bool guided) {
			return ddgi_ray_weight(d, uint(ddgi_data.ddgi_uniform_rays), tile, guided);
		}

		// a probe's visibility is traced if its weight in the blend is at least visibility_min_weight,
		// or if what it adds to the blend so far is more than DDGI_VISIBILITY_MIN_SHARE of it. A faint
		// probe outside a wall can still be many times brighter than the dark room it leaks into
		#define DDGI_VISIBILITY_MIN_WEIGHT 0.02
		#define DDGI_VISIBILITY_MIN_SHARE 0.02
		#define DDGI_NO_VISIBILITY_RAYS 1e30

		vec4 ddgi_sample_cascade(int c, vec3 P, vec3 N, vec3 L, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			weight = 0.0;

			if (ddgi_cascade_reset(c)) return vec4(0.0);

			float spacing = ddgi_spacing(c);
			vec3 biased = P + (N * ddgi_data.ddgi_normal_bias + V * ddgi_data.ddgi_view_bias) * spacing;
			vec3 grid = biased / spacing;
			int side = smooth_blend ? 3 : 2;
			// the B-spline's lowest probe is one below the nearest
			ivec3 base_world = smooth_blend ? ivec3(floor(grid + 0.5)) - 1 : ivec3(floor(grid));
			vec3 alpha = grid - vec3(base_world) - (smooth_blend ? 1.0 : 0.0);
			vec3 below = 0.5 * (0.5 - alpha) * (0.5 - alpha);
			vec3 middle = 0.75 - alpha * alpha;
			vec3 above = 0.5 * (0.5 + alpha) * (0.5 + alpha);
			ivec3 volume_min = ddgi_volume_base(c);
			ivec3 volume_max = volume_min + ddgi_volume_size(c) - 1;
			vec4 sum = vec4(0.0);
			vec4 hidden_sum = vec4(0.0);
			float hidden_weight = 0.0;

			for (int i = 0; i < side * side * side; i++) {
				ivec3 offset = ivec3(i % side, (i / side) % side, i / (side * side));
				ivec3 world = base_world + offset;

				if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

				ivec3 slot = ddgi_slot(world, c);
				vec4 data = ddgi_probe_data(slot, c);

				if (!ddgi_probe_is_current(data, world) || ddgi_probe_disabled(data)) continue;

				vec3 probe_pos = data.xyz * spacing;
				vec3 kernel = smooth_blend ? mix(mix(below, middle, equal(offset, ivec3(1))), above, equal(offset, ivec3(2))) : mix(1.0 - alpha, alpha, vec3(offset));
				vec3 to_probe = normalize(probe_pos - P);
				float w = (dot(to_probe, N) + 1.0) * 0.5;
				w = w * w + 0.2;

				vec3 probe_to_point = biased - probe_pos;
				float dist = length(probe_to_point);
				vec2 moments = textureLod(
					TEXTURE(ddgi_data.ddgi_distance_tex),
					ddgi_atlas_uv(slot, c, probe_to_point / max(dist, 1e-4), DDGI_DISTANCE_TEXELS),
					0.0
				).rg;
				float chebyshev = 1.0;

				if (dist > moments.x) {
					float variance = abs(moments.x * moments.x - moments.y);
					float d = dist - moments.x;
					chebyshev = variance / (variance + d * d);
					chebyshev = chebyshev * chebyshev * chebyshev;
				}

				w *= max(0.05, chebyshev);
				w = max(1e-6, w);

				// crush tiny weights so a barely visible probe cannot tint the result
				if (w < 0.2) w *= w * w / 0.04;

				w *= kernel.x * kernel.y * kernel.z;

				vec4 irradiance = textureLod(
					TEXTURE(ddgi_data.ddgi_irradiance_tex),
					ddgi_atlas_uv(slot, c, L, DDGI_IRRADIANCE_TEXELS),
					0.0
				);
				bool hidden = false;

				#ifdef DDGI_VISIBILITY_RAYS
				if (visibility_min_weight < DDGI_NO_VISIBILITY_RAYS && (w >= visibility_min_weight || w * luminance(irradiance.rgb) > DDGI_VISIBILITY_MIN_SHARE * luminance(sum.rgb)) && ddgi_data.ddgi_rt_ready != 0 && (ddgi_data.ddgi_visibility_rays == 2 || ddgi_data.ddgi_visibility_rays == 1 && data.xyz != vec3(world))) {
					vec3 origin = P + N * (0.02 * spacing);
					vec3 to_probe_ray = probe_pos - origin;
					float len = length(to_probe_ray);

					// a ray query with a nan or zero direction is undefined
					if (!(len > 1e-4)) continue;

					rayQueryEXT query;
					rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | (ddgi_data.ddgi_visibility_front_faces_only != 0 ? gl_RayFlagsCullBackFacingTrianglesEXT : 0u), DDGI_VISIBILITY_MASK, origin, 0.0, to_probe_ray / len, len);

					while (rayQueryProceedEXT(query)) {}

					hidden = rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
				}
				#endif

				if (hidden) {
					hidden_sum += irradiance * w;
					hidden_weight += w;
				} else {
					sum += irradiance * w;
					weight += w;
				}
			}

			float fallback = 1.0 - smoothstep(0.0, 0.025, weight);
			sum += hidden_sum * fallback;
			weight += hidden_weight * fallback;

			// When every probe is all but hidden (a point inside geometry, or
			// on an edge where the reconstructed position slips behind a wall)
			// dividing by the tiny total would blow up whichever hidden probe
			// is least hidden, often one outside. Such points fade out instead.
			return sum / max(weight, ]] .. MIN_WEIGHT .. [[);
		}

		// 1 deep inside cascade c, falling to 0 a cell (the B-spline reaches
		// half a cell further) before its edge where the biased lookup would
		// start missing probes. An edge past the end of
		// the scene has nothing beyond it, so it does not fade.
		float ddgi_cascade_blend(int c, vec3 P, bool smooth_blend) {
			vec3 grid = P / ddgi_spacing(c) - vec3(ddgi_volume_base(c));
			vec3 edge = min(grid, vec3(ddgi_volume_size(c) - 1) - grid);
			int holds = int(ddgi_data.ddgi_cascade_size[c].w);

			if ((holds & 1) != 0) edge.x = 1e9;

			if ((holds & 2) != 0) edge.y = 1e9;

			if ((holds & 4) != 0) edge.z = 1e9;

			return clamp((min(edge.x, min(edge.y, edge.z)) - (smooth_blend ? 1.5 : 1.0)) / ddgi_data.ddgi_cascade_blend, 0.0, 1.0);
		}

		// Irradiance at P with normal N, seen from direction V (towards the
		// viewer), looked up along L, which is N unless something knows the
		// open side to be elsewhere. rgb = irradiance, a = sky visibility.
		// weight is 0 when no probe could contribute.
		vec4 ddgi_sample_irradiance_unscaled(vec3 P, vec3 N, vec3 L, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			weight = 0.0;

			int count = ddgi_data.ddgi_cascade_count;

			for (int c = 0; c < count; c++) {
				float fine = c == count - 1 ? 1.0 : ddgi_cascade_blend(c, P, smooth_blend);

				if (fine <= 0.0) continue;

				vec4 result = ddgi_sample_cascade(c, P, N, L, V, smooth_blend, visibility_min_weight, weight);

				if (c == count - 1) return result;

				float keep = fine;

				// A cascade whose probes barely see the point (disabled, hidden, or
				// not yet written) hands over to the next one like its edge does.
				// That is only safe with the visibility rays, the coarser probes
				// are further apart and leak through thin walls without them.
				#ifdef DDGI_VISIBILITY_RAYS
				if (visibility_min_weight < DDGI_NO_VISIBILITY_RAYS) keep *= smoothstep(0.0, ]] .. MIN_WEIGHT .. [[, weight);
				#endif

				if (keep >= 1.0) return result;

				float coarse_weight;
				vec4 coarse = ddgi_sample_cascade(c + 1, P, N, L, V, smooth_blend, visibility_min_weight, coarse_weight);

				// fitted cascades are not always nested
				if (coarse_weight <= 0.0) return result;

				weight = mix(coarse_weight, weight, keep);
				return mix(coarse, result, keep);
			}

			return vec4(0.0);
		}

		// the probes' own bounces (the shade pass defines DDGI_UNSCALED) are not scaled, that would compound
		vec4 ddgi_sample_irradiance(vec3 P, vec3 N, vec3 L, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			vec4 result = ddgi_sample_irradiance_unscaled(P, N, L, V, smooth_blend, visibility_min_weight, weight);
			#ifndef DDGI_UNSCALED
			result.rgb *= ddgi_data.ddgi_strength;
			#endif
			return result;
		}
	]]
end

function ddgi.GetProbeBlockLayout()
	return {
		{"ddgi_cascades", "vec4", ddgi.CASCADES},
		{"ddgi_cascade_size", "vec4", ddgi.CASCADES},
		{"ddgi_rotation", "vec4"},
		{"ddgi_sun_direction", "vec4"},
		{"ddgi_sun_radiance", "vec4"},
		-- x the ground fog's extinction per km at the ground, y the precipitation's
		{"ddgi_ground_fog", "vec4"},
		{"ddgi_max_distance", "float"},
		{"ddgi_cascade_update", "vec4", ddgi.CASCADES},
		{"ddgi_ray_clamp", "float"},
		{"ddgi_distance_exponent", "float"},
		{"ddgi_normal_bias", "float"},
		{"ddgi_view_bias", "float"},
		{"ddgi_backface_threshold", "float"},
		{"ddgi_relocation_distance", "float"},
		{"ddgi_max_offset", "float"},
		{"ddgi_sky_intensity", "float"},
		{"ddgi_strength", "float"},
		{"ddgi_light_radius", "float"},
		{"ddgi_cascade_blend", "float"},
		{"ddgi_debug_scale", "float"},
		{"ddgi_debug_probes", "int"},
		{"ddgi_debug_cascade", "int"},
		{"ddgi_debug_scene", "int"},
		{"ddgi_debug_manual_gamma", "int"},
		{"ddgi_smooth_blend", "int"},
		{"ddgi_visibility_rays", "int"},
		{"ddgi_visibility_front_faces_only", "int"},
		{"ddgi_cascade_count", "int"},
		{"ddgi_reset_mask", "int"},
		{"ddgi_update_mask", "int"},
		{"ddgi_rt_ready", "int"},
		{"ddgi_env_tex", "int"},
		{"ddgi_env_irradiance_tex", "int"},
		{"ddgi_ray_tex", "int"},
		{"ddgi_irradiance_tex", "int"},
		{"ddgi_distance_tex", "int"},
		{"ddgi_probe_data_tex", "int"},
		{"ddgi_emitter_count", "int"},
		{"ddgi_frame", "int"},
		{"ddgi_uniform_rays", "int"},
		{"ddgi_guide_tex", "int"},
		{"ddgi_bent_normal_tex", "int"},
	}
end

function ddgi.GetBlockLayout()
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		clouds.GetShadowBlockLayout(),
	}
	table.add(layout, ddgi.GetProbeBlockLayout())
	table.add(layout, post_source.pre_exposure_block)
	layout[#layout + 1] = {"glass_light", "int"}
	return layout
end

local function pipeline_texture_index(self, name)
	local pipeline = render3d.pipelines[name]
	return pipeline and
		self:GetTextureIndex(pipeline:GetFramebuffer(1):GetAttachment(1)) or
		-1
end

function ddgi.WriteProbeBlock(self, block)
	local state = ddgi.GetFrameState()
	local lights = render3d.GetLights()
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, sun_direction.y)
	sun_direction:CopyToFloatPointer(block.ddgi_sun_direction)
	block.ddgi_sun_direction[3] = 0
	block.ddgi_sun_radiance[0] = sun_color.x * sun_illuminance
	block.ddgi_sun_radiance[1] = sun_color.y * sun_illuminance
	block.ddgi_sun_radiance[2] = sun_color.z * sun_illuminance
	block.ddgi_sun_radiance[3] = 0
	block.ddgi_ground_fog[0] = atmosphere.GetGroundFogExtinction()
	block.ddgi_ground_fog[1] = atmosphere.precipitation_extinction

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		block.ddgi_cascades[c - 1][0] = cascade.x
		block.ddgi_cascades[c - 1][1] = cascade.y
		block.ddgi_cascades[c - 1][2] = cascade.z
		block.ddgi_cascades[c - 1][3] = cascade.spacing
		block.ddgi_cascade_size[c - 1][0] = cascade.size.x
		block.ddgi_cascade_size[c - 1][1] = cascade.size.y
		block.ddgi_cascade_size[c - 1][2] = cascade.size.z
		block.ddgi_cascade_size[c - 1][3] = cascade.holds
	end

	block.ddgi_rotation[0] = state.rotation.x
	block.ddgi_rotation[1] = state.rotation.y
	block.ddgi_rotation[2] = state.rotation.z
	block.ddgi_rotation[3] = state.rotation.w
	block.ddgi_max_distance = max_ray_distance:Get()

	for c = 1, ddgi.CASCADES do
		block.ddgi_cascade_update[c - 1][0] = hysteresis:Get() ^ (math.min(state.cascades[c].update_time, 0.1 * ddgi.GetUpdateInterval(c)) * 60)
		block.ddgi_cascade_update[c - 1][1] = (state.sun_fast_until or 0) > state.frame and 1 or 0
	end

	block.ddgi_ray_clamp = ray_clamp:Get()
	block.ddgi_distance_exponent = ddgi.DISTANCE_EXPONENT
	block.ddgi_normal_bias = ddgi.NORMAL_BIAS
	block.ddgi_view_bias = ddgi.VIEW_BIAS
	block.ddgi_backface_threshold = ddgi.BACKFACE_THRESHOLD
	block.ddgi_relocation_distance = relocation:Get() and ddgi.RELOCATION_DISTANCE or 0
	block.ddgi_max_offset = relocation:Get() and ddgi.PROBE_MAX_OFFSET or 0
	block.ddgi_sky_intensity = ddgi.SKY_INTENSITY
	block.ddgi_strength = strength:Get()
	block.ddgi_light_radius = light_radius:Get()
	block.ddgi_cascade_blend = ddgi.CASCADE_BLEND
	block.ddgi_debug_scale = debug_scale:Get()
	block.ddgi_debug_probes = DEBUG_PROBES[debug_probes:Get()]
	block.ddgi_debug_cascade = debug_cascade:Get()
	block.ddgi_debug_scene = DEBUG_SCENE[debug_scene:Get()]
	block.ddgi_debug_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
	block.ddgi_smooth_blend = smooth_blend:Get() and 1 or 0
	block.ddgi_visibility_rays = VISIBILITY_RAYS[visibility_rays:Get()]
	block.ddgi_visibility_front_faces_only = visibility_front_faces_only:Get() and 1 or 0
	block.ddgi_cascade_count = state.cascade_count
	block.ddgi_reset_mask = state.reset_mask
	block.ddgi_update_mask = state.update_mask
	block.ddgi_rt_ready = state.rt_ready and 1 or 0
	block.ddgi_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.ddgi_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.ddgi_ray_tex = pipeline_texture_index(self, "ddgi_shade")
	block.ddgi_irradiance_tex = pipeline_texture_index(self, "ddgi_irradiance")
	block.ddgi_distance_tex = pipeline_texture_index(self, "ddgi_distance")
	block.ddgi_probe_data_tex = pipeline_texture_index(self, "ddgi_probe_data")
	local emitters = ddgi.GetEmitters()
	block.ddgi_emitter_count = emitters_enabled:Get() and emitters.count or 0
	block.ddgi_frame = state.frame
	block.ddgi_uniform_rays = ddgi.GetUniformRays()
	block.ddgi_guide_tex = pipeline_texture_index(self, "ddgi_guide")
	local bent_normal = ambient_occlusion.GetBentNormalTexture()
	block.ddgi_bent_normal_tex = bent_normal and self:GetTextureIndex(bent_normal) or -1
	return block
end

function ddgi.WriteBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	gbuffer_layout.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	clouds.WriteShadowBlock(self, block)
	post_source.WritePreExposureBlock(self, block)
	block.glass_light = ddgi.HasGlass() and 1 or 0
	return ddgi.WriteProbeBlock(self, block)
end

local ray_hit_buffer = nil

function ddgi.GetRayHitBuffer()
	if not ray_hit_buffer then
		ray_hit_buffer = render.CreateBuffer{
			byte_size = ddgi.GetRayCount() * 8,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "device_local"},
			label = "ddgi_ray_hits",
		}
	end

	return ray_hit_buffer
end

do
	local HEADER_WORDS = 2
	local EMITTER_WORDS = 3
	local WordArray = ffi.typeof("uint32_t[?]")
	local Floats = ffi.typeof("float*")
	local emitters = {
		words = WordArray(1),
		word_capacity = 1,
		word_count = 0,
		count = 0,
		weight = 0,
		version = 0,
		emitter_version = -1,
		additive = false,
		excluded_count = 0,
		excluded_power = 0,
	}
	local buffers = {}
	local buffer_versions = {}

	function ddgi.GetEmitters()
		local additive = additive_emitters:Get()

		if emitters.emitter_version == scene_bvh.emitter_version and emitters.additive == additive then
			return emitters
		end

		local total_count = 0

		for _, block in ipairs(scene_bvh.emissive_blocks) do
			total_count = total_count + block.emitter_count
		end

		local word_count = HEADER_WORDS + total_count * EMITTER_WORDS

		if emitters.word_capacity < word_count then
			emitters.words = WordArray(word_count * 2)
			emitters.word_capacity = word_count * 2
		end

		local words = emitters.words
		ffi.fill(words, word_count * 4)
		local floats = ffi.cast(Floats, words)
		local count, weight = 0, 0
		local excluded_count, excluded_power = 0, 0

		for _, block in ipairs(scene_bvh.emissive_blocks) do
			local block_emitters = block.emitters
			local tri_base = block.tri_base

			for j = 0, block.emitter_count - 1 do
				local emitter = block_emitters[j]
				local power = emitter.power

				if emitter.additive ~= 0 and not additive then
					excluded_count = excluded_count + 1
					excluded_power = excluded_power + power
				elseif power > 0 then
					weight = weight + power
					local g = HEADER_WORDS + count * EMITTER_WORDS
					words[g] = emitter.triangle + tri_base
					floats[g + 1] = weight
					floats[g + 2] = power
					count = count + 1
				end
			end
		end

		for i = 0, count - 1 do
			floats[HEADER_WORDS + i * EMITTER_WORDS + 1] = floats[HEADER_WORDS + i * EMITTER_WORDS + 1] / weight
		end

		if count > 0 then floats[HEADER_WORDS + (count - 1) * EMITTER_WORDS + 1] = 1 end

		floats[0] = weight
		words[1] = count
		emitters.word_count = word_count
		emitters.count = count
		emitters.weight = weight
		emitters.additive = additive
		emitters.excluded_count = excluded_count
		emitters.excluded_power = excluded_power
		emitters.emitter_version = scene_bvh.emitter_version
		emitters.version = emitters.version + 1
		return emitters
	end

	function ddgi.GetEmitterBuffer()
		local emitters = ddgi.GetEmitters()
		local frame = render.GetCurrentFrame()
		local buffer = buffers[frame]
		local bytes = emitters.word_count * 4

		if not buffer or buffer:GetSize() < bytes then
			if buffer then buffer:Remove() end

			buffer = render.CreateBuffer{
				byte_size = bytes * 2,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_emitters",
				data = WordArray(emitters.word_count * 2),
			}
			buffers[frame] = buffer
			buffer_versions[frame] = nil
		end

		if buffer_versions[frame] ~= emitters.version then
			buffer:CopyData(emitters.words, bytes)
			buffer_versions[frame] = emitters.version
		end

		return buffer
	end
end

local MaterialEntry = ffi.typeof([[struct {
	float albedo[3];
	int32_t albedo_tex;
	int32_t double_sided;
	int32_t terrain_tex;
	int32_t terrain_layer_tex[4];
	float terrain_bounds[3];
	float terrain_detail[4];
	float terrain_additive_detail[4];
	int32_t terrain_tex2;
	int32_t terrain_layer_tex2[4];
	float terrain_detail2[4];
	float terrain_additive_detail2[4];
	float alpha;
	float alpha_cutoff;
	int32_t alpha_test;
	int32_t glass;
	int32_t albedo2_tex;
	int32_t blend_tex;
	int32_t transparent;
	int32_t refractive;
	float glass_refraction;
	float glass_covering;
	float metallic;
	int32_t metallic_tex;
	int32_t metallic_channel;
	float roughness;
	float roughness_min;
	float roughness_max;
	int32_t roughness_tex;
	int32_t roughness_channel;
	}]])
ddgi.MaterialEntry = MaterialEntry
local MaterialEntryArray = ffi.typeof("$[?]", MaterialEntry)
local MaterialEntryPointer = ffi.typeof("$*", MaterialEntry)
local MATERIAL_ENTRY_SIZE = ffi.sizeof(MaterialEntry)
local material_buffers = setmetatable({}, {__mode = "k"})
local glass_count = 0

function ddgi.HasGlass()
	return glass_count > 0
end

function ddgi.WriteMaterialBuffer(self)
	local frame = render.GetCurrentFrame()
	local materials = scene_bvh.materials
	local count = #materials
	material_buffers[self] = material_buffers[self] or {}
	local states = material_buffers[self]
	local state = states[frame]

	if not state or state.buffer:GetSize() < count * MATERIAL_ENTRY_SIZE then
		if state then state.buffer:Remove() end

		local capacity = math.max(count, 1) * 2
		state = {
			buffer = render.CreateBuffer{
				byte_size = capacity * MATERIAL_ENTRY_SIZE,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_materials",
				data = MaterialEntryArray(capacity),
			},
			written = 0,
			generation = 0,
			releases = -1,
		}
		states[frame] = state
	end

	local generation = Material.ray_material_generation
	local releases = self:GetTextureIndexReleases()
	local glass_enabled = not Material.GlassCastsShadow()

	if
		state.written == count and
		state.generation == generation and
		state.releases == releases and
		state.glass == glass_enabled
	then
		glass_count = state.glass_count or 0
		return state.buffer
	end

	local rewrite_all = state.releases ~= releases or state.glass ~= glass_enabled
	local written = state.written
	local stamp = state.generation
	local out = ffi.cast(MaterialEntryPointer, state.buffer:Map(0, state.buffer:GetSize()))

	for i = 1, count do
		local material = materials[i]

		if rewrite_all or i > written or material.ray_material_stamp > stamp then
			local entry = out[i - 1]
			local color = material:GetColorMultiplier()
			entry.albedo[0] = color.r
			entry.albedo[1] = color.g
			entry.albedo[2] = color.b
			local albedo = material:GetAlbedoTexture() or NULL
			entry.albedo_tex = albedo:IsValid() and self:GetTextureIndex(albedo) or -1
			entry.double_sided = material:GetDoubleSided() and 1 or 0
			entry.alpha = color.a
			entry.alpha_cutoff = material:GetAlphaCutoff()

			if not material:GetAlphaTest() then
				entry.alpha_test = 0
			else
				entry.alpha_test = material:HasShadowTexture() and 2 or 1
			end

			local was_glass = entry.glass
			entry.glass = (glass_enabled and material:IsGlass()) and 1 or 0
			state.glass_count = (state.glass_count or 0) + entry.glass - was_glass
			entry.glass_refraction = material:GetRefraction()
			entry.glass_covering = material:GetTranslucent() and color.a or 1
			entry.metallic = material:GetMetallicMultiplier()
			local metallic_texture = material:GetMetallicTexture()
			entry.metallic_channel = 0

			if not metallic_texture then
				metallic_texture = material:GetMetallicRoughnessTexture()
				entry.metallic_channel = 2
			end

			entry.metallic_tex = metallic_texture and
				metallic_texture:IsValid() and
				self:GetTextureIndex(metallic_texture) or
				-1
			entry.roughness = material:GetRoughnessMultiplier()
			entry.roughness_min = material:GetRoughnessMin()
			entry.roughness_max = material:GetRoughnessMax()
			local roughness_texture = material:GetRoughnessTexture()
			entry.roughness_channel = 0

			if not roughness_texture then
				roughness_texture = material:GetMetallicRoughnessTexture()
				entry.roughness_channel = 1
			end

			entry.roughness_tex = roughness_texture and
				roughness_texture:IsValid() and
				self:GetTextureIndex(roughness_texture) or
				-1
			entry.transparent = material:IsTransparent() and 1 or 0
			entry.refractive = material:IsSeeThrough() and 1 or 0
			local albedo2 = material:GetAlbedo2Texture()
			entry.albedo2_tex = albedo2 and albedo2:IsValid() and self:GetTextureIndex(albedo2) or -1
			local blend_texture = material:GetBlendTexture()
			entry.blend_tex = blend_texture and
				blend_texture:IsValid() and
				self:GetTextureIndex(blend_texture) or
				-1
			local terrain = material:GetTerrainMaterialTexture()

			if terrain and terrain:IsValid() then
				entry.terrain_tex = self:GetTextureIndex(terrain)

				for layer = 1, 4 do
					local tex = material["GetTerrainLayer" .. layer .. "Texture"](material)
					entry.terrain_layer_tex[layer - 1] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
				end

				local bounds = material:GetTerrainBounds()
				entry.terrain_bounds[0] = bounds.x
				entry.terrain_bounds[1] = bounds.y
				entry.terrain_bounds[2] = 1 / bounds.z
				local detail = material:GetTerrainLayerDetailStrength()
				local additive = material:GetTerrainLayerAdditiveDetail()
				entry.terrain_detail[0] = detail.r
				entry.terrain_detail[1] = detail.g
				entry.terrain_detail[2] = detail.b
				entry.terrain_detail[3] = detail.a
				entry.terrain_additive_detail[0] = additive.r
				entry.terrain_additive_detail[1] = additive.g
				entry.terrain_additive_detail[2] = additive.b
				entry.terrain_additive_detail[3] = additive.a
				local terrain2 = material:GetTerrainMaterial2Texture()

				if terrain2 and terrain2:IsValid() then
					entry.terrain_tex2 = self:GetTextureIndex(terrain2)

					for layer = 5, 8 do
						local tex = material["GetTerrainLayer" .. layer .. "Texture"](material)
						entry.terrain_layer_tex2[layer - 5] = tex and tex:IsValid() and self:GetTextureIndex(tex) or -1
					end

					local detail2 = material:GetTerrainLayerDetailStrength2()
					local additive2 = material:GetTerrainLayerAdditiveDetail2()
					entry.terrain_detail2[0] = detail2.r
					entry.terrain_detail2[1] = detail2.g
					entry.terrain_detail2[2] = detail2.b
					entry.terrain_detail2[3] = detail2.a
					entry.terrain_additive_detail2[0] = additive2.r
					entry.terrain_additive_detail2[1] = additive2.g
					entry.terrain_additive_detail2[2] = additive2.b
					entry.terrain_additive_detail2[3] = additive2.a
				else
					entry.terrain_tex2 = -1
				end
			else
				entry.terrain_tex = -1
				entry.terrain_tex2 = -1
			end
		end
	end

	state.written = count
	state.generation = generation
	state.releases = releases
	state.glass = glass_enabled
	glass_count = state.glass_count or 0
	return state.buffer
end

local RTParams = ffi.typeof(
	(
		[[struct {
	float cascades[%d][4];
	float size[%d][4];
	float rotation[4];
	float sun_direction[4];
	float max_ray_distance;
	float tmin;
	int32_t emitter_count;
	uint32_t frame;
	float light_radius;
	int32_t update_mask;
	int32_t uniform_rays;
	int32_t reset_mask;
}]]
	):format(ddgi.CASCADES, ddgi.CASCADES)
)
local RTParamsPointer = ffi.typeof("$*", RTParams)
local rt_params = {}

function ddgi.WriteRTParams()
	local frame = render.GetCurrentFrame()
	local buffer = rt_params[frame]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = ffi.sizeof(RTParams),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "ddgi_rt_params",
			data = RTParams(),
		}
		rt_params[frame] = buffer
	end

	local state = ddgi.GetFrameState()
	local p = ffi.cast(RTParamsPointer, buffer:Map(0, ffi.sizeof(RTParams)))

	for c = 1, ddgi.CASCADES do
		local cascade = state.cascades[c]
		p.cascades[c - 1][0] = cascade.x
		p.cascades[c - 1][1] = cascade.y
		p.cascades[c - 1][2] = cascade.z
		p.cascades[c - 1][3] = cascade.spacing
		p.size[c - 1][0] = cascade.size.x
		p.size[c - 1][1] = cascade.size.y
		p.size[c - 1][2] = cascade.size.z
	end

	p.rotation[0] = state.rotation.x
	p.rotation[1] = state.rotation.y
	p.rotation[2] = state.rotation.z
	p.rotation[3] = state.rotation.w
	local lights = render3d.GetLights()
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	p.sun_direction[0] = sun_direction.x
	p.sun_direction[1] = sun_direction.y
	p.sun_direction[2] = sun_direction.z
	p.sun_direction[3] = directional_shadows.GetPrimarySunIlluminance(lights) > 0 and 1 or 0
	p.max_ray_distance = max_ray_distance:Get()
	p.tmin = 0.0
	p.emitter_count = emitters_enabled:Get() and ddgi.GetEmitters().count or 0
	p.frame = state.frame
	p.light_radius = light_radius:Get()
	p.update_mask = state.update_mask
	p.uniform_rays = ddgi.GetUniformRays()
	p.reset_mask = state.reset_mask
	return buffer
end

local payload_glsl = [[
struct Payload
{
    float hit_t;
    uint primitive;
    // 1 for the sun's shadow ray, which passes through glass (see ddgi_material.glass)
    uint sun;
};
]]
ddgi.SCENE_FLAGS_GLSL = ddgi.ALPHA_TEST and
	"#define DDGI_SCENE_FLAGS 0u\n" or
	"#define DDGI_SCENE_FLAGS gl_RayFlagsOpaqueEXT\n"
local raygen_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
]] .. ddgi.SCENE_FLAGS_GLSL .. ddgi.GetDefinesGLSL() .. [[
// see ddgi_guide_texel
layout(set = 0, binding = 4) uniform sampler2D guide;
#define DDGI_GUIDE_FETCH(texel) texelFetch(guide, texel, 0)
]] .. ddgi.GetRayDirectionGLSL() .. payload_glsl .. scene_bvh.GetDeclarationsGLSL(7, 5) .. ddgi.GetEmitterDeclarationsGLSL(6) .. ddgi.GetEmitterGLSL() .. [[
layout(set = 0, binding = 0) uniform Params
{
    // see ddgi_cascades and ddgi_cascade_size
    vec4 cascades[DDGI_CASCADES];
    vec4 size[DDGI_CASCADES];
    vec4 rotation;
    vec4 sun_direction;
    float max_ray_distance;
    float tmin;
    int emitter_count;
    uint frame;
    // in spacings, see ddgi_light_radius
    float light_radius;
    // bit c: cascade c traces this frame
    int update_mask;
    // rays of a probe that are not aimed by its guide
    int uniform_rays;
    // bit c: cascade c starts over
    int reset_mask;
} params;
layout(set = 0, binding = 1) writeonly buffer Hits
{
    uvec2 hits[];
};
layout(set = 0, binding = 2) uniform accelerationStructureEXT scene;
// see ddgi_probe_data
layout(set = 0, binding = 3) uniform sampler2D probe_data;
layout(location = 0) rayPayloadEXT Payload payload;

void main()
{
    uint ray = gl_LaunchIDEXT.x;
    int probe = int(gl_LaunchIDEXT.y);
    int c = int(gl_LaunchIDEXT.z);

    if ((params.update_mask & (1 << c)) == 0) return;

    ivec3 n = ivec3(params.size[c].xyz);

    if (probe >= n.x * n.y * n.z) return;

    ivec3 base = ivec3(params.cascades[c].xyz);
    ivec3 slot = ivec3(probe % n.x, (probe / n.x) % n.y, probe / (n.x * n.y));
    ivec3 world = base + DDGI_WRAP(slot - DDGI_WRAP(base, n), n);
    ivec2 tile = ivec2(probe % (DDGI_P * DDGI_P), probe / (DDGI_P * DDGI_P) + DDGI_P * c);
    vec4 data = texelFetch(probe_data, tile, 0);
    bool current = data.w >= 1.0 && ivec3(round(data.xyz)) == world;

    if (ddgi_probe_idle(data.w, current && (params.reset_mask & (1 << c)) == 0, probe, c, params.frame)) return;

    vec3 origin = (current ? data.xyz : vec3(world)) * params.cascades[c].w;
    uint index = uint(probe + DDGI_P * DDGI_P * DDGI_P * c) * uint(DDGI_RAY_STRIDE) + ray;
    const uint shadow_flags = DDGI_SCENE_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT;

    // An emitter sample (see ddgi_pick_emitter_sample). Stores its weight and the
    // emitter, or a negative weight when it is blocked.
    if (ray >= DDGI_RAYS) {
        uvec2 result = uvec2(floatBitsToUint(-1.0), 0u);

        if (params.emitter_count > 0) {
            int emitter;
            vec3 point;
            float weight = ddgi_pick_emitter_sample(index, params.frame, params.emitter_count, origin, params.light_radius * params.cascades[c].w, emitter, point);
            vec3 to_point = point - origin;
            float dist = length(to_point);

            if (weight > 0.0 && dist > DDGI_SHADOW_OFFSET) {
                payload.hit_t = 1.0;
                payload.sun = 0u;
                traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, origin, 0.0, to_point / dist, dist - DDGI_SHADOW_OFFSET, 0);

                if (payload.hit_t < 0.0) result = uvec2(floatBitsToUint(weight), uint(emitter));
            }
        }

        hits[index] = result;
        return;
    }

    vec3 dir = ddgi_ray_direction(ray, uint(params.uniform_rays), params.rotation, tile, ddgi_guide_valid(tile, world, c));
    payload.sun = 0u;
    traceRayEXT(scene, DDGI_SCENE_FLAGS, 0xFF, 0, 0, 0, origin, params.tmin, dir, params.max_ray_distance, 0);
    float hit_t = payload.hit_t;
    uint primitive = payload.primitive;

    // The sun's visibility from the hit, exact rather than from shadow maps
    // that only cover the view. The local lights get theirs in the shade pass
    // (see ddgi_direct_light). The shadow rays skip the closest hit shader, so
    // only a miss changes the payload.
    if (hit_t >= 0.0 && params.sun_direction.w > 0.0) {
        // the shade pass' normal, flipped to face the ray (a back face of a single sided material is discarded there anyway)
        vec3 hit_normal = -bvh_tri(primitive).normal;

        if (dot(dir, hit_normal) > 0.0) hit_normal = -hit_normal;

        vec3 sun_direction = normalize(params.sun_direction.xyz);

        // a surface facing away from the sun gets no direct light, so no ray
        if (dot(hit_normal, sun_direction) > 0.0) {
            payload.hit_t = 1.0;
            payload.sun = 1u;
            traceRayEXT(scene, shadow_flags, 0xFF, 0, 0, 0, origin + dir * hit_t + hit_normal * DDGI_SHADOW_OFFSET, 0.0, sun_direction, params.max_ray_distance, 0);

            if (payload.hit_t < 0.0) primitive |= DDGI_SUN_VISIBLE_BIT;
        }
    }

    hits[index] = uvec2(floatBitsToUint(hit_t), primitive);
}
]]
local closesthit_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = gl_HitTEXT;
    // one instance per visual, its custom index is the visual's soup range start
    payload.primitive = uint(gl_InstanceCustomIndexEXT) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(gl_PrimitiveID);
}
]]

local function build_anyhit_glsl()
	return [[
#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 1, binding = 0) uniform sampler2D textures[]] .. render.GetBindlessDescriptorCapacities().textures .. [[];
#define TEXTURE(idx) textures[nonuniformEXT(idx)]
hitAttributeEXT vec2 barycentrics;
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;
]] .. scene_bvh.GetTriangleDeclarationGLSL(5) .. scene_bvh.GetUvDeclarationGLSL(8) .. ddgi.GetMaterialDeclarationsGLSL(9) .. ddgi.GetAlphaTestGLSL() .. [[

void main()
{
    // one instance per visual, its custom index is the visual's soup range start
    uint triangle = uint(gl_InstanceCustomIndexEXT) * ]] .. scene_bvh.SOUP_ALIGN .. [[u + uint(gl_PrimitiveID);

    // the sun's light goes on through glass, tinted by the lookup in the shade pass
    if (payload.sun != 0u && ddgi_materials[bvh_tri(triangle).material].glass != 0) ignoreIntersectionEXT;

    // probe and emitter rays see what is behind refractive surfaces
    if (payload.sun == 0u && ddgi_materials[bvh_tri(triangle).material].refractive != 0) ignoreIntersectionEXT;

    if (!ddgi_alpha_passes(triangle, barycentrics)) ignoreIntersectionEXT;
}
]]
end

local miss_glsl = [[
#version 460
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = -1.0;
    payload.primitive = 0u;
}
]]
local rt_pipeline = nil

function ddgi.GetRTPipeline()
	if not rt_pipeline then
		local RayTracingPipeline = import("goluwa/render/vulkan/ray_tracing_pipeline.lua")
		local stages = {
			{name = "raygeneration", code = raygen_glsl},
			{name = "closesthit", code = closesthit_glsl},
			{name = "miss", code = miss_glsl},
		}
		local bindings = {
			{binding_index = 0, type = "uniform_buffer", stageFlags = "all"},
			{binding_index = 1, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 2, type = "acceleration_structure_khr", stageFlags = "all"},
			{binding_index = 3, type = "combined_image_sampler", stageFlags = "all"},
			{binding_index = 4, type = "combined_image_sampler", stageFlags = "all"},
			{
				binding_index = 5,
				type = "storage_buffer",
				stageFlags = "all",
				count = scene_bvh.SOUP_CHUNKS,
			},
			{binding_index = 6, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 7, type = "storage_buffer", stageFlags = "all"},
		}

		if ddgi.ALPHA_TEST then
			stages[#stages + 1] = {name = "anyhit", code = build_anyhit_glsl()}
			bindings[#bindings + 1] = {
				binding_index = 8,
				type = "storage_buffer",
				stageFlags = "all",
				count = scene_bvh.SOUP_CHUNKS,
			}
			bindings[#bindings + 1] = {binding_index = 9, type = "storage_buffer", stageFlags = "all"}
		end

		rt_pipeline = RayTracingPipeline.New(
			render.GetDevice(),
			{
				stages = stages,
				bindless = ddgi.ALPHA_TEST,
				max_recursion_depth = 1,
				max_ray_payload_size = 12,
				DescriptorSetCount = render.GetSwapchainImageCount() * 16,
				descriptor_sets = {bindings},
			}
		)
	end

	return rt_pipeline
end

return ddgi
