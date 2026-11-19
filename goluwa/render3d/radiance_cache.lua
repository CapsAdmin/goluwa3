local ffi = require("ffi")
local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
local pvars = import("goluwa/cli/pvars.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local scene_materials = import("goluwa/render3d/scene/materials.lua")
local scene_bridge = import("goluwa/render3d/scene/bridge.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local scene_hit = import("goluwa/render3d/scene/hit.lua")
local glsl_metadata = import("goluwa/render/glsl_metadata.lua")
local Material = import("goluwa/render3d/material.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local media = import("goluwa/render3d/media.lua")
local water = import("goluwa/render3d/water.lua")
local radiance_cache = {}
pvars.StartGroup("Lighting", "DDGI", {store = false, prefix = "radiance_cache_"})

event.AddListener("Render3DPassToggled", "radiance_cache", function(name, value)
	if name == "radiance_cache" and value then radiance_cache.ResetHistory() end
end)

radiance_cache.PROBES_PER_AXIS = 24
local probe_spacing = pvars.Setup2{
	key = "radiance_cache_probe_spacing",
	default = 0.5,
	min = 0.1,
	help = "meters between the finest cascade's probes",
}
local cascade_ratio = pvars.Setup2{
	key = "radiance_cache_cascade_ratio",
	default = 2,
	min = 1.25,
	max = 8,
	help = "how many times further apart the probes of each cascade are than those of the one before, the coarsest is that ratio cubed times the spacing of the finest. a lower ratio keeps probes fine for longer but the cascades together reach less far",
}
radiance_cache.CASCADES = 10
radiance_cache.CASCADE_BLEND = 2.0
local update_interval_min = pvars.Setup2{
	key = "radiance_cache_update_interval_min",
	default = 4,
	integer = true,
	min = 1,
	max = 64,
	help = "frames between updates of the finest cascade. the cascades between it and the coarsest wait geometrically more",
}
local update_interval_max = pvars.Setup2{
	key = "radiance_cache_update_interval_max",
	default = 64,
	integer = true,
	min = 1,
	max = 64,
	help = "frames between updates of the coarsest cascade, the further cascades reach the longer they can wait, but lighting that changes shows up in them that much later",
}

function radiance_cache.GetUpdateInterval(c)
	local lowest = update_interval_min:Get()
	return math.max(
		1,
		math.floor(
			lowest * (
					update_interval_max:Get() / lowest
				) ^ (
					(
						c - 1
					) / (
						radiance_cache.CASCADES - 1
					)
				) + 0.5
		)
	)
end

local min_coverage = pvars.Setup2{
	key = "radiance_cache_min_coverage",
	default = 4,
	min = 0,
	help = "least meters the fitted region reaches from its centre to each side",
}
local max_coverage = pvars.Setup2{
	key = "radiance_cache_max_coverage",
	default = 1000,
	min = 0,
	help = "most meters the fitted region reaches from the camera. Past it the probes are not there and the light is the sky's. The far cascades are 64 to 256 m apart, on Quarry 1000 m instead of 4000 m is the same picture and a few tenths of a millisecond",
}
local change_threshold = pvars.Setup2{
	key = "radiance_cache_change_threshold",
	default = 0.05,
	min = 0,
	help = "how far the sun may move (radians, plus its relative brightness change) before a cascade updates ahead of its interval, 0 turns it off",
}
local change_min_interval = pvars.Setup2{
	key = "radiance_cache_change_min_interval",
	default = 2,
	integer = true,
	min = 1,
	help = "least frames between two updates of a cascade that were triggered by the lighting changing",
}
radiance_cache.MIN_PROBES_PER_AXIS = 4
radiance_cache.RAYS_PER_PROBE = pvars.Setup2{
	key = "radiance_cache_rays",
	default = 64,
	integer = true,
	help = "rays each probe traces when its cascade updates, with the emitter samples this is most of the probe update. fewer is cheaper and noisier, which the probe history hides. built into the shaders, read at startup",
}:Get()
assert(radiance_cache.RAYS_PER_PROBE > 0, "radiance_cache_rays must be above 0")
radiance_cache.HALF_PRECISION_RAYS = true
radiance_cache.ALPHA_TEST = true
radiance_cache.EMITTER_SAMPLES = pvars.Setup2{
	key = "radiance_cache_emitter_samples",
	default = 8,
	integer = true,
	help = "emitter samples each probe takes when its cascade updates, each walks the emitter light tree and traces a shadow ray, on maps with many emitters the walk is most of the probe trace. built into the shaders, read at startup",
}:Get()
assert(radiance_cache.EMITTER_SAMPLES > 0, "radiance_cache_emitter_samples must be above 0")
radiance_cache.LIGHT_SAMPLES = 2
radiance_cache.IRRADIANCE_TEXELS = 8
radiance_cache.GUIDE_TEXELS = 8
radiance_cache.DISTANCE_TEXELS = 16
local hysteresis = pvars.Setup2{
	key = "radiance_cache_hysteresis",
	default = 0.97,
	min = 0,
	max = 1,
	help = "how much of a probe texel's history survives a frame at 60 fps, a cascade that updates less often keeps this to the power of the frames it was away",
}
local change_power = pvars.Setup2{
	key = "radiance_cache_change_power",
	default = 4,
	min = 1,
	help = "a probe whose light is changing (its mean ray brightness stays on one side of its median) keeps its history to this power per update, so it takes the new rays in faster. 1 turns that off",
}
local ray_clamp = pvars.Setup2{
	key = "radiance_cache_ray_clamp",
	default = 200,
	min = 0,
	help = "cap each ray's radiance at this many times the probe's mean ray luminance, 0 is off",
}
local guided_ray_fraction = pvars.Setup2{
	key = "radiance_cache_guided_rays",
	default = 0.7,
	min = 0,
	max = 1,
	help = "share of each probe's rays aimed by its own radiance map, 0 is uniform rays only",
}
local aim_share = pvars.Setup2{
	key = "radiance_cache_aim_share",
	default = 0.5,
	min = 0,
	max = 0.9,
	help = "the most of the rays a bright guide cell aims at the brightest spot of it, instead of spreading them over the cell. A small bright patch is a fraction of a percent of a cell and spread rays find it once in a while, each time the probe flickers. 0 spreads them. built into the shaders",
}

function radiance_cache.GetUniformRays()
	return radiance_cache.RAYS_PER_PROBE - math.floor(radiance_cache.RAYS_PER_PROBE * guided_ray_fraction:Get() + 0.5)
end

local light_radius = pvars.Setup2{
	key = "radiance_cache_light_radius",
	default = 0.1,
	min = 0,
	help = "radius of local lights in probe spacings when lighting ray hits",
}
radiance_cache.DISTANCE_EXPONENT = 50.0
radiance_cache.NORMAL_BIAS = 0.1
radiance_cache.VIEW_BIAS = 0.3
radiance_cache.BIAS_MAX_SPACING = 1
radiance_cache.BACKFACE_THRESHOLD = 0.25
local relocation = pvars.Setup2{
	key = "radiance_cache_relocation",
	default = true,
	help = "move probes out of geometry",
	callback = function()
		radiance_cache.ResetHistory()
	end,
}
radiance_cache.RELOCATION_DISTANCE = 0.25
radiance_cache.PROBE_MAX_OFFSET = 0.45
local strength = pvars.Setup2{
	key = "radiance_cache_strength",
	default = 1,
	min = 0,
	max = 4,
	help = "scales the light the probes give every surface (diffuse gi, the reflection fallback, translucent surfaces, traced hits, fog), the probes' own bounces are not scaled. 0 is no indirect light from them",
}
radiance_cache.SKY_INTENSITY = 1.0
radiance_cache.RANDOM_ROTATION = true
local shade_ray_generation = pvars.Setup2{
	key = "radiance_cache_shade_ray_generation",
	default = true,
	help = "the pass that lights the probe rays' hits is built as a ray generation shader of a ray tracing pipeline, off a compute shader. the same shader, the driver schedules it better. built into the shader",
}

function radiance_cache.IsShadeRayGeneration()
	return shade_ray_generation:Get()
end

local smooth_blend = pvars.Setup2{
	key = "radiance_cache_smooth_blend",
	default = true,
	help = "blend 3x3x3 probes with quadratic B-spline weights",
}
local VISIBILITY_RAYS = {none = 0, relocated = 1, all = 2}
local visibility_rays = pvars.Setup2{
	key = "radiance_cache_visibility_rays",
	default = "all",
	enums = {"none", "relocated", "all"},
	help = "probes checked with a ray: none, only the relocated ones, or all",
}
local contrast_ratio = pvars.Setup2{
	key = "radiance_cache_contrast_ratio",
	default = 4,
	min = 0,
	help = "the lookups of the probe rays' hits and of reflections trace a ray to the probes that are this many times brighter than the dimmest one that counts, the ones a thin wall can leak through. 0 traces all, a large number none",
}
local visibility_front_faces_only = pvars.Setup2{
	key = "radiance_cache_visibility_front_faces_only",
	default = false,
	help = "visibility rays only hit front faces",
}
local DEBUG_PROBES = {off = 0, irradiance = 1, hit_distance = 2}
local debug_probes = pvars.Setup2{
	key = "radiance_cache_debug_probes",
	default = "off",
	enums = {"off", "irradiance", "hit_distance"},
	help = "what the probe debug markers show: the probe irradiance or its mean hit distance",
}
local DEBUG_SCENE = {off = 0, albedo = 1, normals = 2, hit_distance = 3}
local debug_scene = pvars.Setup2{
	key = "radiance_cache_debug_scene",
	default = "off",
	enums = {"off", "albedo", "normals", "hit_distance"},
	help = "show the scene the probe rays trace as its albedo, normals or hit distance",
}
local debug_scale = pvars.Setup2{
	key = "radiance_cache_debug_scale",
	default = 1.0,
	min = 0,
	help = "brightness of the debug markers",
}
local debug_cascade = pvars.Setup2{
	key = "radiance_cache_debug_cascade",
	default = 0,
	integer = true,
	min = 0,
	max = radiance_cache.CASCADES - 1,
	help = "the cascade whose probes the debug view draws",
}
local max_ray_distance = pvars.Setup2{
	key = "radiance_cache_max_ray_distance",
	default = 4000,
	integer = true,
	min = 0,
	help = "max distance a ray can travel",
}
pvars.EndGroup()
radiance_cache.MISS_DISTANCE = radiance_cache.HALF_PRECISION_RAYS and 60000 or 1e27

function radiance_cache.GetDebugProbes()
	return DEBUG_PROBES[debug_probes:Get()]
end

function radiance_cache.GetCascadeSpacing(cascade)
	return probe_spacing:Get() * render3d.GetSnappedViewScale() * cascade_ratio:Get() ^ cascade
end

function radiance_cache.GetProbeCount()
	return radiance_cache.PROBES_PER_AXIS ^ 3 * radiance_cache.CASCADES
end

function radiance_cache.GetRayCount()
	return radiance_cache.GetProbeCount() * (
			radiance_cache.RAYS_PER_PROBE + radiance_cache.EMITTER_SAMPLES
		)
end

function radiance_cache.GetScreenSampleGLSL(block_name)
	return [[

		vec3 radiance_cache_screen_ray(vec2 uv) {
			vec4 p = ]] .. block_name .. [[.inv_projection * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
			return vec3(p.xy / -p.z, -1.0);
		}

		// lobe 0 is the diffuse estimate, above it the specular one is also stopped by how far apart the reflection directions are
		vec4 radiance_cache_screen_sample_texture(int screen_tex, vec2 uv, vec3 N, float view_depth, float lobe) {
			ivec2 size = textureSize(TEXTURE(screen_tex), 0);

			if (size == ivec2(]] .. block_name .. [[.render_size)) return texelFetch(TEXTURE(screen_tex), ivec2(uv * vec2(size)), 0);

			vec2 position = uv * vec2(size) - 0.5;
			ivec2 base = ivec2(floor(position));
			vec3 ray = radiance_cache_screen_ray(uv);
			vec3 ray_x = radiance_cache_screen_ray(uv + vec2(1.0 / float(size.x), 0.0)) - ray;
			vec3 ray_y = radiance_cache_screen_ray(uv + vec2(0.0, 1.0 / float(size.y))) - ray;
			vec3 P = ray * view_depth;
			vec3 n = mat3(]] .. block_name .. [[.view) * N;
			vec3 R = reflect(normalize(P), n);
			// a gi texel stands for one of the screen pixels under it, its position is only known to about a texel
			float plane_tolerance = view_depth * (0.01 + 2.0 * max(length(ray_x), length(ray_y)));
			vec4 sum = vec4(0.0);
			float total = 0.0;
			vec4 best = vec4(0.0);
			float best_weight = -1.0;

			// the outer ring is only read where no texel of the bilinear quad lies on this surface
			for (int ring = 0; ring < 2; ring++) {
				if (ring == 1 && total > 0.2) break;

				for (int y = -1; y <= 2; y++) {
					for (int x = -1; x <= 2; x++) {
						if ((x >= 0 && x <= 1 && y >= 0 && y <= 1) != (ring == 0)) continue;

						ivec2 texel = base + ivec2(x, y);

						if (any(lessThan(texel, ivec2(0))) || any(greaterThanEqual(texel, size))) continue;

						vec2 offset = vec2(texel) - position;
						float spatial = ring == 0 ? (1.0 - abs(offset.x)) * (1.0 - abs(offset.y)) : 0.01;

						if (spatial <= 0.0) continue;

						vec4 geometry = texelFetch(TEXTURE(]] .. block_name .. [[.gi_screen_geometry_tex), texel, 0);
						vec3 q_n = mat3(]] .. block_name .. [[.view) * geometry.xyz;
						vec3 Q = (ray + ray_x * offset.x + ray_y * offset.y) * geometry.w;
						float plane = max(abs(dot(n, Q - P)), abs(dot(q_n, P - Q)));
						float w = exp(-plane / plane_tolerance) * pow(max(dot(n, q_n), 0.0), 16.0);

						if (lobe > 0.0) w *= pow(max(dot(R, reflect(normalize(Q), q_n)), 0.0), lobe);

						vec4 value = texelFetch(TEXTURE(screen_tex), texel, 0);

						if (w > best_weight) {
							best_weight = w;
							best = value;
						}

						sum += value * w * spatial;
						total += w * spatial;
					}
				}
			}

			// no texel lies on this surface (an edge thinner than a gi texel): the closest match beats a blend across the edge
			return (sum + best * 1e-3) / (total + 1e-3);
		}

		vec4 radiance_cache_screen_sample(vec2 uv, vec3 N, float view_depth) {
			return radiance_cache_screen_sample_texture(]] .. block_name .. [[.gi_screen_tex, uv, N, view_depth, 0.0);
		}

		vec4 radiance_cache_screen_specular_sample(vec2 uv, vec3 N, float view_depth, float perceptual_roughness) {
			float a = max(perceptual_roughness * perceptual_roughness, 0.02);
			vec4 weighted = radiance_cache_screen_sample_texture(]] .. block_name .. [[.gi_screen_specular_tex, uv, N, view_depth, 2.0 / (a * a));
			return vec4(weighted.rgb / max(weighted.a, 1e-4), 1.0);
		}
	]]
end

function radiance_cache.GetDebugSceneMode()
	return DEBUG_SCENE[debug_scene:Get()]
end

function radiance_cache.GetDebugOverlayTexture()
	if radiance_cache.GetDebugProbes() == 0 then return nil end

	return render3d.pipelines.radiance_cache_probe_debug:GetFramebuffer(1):GetAttachment(1)
end

function radiance_cache.RTSupported()
	return render.GetDevice().ray_tracing_supported
end

function radiance_cache.ResetHistory()
	radiance_cache.force_reset = true
end

event.AddListener("ViewScaleChanged", "radiance_cache", function()
	radiance_cache.ResetHistory()
end)

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
		local view_scale = render3d.GetSnappedViewScale()
		local min_reach = min_coverage:Get() * view_scale
		local max_reach = max_coverage:Get() * view_scale
		local lo, hi = camera - min_reach, camera + min_reach

		if bounds_min then
			lo = math.max(bounds_min[axis], camera - max_reach)
			hi = math.min(bounds_max[axis], camera + max_reach)

			if hi < lo then lo, hi = camera - min_reach, camera + min_reach end
		end

		if hi - lo < min_reach * 2 then
			local mid = (lo + hi) / 2
			lo, hi = mid - min_reach, mid + min_reach
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
		local budget = radiance_cache.PROBES_PER_AXIS ^ 3
		local a, b, c = "x", "y", "z"
		local need = cascade.need

		if need[a] > need[b] then a, b = b, a end

		if need[b] > need[c] then b, c = c, b end

		if need[a] > need[b] then a, b = b, a end

		local n = math.max(
			math.min(need[a], math.floor(budget ^ (1 / 3) + 1e-6)),
			radiance_cache.MIN_PROBES_PER_AXIS
		)
		cascade.size[a] = n
		budget = math.floor(budget / n)
		n = math.max(
			math.min(need[b], math.floor(math.sqrt(budget) + 1e-6)),
			radiance_cache.MIN_PROBES_PER_AXIS
		)
		cascade.size[b] = n
		budget = math.floor(budget / n)
		cascade.size[c] = math.max(math.min(need[c], budget), radiance_cache.MIN_PROBES_PER_AXIS)
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

	function radiance_cache.GetFrameState()
		local frame = system.GetFrameNumber()

		if state.frame == frame then return state end

		state.frame = frame
		local position = render3d.GetCamera():GetPosition()
		local bounds_min, bounds_max = scene_bridge.GetBounds()
		local region = state.region
		region.min_x, region.max_x = fit_region(0, position.x, bounds_min, bounds_max)
		region.min_y, region.max_y = fit_region(1, position.y, bounds_min, bounds_max)
		region.min_z, region.max_z = fit_region(2, position.z, bounds_min, bounds_max)
		local frame_time = system.GetUnscaledFrameTime()
		local irradiance = render3d.pipelines.radiance_cache_irradiance
		local framebuffers = irradiance and irradiance.framebuffers
		local reset_mask = 0
		local update_mask = 0

		if radiance_cache.force_reset or framebuffers ~= state.history_framebuffers then
			reset_mask = bit.lshift(1, radiance_cache.CASCADES) - 1
		end

		local count = radiance_cache.CASCADES
		local lights = render3d.GetLights()
		local sun = directional_shadows.GetPrimarySunDirection(lights)
		local sun_x, sun_y, sun_z = sun.x, sun.y, sun.z
		local sun_luma = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, sun_y)
		local threshold = change_threshold:Get()
		local reference = state.sun_reference

		if not reference or frame - reference.frame >= 8 then
			if reference and threshold > 0 then
				local luma_change = math.abs(sun_luma - reference.luma) / math.max(sun_luma, reference.luma, 1e-3)
				local moved = math.sqrt(
					(
							sun_x - reference.x
						) ^ 2 + (
							sun_y - reference.y
						) ^ 2 + (
							sun_z - reference.z
						) ^ 2
				)

				if moved + luma_change > threshold then state.sun_fast_until = frame + 60 end
			end

			reference = reference or {}
			reference.x, reference.y, reference.z, reference.luma, reference.frame = sun_x, sun_y, sun_z, sun_luma, frame
			state.sun_reference = reference
		end

		for c = 1, radiance_cache.CASCADES do
			local spacing = radiance_cache.GetCascadeSpacing(c - 1)
			local cascade = state.cascades[c] or {need = {}, size = {}}
			local need, size = cascade.need, cascade.size
			local old_x, old_y, old_z = size.x, size.y, size.z

			if bounds_min then
				need.x = fit_need(region.max_x - region.min_x, spacing, need.x)
				need.y = fit_need(region.max_y - region.min_y, spacing, need.y)
				need.z = fit_need(region.max_z - region.min_z, spacing, need.z)
				distribute(cascade)
			else
				size.x, size.y, size.z = radiance_cache.PROBES_PER_AXIS, radiance_cache.PROBES_PER_AXIS, radiance_cache.PROBES_PER_AXIS
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
			local interval = radiance_cache.GetUpdateInterval(c)
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

		if radiance_cache.RANDOM_ROTATION then
			random_rotation(state.rotation)
		else
			state.rotation.x, state.rotation.y, state.rotation.z, state.rotation.w = 0, 0, 0, 1
		end

		state.history_framebuffers = framebuffers
		state.rt_ready = false
		radiance_cache.force_reset = false
		return state
	end
end

function radiance_cache.GetRayDirection(index, n, rotation)
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

function radiance_cache.GetDefinesGLSL()
	return (
		[[

		#define RADIANCE_CACHE_P %d
		#define RADIANCE_CACHE_CASCADES %d
		#define RADIANCE_CACHE_RAYS %d
		#define RADIANCE_CACHE_EMITTER_SAMPLES %d
		#define RADIANCE_CACHE_RAY_STRIDE (RADIANCE_CACHE_RAYS + RADIANCE_CACHE_EMITTER_SAMPLES)
		#define RADIANCE_CACHE_IRRADIANCE_TEXELS %d
		#define RADIANCE_CACHE_DISTANCE_TEXELS %d
		#define RADIANCE_CACHE_MISS_DISTANCE %.1e
		#define RADIANCE_CACHE_RAY_MAX %.1e
		#define RADIANCE_CACHE_DIRECTION_BITS %du
		#define RADIANCE_CACHE_DIRECTION_OFFSET %.1f
		#define RADIANCE_CACHE_SUN_VISIBLE_BIT 0x80000000u
		#define RADIANCE_CACHE_SHADOW_OFFSET (0.02 * radiance_cache_data.radiance_cache_view_scale)
		#define RADIANCE_CACHE_ORIGIN_PULL 0.001
		#define RADIANCE_CACHE_LIGHT_SAMPLES %d
		#define RADIANCE_CACHE_BACKFACE_SCALE 0.2
		// GLSL leaves %% undefined for negative operands (NVIDIA treats them
		// as unsigned), so shift into the positive range before wrapping
		#define RADIANCE_CACHE_WRAP(v, n) (((v) + (n) * 65536) %% (n))
		#define RADIANCE_CACHE_VISIBILITY_MASK %d
		#define RADIANCE_CACHE_SCENE_MASK %d
		#define RADIANCE_CACHE_DISABLED_PROBE_FRAMES 8u

		bool radiance_cache_probe_idle(float data_w, bool current, int probe, int c, uint frame) {
			if (!current || (int((data_w - 1.0) * 0.5) & 3) != 2) return false;

			uint h = uint(probe >> 5) * 747796405u + uint(c) * 2891336453u + frame * 277803737u;
			h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
			h = (h >> 22u) ^ h;
			return h %% max(RADIANCE_CACHE_DISABLED_PROBE_FRAMES >> uint(c), 1u) != 0u;
		}
	]]
	):format(
		radiance_cache.PROBES_PER_AXIS,
		radiance_cache.CASCADES,
		radiance_cache.RAYS_PER_PROBE,
		radiance_cache.EMITTER_SAMPLES,
		radiance_cache.IRRADIANCE_TEXELS,
		radiance_cache.DISTANCE_TEXELS,
		radiance_cache.MISS_DISTANCE,
		radiance_cache.HALF_PRECISION_RAYS and 65000 or 3e38,
		radiance_cache.HALF_PRECISION_RAYS and 6 or 12,
		radiance_cache.HALF_PRECISION_RAYS and 2048 or 0,
		radiance_cache.LIGHT_SAMPLES,
		radiance_cache.ALPHA_TEST and
			scene_instances.MASK_GI_SOLID or
			scene_instances.MASK_GI,
		scene_instances.MASK_GI
	)
end

function radiance_cache.GetRayDirectionGLSL()
	return glsl_common.GetOctahedralGLSL() .. "\t\t#define RADIANCE_CACHE_GUIDE_TEXELS " .. radiance_cache.GUIDE_TEXELS .. "\n\t\t#define RADIANCE_CACHE_GUIDE_CELLS " .. radiance_cache.GUIDE_TEXELS * radiance_cache.GUIDE_TEXELS .. "\n" .. [[
		#define RADIANCE_CACHE_GUIDE_HISTORY 0.9
		#define RADIANCE_CACHE_GUIDE_STAMP_CELL 63
		#define RADIANCE_CACHE_AIM_SIZE 0.125
		#define RADIANCE_CACHE_AIM_SHARE ]] .. string.format("%.3f", aim_share:Get()) .. [[

		#ifndef RADIANCE_CACHE_GUIDE_FETCH
		#define RADIANCE_CACHE_GUIDE_FETCH(texel) texelFetch(TEXTURE(radiance_cache_data.radiance_cache_guide_tex), texel, 0)
		#endif

		vec3 radiance_cache_fibonacci(uint index, uint count, vec4 q) {
			const float golden = 0.61803398875;
			float phi = 6.28318530718 * fract(float(index) * golden);
			float cos_theta = 1.0 - (2.0 * float(index) + 1.0) / float(count);
			float sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
			vec3 v = vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
			return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
		}

		float radiance_cache_guide_stamp(ivec3 world, int c) {
			uint h = uint(world.x) * 73856093u ^ uint(world.y) * 19349663u ^ uint(world.z) * 83492791u ^ uint(c + 1) * 2654435761u;
			return float(h & 0xFFFFFFu) + 1.0;
		}

		ivec2 radiance_cache_guide_texel(ivec2 tile, int cell) {
			return tile * RADIANCE_CACHE_GUIDE_TEXELS + ivec2(cell % RADIANCE_CACHE_GUIDE_TEXELS, cell / RADIANCE_CACHE_GUIDE_TEXELS);
		}

		bool radiance_cache_guide_valid(ivec2 tile, ivec3 world, int c) {
			return RADIANCE_CACHE_GUIDE_FETCH(radiance_cache_guide_texel(tile, RADIANCE_CACHE_GUIDE_STAMP_CELL)).b == radiance_cache_guide_stamp(world, c);
		}

		vec3 radiance_cache_guide_aim_stored(float stored) {
			uint v = uint(stored);
			return vec3(float(v & 255u), float((v >> 8u) & 255u), float((v >> 16u) & 255u)) / 255.0;
		}

		vec3 radiance_cache_guide_aim(float stored) {
			vec3 aim = radiance_cache_guide_aim_stored(stored);
			return vec3(clamp(aim.xy, vec2(RADIANCE_CACHE_AIM_SIZE * 0.5), vec2(1.0 - RADIANCE_CACHE_AIM_SIZE * 0.5)), aim.z * RADIANCE_CACHE_AIM_SHARE);
		}

		vec3 radiance_cache_guide_sample(float u, vec2 inner, float aim_pick, ivec2 tile) {
			int lo = 0;
			int hi = RADIANCE_CACHE_GUIDE_CELLS - 1;

			while (lo < hi) {
				int mid = (lo + hi) / 2;

				if (RADIANCE_CACHE_GUIDE_FETCH(radiance_cache_guide_texel(tile, mid)).b < u) {
					lo = mid + 1;
				} else {
					hi = mid;
				}
			}

			vec3 aim = radiance_cache_guide_aim(RADIANCE_CACHE_GUIDE_FETCH(radiance_cache_guide_texel(tile, lo)).a);

			if (aim_pick < aim.z) inner = aim.xy + (inner - 0.5) * RADIANCE_CACHE_AIM_SIZE;

			vec2 p = (vec2(lo % RADIANCE_CACHE_GUIDE_TEXELS, lo / RADIANCE_CACHE_GUIDE_TEXELS) + inner) / float(RADIANCE_CACHE_GUIDE_TEXELS) * 2.0 - 1.0;
			return oct_decode(p);
		}

		float radiance_cache_guide_density(vec3 d, ivec2 tile) {
			vec2 scaled = (oct_encode(d) * 0.5 + 0.5) * float(RADIANCE_CACHE_GUIDE_TEXELS);
			ivec2 cell = clamp(ivec2(scaled), ivec2(0), ivec2(RADIANCE_CACHE_GUIDE_TEXELS - 1));
			vec4 texel = RADIANCE_CACHE_GUIDE_FETCH(tile * RADIANCE_CACHE_GUIDE_TEXELS + cell);
			vec3 aim = radiance_cache_guide_aim(texel.a);
			vec2 offset = abs(clamp(scaled - vec2(cell), 0.0, 1.0) - aim.xy);
			float in_cell = (1.0 - aim.z) + (all(lessThanEqual(offset, vec2(RADIANCE_CACHE_AIM_SIZE * 0.5))) ? aim.z / (RADIANCE_CACHE_AIM_SIZE * RADIANCE_CACHE_AIM_SIZE) : 0.0);
			vec3 a = abs(d);
			float l1 = a.x + a.y + a.z;
			return texel.g * in_cell * float(RADIANCE_CACHE_GUIDE_TEXELS * RADIANCE_CACHE_GUIDE_TEXELS) * 0.25 / (l1 * l1 * l1);
		}

		vec3 radiance_cache_ray_direction(uint index, uint uniform_count, vec4 q, ivec2 tile, bool guided) {
			if (index < uniform_count) return radiance_cache_fibonacci(index, uniform_count, q);

			uint k = index - uniform_count;
			uint guided_count = uint(RADIANCE_CACHE_RAYS) - uniform_count;

			if (!guided) return radiance_cache_fibonacci(k, guided_count, q);

			vec3 jitter = fract(abs(q.xyz) * 1000.0 + q.w * 7.0);
			return radiance_cache_guide_sample(fract((float(k) + 0.5) / float(guided_count) + jitter.x), fract(vec2(0.7548776662, 0.5698402910) * float(k) + jitter.yz), fract(float(k) * 0.8191725134 + jitter.y * 7.0), tile);
		}

		float radiance_cache_ray_weight(vec3 d, uint uniform_count, ivec2 tile, bool guided) {
			if (!guided || uniform_count >= uint(RADIANCE_CACHE_RAYS)) return 1.0;

			float share = float(uniform_count) / float(RADIANCE_CACHE_RAYS);
			return 1.0 / (share + (1.0 - share) * radiance_cache_guide_density(d, tile) * 12.5663706144);
		}
	]]
end

local MIN_WEIGHT = "0.05"
radiance_cache.MIN_WEIGHT = MIN_WEIGHT

function radiance_cache.GetCommonGLSL()
	return medium_common.GetGLSL() .. radiance_cache.GetDefinesGLSL() .. radiance_cache.GetRayDirectionGLSL() .. glsl_common.GetLuminanceGLSL() .. [[

		vec3 radiance_cache_ground_fog_sun_transmittance(float altitude, float sun_up, float fog_extinction, float precipitation_extinction, float scale_height, float start, float top) {
			return exponential_layer_transmittance(altitude, sun_up, fog_extinction, precipitation_extinction, scale_height, start, top, ]] .. atmosphere.GROUND_FOG_TINT_GLSL .. [[);
		}

		ivec3 radiance_cache_volume_base(int c) {
			return ivec3(radiance_cache_data.radiance_cache_cascades[c].xyz);
		}

		float radiance_cache_spacing(int c) {
			return radiance_cache_data.radiance_cache_cascades[c].w;
		}

		ivec3 radiance_cache_volume_size(int c) {
			return ivec3(radiance_cache_data.radiance_cache_cascade_size[c].xyz);
		}

		int radiance_cache_probe_count(int c) {
			ivec3 n = radiance_cache_volume_size(c);
			return n.x * n.y * n.z;
		}

		ivec3 radiance_cache_slot(ivec3 world, int c) {
			return RADIANCE_CACHE_WRAP(world, radiance_cache_volume_size(c));
		}

		int radiance_cache_probe_index(ivec3 slot, int c) {
			ivec3 n = radiance_cache_volume_size(c);
			return slot.x + n.x * (slot.y + n.y * slot.z);
		}

		ivec3 radiance_cache_slot_from_index(int index, int c) {
			ivec3 n = radiance_cache_volume_size(c);
			return ivec3(index % n.x, (index / n.x) % n.y, index / (n.x * n.y));
		}

		ivec2 radiance_cache_ray_texel(uint ray, ivec3 slot, int c) {
			return ivec2(int(ray) + RADIANCE_CACHE_RAY_STRIDE * c, radiance_cache_probe_index(slot, c));
		}

		ivec3 radiance_cache_world_from_slot(ivec3 slot, int c) {
			ivec3 base = radiance_cache_volume_base(c);
			return base + RADIANCE_CACHE_WRAP(slot - radiance_cache_slot(base, c), radiance_cache_volume_size(c));
		}

		ivec2 radiance_cache_tile_from_index(int index, int c) {
			return ivec2(index % (RADIANCE_CACHE_P * RADIANCE_CACHE_P), index / (RADIANCE_CACHE_P * RADIANCE_CACHE_P) + RADIANCE_CACHE_P * c);
		}

		ivec2 radiance_cache_tile(ivec3 slot, int c) {
			return radiance_cache_tile_from_index(radiance_cache_probe_index(slot, c), c);
		}

		bool radiance_cache_in_volume(vec3 P) {
			if (radiance_cache_data.radiance_cache_cascade_count == 0) return false;

			int c = radiance_cache_data.radiance_cache_cascade_count - 1;
			vec3 grid = P / radiance_cache_spacing(c) - vec3(radiance_cache_volume_base(c));
			return all(greaterThanEqual(grid, vec3(0.0))) && all(lessThanEqual(grid, vec3(radiance_cache_volume_size(c) - 1)));
		}

		float radiance_cache_pack_direction(vec3 d) {
			const float levels = float((1u << RADIANCE_CACHE_DIRECTION_BITS) - 1u);
			uvec2 q = uvec2((oct_encode(d) * 0.5 + 0.5) * levels + 0.5);
			return float(q.x | (q.y << RADIANCE_CACHE_DIRECTION_BITS)) - RADIANCE_CACHE_DIRECTION_OFFSET;
		}

		vec3 radiance_cache_unpack_direction(float packed) {
			const uint mask = (1u << RADIANCE_CACHE_DIRECTION_BITS) - 1u;
			uint v = uint(packed + RADIANCE_CACHE_DIRECTION_OFFSET);
			return oct_decode(vec2(v & mask, v >> RADIANCE_CACHE_DIRECTION_BITS) / float(mask) * 2.0 - 1.0);
		}

		vec3 radiance_cache_texel_direction(ivec2 texel, int texels) {
			int last = texels - 1;
			bool border_x = texel.x == 0 || texel.x == last;
			bool border_y = texel.y == 0 || texel.y == last;
			ivec2 src = texel;

			if (border_x && border_y) {
				src = ivec2(texel.x == 0 ? last - 1 : 1, texel.y == 0 ? last - 1 : 1);
			} else if (border_y) {
				src = ivec2(last - texel.x, texel.y == 0 ? 1 : last - 1);
			} else if (border_x) {
				src = ivec2(texel.x == 0 ? 1 : last - 1, last - texel.y);
			}

			vec2 uv = (vec2(src - 1) + 0.5) / float(texels - 2);
			return oct_decode(uv * 2.0 - 1.0);
		}

		vec2 radiance_cache_atlas_uv(ivec3 slot, int c, vec3 dir, int texels) {
			vec2 atlas_size = vec2(RADIANCE_CACHE_P * RADIANCE_CACHE_P * texels, RADIANCE_CACHE_P * RADIANCE_CACHE_CASCADES * texels);
			vec2 oct = oct_encode(dir) * 0.5 + 0.5;
			vec2 pixel = vec2(radiance_cache_tile(slot, c) * texels) + 1.0 + oct * float(texels - 2);
			return pixel / atlas_size;
		}

		vec4 radiance_cache_probe_data(ivec3 slot, int c) {
			return texelFetch(TEXTURE(radiance_cache_data.radiance_cache_probe_data_tex), radiance_cache_tile(slot, c), 0);
		}

		bool radiance_cache_probe_is_current(vec4 data, ivec3 world) {
			return data.w >= 1.0 && ivec3(round(data.xyz)) == world;
		}

		int radiance_cache_probe_flags(vec4 data) {
			return int((data.w - 1.0) * 0.5);
		}

		bool radiance_cache_probe_moved(vec4 data) {
			return (radiance_cache_probe_flags(data) & 1) != 0;
		}

		bool radiance_cache_probe_disabled(vec4 data) {
			return (radiance_cache_probe_flags(data) & 2) != 0;
		}

		float radiance_cache_probe_backfaces(vec4 data) {
			return data.w - 1.0 - 2.0 * float(radiance_cache_probe_flags(data));
		}

		vec3 radiance_cache_probe_origin(ivec3 slot, int c, ivec3 world) {
			vec4 data = radiance_cache_probe_data(slot, c);
			return (radiance_cache_probe_is_current(data, world) ? data.xyz : vec3(world)) * radiance_cache_spacing(c);
		}

		vec3 radiance_cache_sky(vec3 dir) {
			if (radiance_cache_data.radiance_cache_env_tex < 0) return vec3(0.0);

			vec4 stored = textureLod(
				TEXTURE(radiance_cache_data.radiance_cache_env_tex),
				dir_to_equirect_uv(correct_environment_lookup_dir(dir)),
				1.0
			);
			return stored.rgb * stored.a * radiance_cache_data.radiance_cache_sky_intensity;
		}

		vec3 radiance_cache_fog_ambient() {
			return sample_environment_irradiance(radiance_cache_data.radiance_cache_env_irradiance_tex, vec3(0.0, 1.0, 0.0)) / 3.14159265359;
		}

		bool radiance_cache_cascade_reset(int c) {
			return (radiance_cache_data.radiance_cache_reset_mask & (1 << c)) != 0;
		}

		bool radiance_cache_probe_is_idle(ivec3 slot, ivec3 world, int probe, int c) {
			vec4 data = radiance_cache_probe_data(slot, c);
			return radiance_cache_probe_idle(data.w, !radiance_cache_cascade_reset(c) && radiance_cache_probe_is_current(data, world), probe, c, uint(radiance_cache_data.radiance_cache_frame));
		}

		vec3 radiance_cache_ray(uint index, ivec2 tile, bool guided) {
			return radiance_cache_ray_direction(index, uint(radiance_cache_data.radiance_cache_uniform_rays), radiance_cache_data.radiance_cache_rotation, tile, guided);
		}

		float radiance_cache_ray_q(vec3 d, ivec2 tile, bool guided) {
			return radiance_cache_ray_weight(d, uint(radiance_cache_data.radiance_cache_uniform_rays), tile, guided);
		}

		#define RADIANCE_CACHE_VISIBILITY_MIN_WEIGHT 0.02
		#define RADIANCE_CACHE_VISIBILITY_MIN_SHARE 0.02
		#define RADIANCE_CACHE_NO_VISIBILITY_RAYS 1e30
		#define RADIANCE_CACHE_CONTRAST_VISIBILITY_RAYS 1e29
		#define RADIANCE_CACHE_CONTRAST_SHARE 0.002
		#define RADIANCE_CACHE_HIDDEN_LEAK_SHARE 0.5
		#define RADIANCE_CACHE_HIDDEN_LEAK_RATIO 2.0
		#define RADIANCE_CACHE_LOW_WEIGHT_FLOOR 0.4
		float radiance_cache_contrast_reference = 0.0;

		#ifdef RADIANCE_CACHE_VISIBILITY_RAYS
		]] .. scene_hit.GetEscapeGLSL("scene_tlas") .. [[
		#endif

		vec3 radiance_cache_probe_ray_origin(vec3 P, vec3 N, float spacing) {
			#ifdef RADIANCE_CACHE_VISIBILITY_RAYS
			return scene_escape_tessellation(P + N * (0.02 * spacing), N, 0.1);
			#else
			return P;
			#endif
		}

		float radiance_cache_probe_hit_fraction(vec3 origin, vec3 probe_pos) {
			#ifdef RADIANCE_CACHE_VISIBILITY_RAYS
			vec3 to_probe_ray = probe_pos - origin;
			float len = length(to_probe_ray);

			// a ray query with a nan or zero direction is undefined
			if (!(len > 1e-4)) return 0.0;

			rayQueryEXT query;
			rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | (radiance_cache_data.radiance_cache_visibility_front_faces_only != 0 ? gl_RayFlagsCullBackFacingTrianglesEXT : 0u), RADIANCE_CACHE_VISIBILITY_MASK, origin, 0.0, to_probe_ray / len, len);

			while (rayQueryProceedEXT(query)) {}

			if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return 2.0;

			return rayQueryGetIntersectionTEXT(query, true) / len;
			#else
			return 2.0;
			#endif
		}

		bool radiance_cache_probe_hidden(vec3 origin, vec3 probe_pos) {
			return radiance_cache_probe_hit_fraction(origin, probe_pos) <= 1.0;
		}

		bool radiance_cache_probe_can_be_traced(vec3 probe_position, ivec3 world) {
			return radiance_cache_data.radiance_cache_rt_ready != 0 && (radiance_cache_data.radiance_cache_visibility_rays == 2 || radiance_cache_data.radiance_cache_visibility_rays == 1 && probe_position != vec3(world));
		}

		float radiance_cache_probe_weight(int c, ivec3 world, float kernel, vec3 P, vec3 N, vec3 biased, float spacing, out ivec3 slot, out vec3 probe_position) {
			slot = radiance_cache_slot(world, c);
			vec4 data = radiance_cache_probe_data(slot, c);
			probe_position = data.xyz;

			if (!radiance_cache_probe_is_current(data, world) || radiance_cache_probe_disabled(data)) return 0.0;

			vec3 probe_pos = data.xyz * spacing;
			vec3 to_probe = normalize(probe_pos - P);
			float w = (dot(to_probe, N) + 1.0) * 0.5;
			w = w * w + 0.2;

			vec3 probe_to_point = biased - probe_pos;
			float dist = length(probe_to_point);
			vec2 moments = textureLod(
				TEXTURE(radiance_cache_data.radiance_cache_distance_tex),
				radiance_cache_atlas_uv(slot, c, probe_to_point / max(dist, 1e-4), RADIANCE_CACHE_DISTANCE_TEXELS),
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

			if (w < 0.2) w *= w * w / 0.04;

			return w * kernel;
		}

		#ifdef RADIANCE_CACHE_VISIBILITY_STATS
		float radiance_cache_stats_hidden_share = 0.0;
		vec3 radiance_cache_stats_unoccluded = vec3(0.0);
		#endif

		bool radiance_cache_probe_needs_trace(float w, float luma, vec4 sum, float visibility_min_weight) {
			return visibility_min_weight == RADIANCE_CACHE_CONTRAST_VISIBILITY_RAYS ?
				luma > radiance_cache_data.radiance_cache_contrast_ratio * radiance_cache_contrast_reference && w * luma > RADIANCE_CACHE_CONTRAST_SHARE * luminance(sum.rgb) :
				visibility_min_weight < RADIANCE_CACHE_NO_VISIBILITY_RAYS && (w >= visibility_min_weight || w * luma > RADIANCE_CACHE_VISIBILITY_MIN_SHARE * luminance(sum.rgb));
		}

		vec4 radiance_cache_sample_cascade_pair(int c, vec3 P, vec3 N, vec3 L, vec3 L2, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight, out vec4 second) {
			weight = 0.0;
			second = vec4(0.0);
			#ifdef RADIANCE_CACHE_VISIBILITY_STATS
			float stats_total = 0.0;
			float stats_hidden = 0.0;
			vec3 stats_sum = vec3(0.0);
			radiance_cache_stats_hidden_share = 0.0;
			radiance_cache_stats_unoccluded = vec3(0.0);
			#endif

			if (radiance_cache_cascade_reset(c)) return vec4(0.0);

			float spacing = radiance_cache_spacing(c);
			vec3 biased = P + (N * radiance_cache_data.radiance_cache_normal_bias + V * radiance_cache_data.radiance_cache_view_bias) * min(spacing, ]] .. string.format("%.17g", radiance_cache.BIAS_MAX_SPACING) .. [[ * radiance_cache_data.radiance_cache_view_scale);
			vec3 grid = biased / spacing;
			int side = smooth_blend ? 3 : 2;
			ivec3 base_world = smooth_blend ? ivec3(floor(grid + 0.5)) - 1 : ivec3(floor(grid));
			vec3 alpha = grid - vec3(base_world) - (smooth_blend ? 1.0 : 0.0);
			vec3 below = 0.5 * (0.5 - alpha) * (0.5 - alpha);
			vec3 middle = 0.75 - alpha * alpha;
			vec3 above = 0.5 * (0.5 + alpha) * (0.5 + alpha);
			ivec3 volume_min = radiance_cache_volume_base(c);
			ivec3 volume_max = volume_min + radiance_cache_volume_size(c) - 1;
			vec4 sum = vec4(0.0);
			vec4 second_sum = vec4(0.0);
			vec4 hidden_sum = vec4(0.0);
			vec4 hidden_second_sum = vec4(0.0);
			vec4 leak_sum = vec4(0.0);
			vec4 leak_second_sum = vec4(0.0);
			float leak_weight = 0.0;
			float hidden_weight = 0.0;
			float hidden_luma = 1e30;
			float hidden_second_luma = 1e30;
			vec3 ray_origin = P;
			bool have_ray_origin = false;

			for (int i = 0; i < side * side * side; i++) {
				ivec3 offset = ivec3(i % side, (i / side) % side, i / (side * side));
				ivec3 world = base_world + offset;

				if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

				vec3 kernel = smooth_blend ? mix(mix(below, middle, equal(offset, ivec3(1))), above, equal(offset, ivec3(2))) : mix(1.0 - alpha, alpha, vec3(offset));
				ivec3 slot;
				vec3 probe_position;
				float w = radiance_cache_probe_weight(c, world, kernel.x * kernel.y * kernel.z, P, N, biased, spacing, slot, probe_position);

				if (w <= 0.0) continue;

				vec4 irradiance = textureLod(TEXTURE(radiance_cache_data.radiance_cache_irradiance_tex), radiance_cache_atlas_uv(slot, c, L, RADIANCE_CACHE_IRRADIANCE_TEXELS), 0.0);
				vec4 irradiance2 = textureLod(TEXTURE(radiance_cache_data.radiance_cache_irradiance_tex), radiance_cache_atlas_uv(slot, c, L2, RADIANCE_CACHE_IRRADIANCE_TEXELS), 0.0);
				bool trace = radiance_cache_probe_needs_trace(w, luminance(irradiance.rgb), sum, visibility_min_weight) || radiance_cache_probe_needs_trace(w, luminance(irradiance2.rgb), sum, visibility_min_weight);

				float hit_fraction = 2.0;

				if (trace && radiance_cache_probe_can_be_traced(probe_position, world)) {
					if (!have_ray_origin) {
						ray_origin = radiance_cache_probe_ray_origin(P, N, spacing);
						have_ray_origin = true;
					}

					hit_fraction = radiance_cache_probe_hit_fraction(ray_origin, probe_position * spacing);
				}

				bool hidden = hit_fraction <= 1.0;

				#ifdef RADIANCE_CACHE_VISIBILITY_STATS
				stats_total += w;
				stats_sum += irradiance.rgb * w;

				if (hidden) stats_hidden += w;
				#endif

				if (hidden) {
					hidden_sum += irradiance * w;
					hidden_second_sum += irradiance2 * w;
					hidden_weight += w;
					hidden_luma = min(hidden_luma, luminance(irradiance.rgb));
					hidden_second_luma = min(hidden_second_luma, luminance(irradiance2.rgb));
					float leak = w * RADIANCE_CACHE_HIDDEN_LEAK_SHARE * hit_fraction * hit_fraction;
					leak_sum += irradiance * leak;
					leak_second_sum += irradiance2 * leak;
					leak_weight += leak;
					continue;
				}

				sum += irradiance * w;
				second_sum += irradiance2 * w;
				weight += w;
			}

			#ifdef RADIANCE_CACHE_VISIBILITY_STATS
			radiance_cache_stats_hidden_share = stats_hidden / max(stats_total, 1e-6);
			radiance_cache_stats_unoccluded = stats_sum / max(stats_total, ]] .. MIN_WEIGHT .. [[);
			#endif

			if (weight <= 0.0 && hidden_weight > 0.0) {
				vec4 fallback = hidden_sum / hidden_weight;
				vec4 fallback_second = hidden_second_sum / hidden_weight;
				fallback.rgb *= min(1.0, hidden_luma / max(luminance(fallback.rgb), 1e-6));
				fallback_second.rgb *= min(1.0, hidden_second_luma / max(luminance(fallback_second.rgb), 1e-6));
				second = fallback_second;
				return fallback;
			}

			if (weight <= 0.0) {
				second = vec4(0.0);
				return vec4(0.0);
			}

			vec4 visible = sum / weight;
			vec4 visible_second = second_sum / weight;
			float total = weight;

			if (leak_weight > 0.0) {
				vec4 leak = leak_sum / leak_weight;
				vec4 leak_second = leak_second_sum / leak_weight;
				leak.rgb *= min(1.0, RADIANCE_CACHE_HIDDEN_LEAK_RATIO * luminance(visible.rgb) / max(luminance(leak.rgb), 1e-6));
				leak_second.rgb *= min(1.0, RADIANCE_CACHE_HIDDEN_LEAK_RATIO * luminance(visible_second.rgb) / max(luminance(leak_second.rgb), 1e-6));
				leak_weight = min(leak_weight, RADIANCE_CACHE_HIDDEN_LEAK_SHARE * weight);
				total += leak_weight;
				visible = (sum + leak * leak_weight) / total;
				visible_second = (second_sum + leak_second * leak_weight) / total;
			}

			float fade = max(total / ]] .. MIN_WEIGHT .. [[, RADIANCE_CACHE_LOW_WEIGHT_FLOOR);
			visible.rgb *= min(1.0, fade);
			visible_second.rgb *= min(1.0, fade);
			second = visible_second;
			return visible;
		}

		float radiance_cache_cascade_blend(int c, vec3 P, bool smooth_blend) {
			vec3 grid = P / radiance_cache_spacing(c) - vec3(radiance_cache_volume_base(c));
			vec3 edge = min(grid, vec3(radiance_cache_volume_size(c) - 1) - grid);
			int holds = int(radiance_cache_data.radiance_cache_cascade_size[c].w);

			if ((holds & 1) != 0) edge.x = 1e9;

			if ((holds & 2) != 0) edge.y = 1e9;

			if ((holds & 4) != 0) edge.z = 1e9;

			return clamp((min(edge.x, min(edge.y, edge.z)) - (smooth_blend ? 1.5 : 1.0)) / radiance_cache_data.radiance_cache_cascade_blend, 0.0, 1.0);
		}

		vec4 radiance_cache_sample_irradiance_pair(vec3 P, vec3 N, vec3 L, vec3 L2, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight, out vec4 second) {
			weight = 0.0;
			second = vec4(0.0);
			vec4 result = vec4(0.0);
			int count = radiance_cache_data.radiance_cache_cascade_count;
			int first = 0;
			float keep = 1.0;

			for (; first < count - 1; first++) {
				keep = radiance_cache_cascade_blend(first, P, smooth_blend);

				if (keep > 0.0) break;
			}

			if (first == count - 1) keep = 1.0;

			#ifdef RADIANCE_CACHE_VISIBILITY_STATS
			float fine_hidden_share = 0.0;
			vec3 fine_unoccluded = vec3(0.0);
			#endif

			// the cascade and the coarser one it fades into share one call site: two inline the whole lookup twice into every consumer
			for (int c = first; c < min(first + 2, count); c++) {
				float cascade_weight;
				vec4 cascade_second;
				vec4 cascade = radiance_cache_sample_cascade_pair(c, P, N, L, L2, V, smooth_blend, visibility_min_weight, cascade_weight, cascade_second);

				if (c == first) {
					result = cascade;
					weight = cascade_weight;
					second = cascade_second;

					#ifdef RADIANCE_CACHE_VISIBILITY_RAYS
					if (visibility_min_weight < RADIANCE_CACHE_NO_VISIBILITY_RAYS) keep *= smoothstep(0.0, ]] .. MIN_WEIGHT .. [[, weight);
					#endif

					if (keep >= 1.0) break;

					#ifdef RADIANCE_CACHE_VISIBILITY_STATS
					fine_hidden_share = radiance_cache_stats_hidden_share;
					fine_unoccluded = radiance_cache_stats_unoccluded;
					#endif

					continue;
				}

				#ifdef RADIANCE_CACHE_VISIBILITY_STATS
				radiance_cache_stats_hidden_share = cascade_weight > 0.0 ? mix(radiance_cache_stats_hidden_share, fine_hidden_share, keep) : fine_hidden_share;
				radiance_cache_stats_unoccluded = cascade_weight > 0.0 ? mix(radiance_cache_stats_unoccluded, fine_unoccluded, keep) : fine_unoccluded;
				#endif

				if (cascade_weight > 0.0) {
					weight = mix(cascade_weight, weight, keep);
					result = mix(cascade, result, keep);
					second = mix(cascade_second, second, keep);
				}
			}

			#ifndef RADIANCE_CACHE_UNSCALED
			result.rgb *= radiance_cache_data.radiance_cache_strength;
			second.rgb *= radiance_cache_data.radiance_cache_strength;
			#ifdef RADIANCE_CACHE_VISIBILITY_STATS
			radiance_cache_stats_unoccluded *= radiance_cache_data.radiance_cache_strength;
			#endif
			#endif
			return result;
		}

		vec4 radiance_cache_sample_irradiance(vec3 P, vec3 N, vec3 L, vec3 V, bool smooth_blend, float visibility_min_weight, out float weight) {
			vec4 second;
			return radiance_cache_sample_irradiance_pair(P, N, L, L, V, smooth_blend, visibility_min_weight, weight, second);
		}
	]]
end

function radiance_cache.GetMediumGLSL()
	return [[
		vec4 radiance_cache_medium_cascade(int c, vec3 P, vec3 N, out float weight) {
			weight = 0.0;

			if (radiance_cache_cascade_reset(c)) return vec4(0.0);

			float spacing = radiance_cache_spacing(c);
			vec3 grid = P / spacing;
			ivec3 base_world = ivec3(floor(grid));
			vec3 alpha = grid - vec3(base_world);
			ivec3 volume_min = radiance_cache_volume_base(c);
			ivec3 volume_max = volume_min + radiance_cache_volume_size(c) - 1;
			vec4 sum = vec4(0.0);

			for (int i = 0; i < 8; i++) {
				ivec3 offset = ivec3(i & 1, (i >> 1) & 1, i >> 2);
				ivec3 world = base_world + offset;

				if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

				ivec3 slot = radiance_cache_slot(world, c);
				vec4 data = radiance_cache_probe_data(slot, c);

				if (!radiance_cache_probe_is_current(data, world) || radiance_cache_probe_disabled(data)) continue;

				vec3 probe_pos = data.xyz * spacing;
				vec3 probe_to_point = P - probe_pos;
				float dist = length(probe_to_point);
				vec2 moments = textureLod(
					TEXTURE(radiance_cache_data.radiance_cache_distance_tex),
					radiance_cache_atlas_uv(slot, c, probe_to_point / max(dist, 1e-4), RADIANCE_CACHE_DISTANCE_TEXELS),
					0.0
				).rg;
				float chebyshev = 1.0;

				if (dist > moments.x) {
					float variance = abs(moments.x * moments.x - moments.y);
					float d = dist - moments.x;
					chebyshev = variance / (variance + d * d);
					chebyshev = chebyshev * chebyshev * chebyshev;
				}

				float w = max(1e-6, 0.5333 * max(0.05, chebyshev));

				if (w < 0.2) w *= w * w / 0.04;

				vec3 kernel = mix(1.0 - alpha, alpha, vec3(offset));
				w *= kernel.x * kernel.y * kernel.z;

				if (w <= 0.0) continue;

				vec4 lit = vec4(
					0.5 * (
						textureLod(TEXTURE(radiance_cache_data.radiance_cache_irradiance_tex), radiance_cache_atlas_uv(slot, c, N, RADIANCE_CACHE_IRRADIANCE_TEXELS), 0.0).rgb +
						textureLod(TEXTURE(radiance_cache_data.radiance_cache_irradiance_tex), radiance_cache_atlas_uv(slot, c, -N, RADIANCE_CACHE_IRRADIANCE_TEXELS), 0.0).rgb
					),
					textureLod(TEXTURE(radiance_cache_data.radiance_cache_irradiance_tex), radiance_cache_atlas_uv(slot, c, vec3(0.0, 1.0, 0.0), RADIANCE_CACHE_IRRADIANCE_TEXELS), 0.0).a
				);
				bool trace = w >= RADIANCE_CACHE_VISIBILITY_MIN_WEIGHT || w * luminance(lit.rgb) > RADIANCE_CACHE_VISIBILITY_MIN_SHARE * luminance(sum.rgb);

				if (trace && radiance_cache_probe_can_be_traced(data.xyz, world) && radiance_cache_probe_hidden(P, probe_pos)) continue;

				sum += lit * w;
				weight += w;
			}

			return sum / max(weight, ]] .. MIN_WEIGHT .. [[);
		}

		vec4 radiance_cache_sample_medium(vec3 P, vec3 N, out float weight) {
			weight = 0.0;
			int count = radiance_cache_data.radiance_cache_cascade_count;
			vec4 result = vec4(0.0);

			for (int c = 0; c < count; c++) {
				float fine = c == count - 1 ? 1.0 : radiance_cache_cascade_blend(c, P, false);

				if (fine <= 0.0) continue;

				result = radiance_cache_medium_cascade(c, P, N, weight);

				if (c == count - 1) break;

				float keep = fine;

				#ifdef RADIANCE_CACHE_VISIBILITY_RAYS
				keep *= smoothstep(0.0, ]] .. MIN_WEIGHT .. [[, weight);
				#endif

				if (keep >= 1.0) break;

				float coarse_weight;
				vec4 coarse = radiance_cache_medium_cascade(c + 1, P, N, coarse_weight);

				if (coarse_weight > 0.0) {
					weight = mix(coarse_weight, weight, keep);
					result = mix(coarse, result, keep);
				}

				break;
			}

			#ifndef RADIANCE_CACHE_UNSCALED
			result.rgb *= radiance_cache_data.radiance_cache_strength;
			#endif
			return result;
		}
	]]
end

function radiance_cache.GetProbeBlockLayout()
	return {
		{"radiance_cache_cascades", "vec4", radiance_cache.CASCADES},
		{"radiance_cache_cascade_size", "vec4", radiance_cache.CASCADES},
		{"radiance_cache_rotation", "vec4"},
		{"radiance_cache_sun_direction", "vec4"},
		{"radiance_cache_sun_radiance", "vec4"},
		{"radiance_cache_ground_fog", "vec4"},
		{"radiance_cache_ground_fog_range", "vec4"},
		{"radiance_cache_max_distance", "float"},
		{"radiance_cache_cascade_update", "vec4", radiance_cache.CASCADES},
		{"radiance_cache_ray_clamp", "float"},
		{"radiance_cache_distance_exponent", "float"},
		{"radiance_cache_normal_bias", "float"},
		{"radiance_cache_view_scale", "float"},
		{"radiance_cache_view_bias", "float"},
		{"radiance_cache_backface_threshold", "float"},
		{"radiance_cache_relocation_distance", "float"},
		{"radiance_cache_max_offset", "float"},
		{"radiance_cache_sky_intensity", "float"},
		{"radiance_cache_strength", "float"},
		{"radiance_cache_light_radius", "float"},
		{"radiance_cache_cascade_blend", "float"},
		{"radiance_cache_contrast_ratio", "float"},
		{"radiance_cache_change_power", "float"},
		{"radiance_cache_debug_scale", "float"},
		{"radiance_cache_debug_probes", "int"},
		{"radiance_cache_debug_cascade", "int"},
		{"radiance_cache_debug_scene", "int"},
		{"radiance_cache_debug_manual_gamma", "int"},
		{"radiance_cache_smooth_blend", "int"},
		{"radiance_cache_visibility_rays", "int"},
		{"radiance_cache_visibility_front_faces_only", "int"},
		{"radiance_cache_cascade_count", "int"},
		{"radiance_cache_reset_mask", "int"},
		{"radiance_cache_update_mask", "int"},
		{"radiance_cache_rt_ready", "int"},
		{"radiance_cache_env_tex", "int"},
		{"radiance_cache_env_irradiance_tex", "int"},
		{"radiance_cache_ray_tex", "int"},
		{"radiance_cache_irradiance_tex", "int"},
		{"radiance_cache_distance_tex", "int"},
		{"radiance_cache_probe_data_tex", "int"},
		{"radiance_cache_emitter_count", "int"},
		{"radiance_cache_frame", "int"},
		{"radiance_cache_uniform_rays", "int"},
		{"radiance_cache_guide_tex", "int"},
		{"radiance_cache_bent_normal_tex", "int"},
		clouds.GetShadowBlockLayout(),
		-- imported here: caustics needs the render device, and this module loads before it exists
		import("goluwa/render3d/caustics.lua").hit_block,
	}
end

function radiance_cache.GetBlockLayout()
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
	}
	table.add(layout, radiance_cache.GetProbeBlockLayout())
	table.add(layout, post_source.pre_exposure_block)
	layout[#layout + 1] = {"light_transmittance", "int"}
	layout[#layout + 1] = {"medium_gi", "int"}
	return layout
end

local function pipeline_texture_index(self, name)
	local pipeline = render3d.pipelines[name]
	return pipeline and
		self:GetTextureIndex(pipeline:GetFramebuffer(1):GetAttachment(1)) or
		-1
end

function radiance_cache.WriteProbeBlock(self, block)
	local state = radiance_cache.GetFrameState()
	local lights = render3d.GetLights()
	local sun_direction = directional_shadows.GetPrimarySunDirection(lights)
	local sun_color = directional_shadows.GetPrimarySunColor(lights)
	local sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights) * math.smoothstep(-0.08, 0.02, sun_direction.y)
	sun_direction:CopyToFloatPointer(block.radiance_cache_sun_direction)
	block.radiance_cache_sun_direction[3] = 0
	block.radiance_cache_sun_radiance[0] = sun_color.x * sun_illuminance
	block.radiance_cache_sun_radiance[1] = sun_color.y * sun_illuminance
	block.radiance_cache_sun_radiance[2] = sun_color.z * sun_illuminance
	block.radiance_cache_sun_radiance[3] = 0
	block.radiance_cache_ground_fog[0] = atmosphere.GetGroundFogExtinction()
	block.radiance_cache_ground_fog[1] = atmosphere.precipitation_extinction
	block.radiance_cache_ground_fog[2] = atmosphere.ground_fog_scale_height
	block.radiance_cache_ground_fog_range[0] = atmosphere.GetGroundFogStartAltitude()
	block.radiance_cache_ground_fog_range[1] = atmosphere.GetGroundFogTopAltitude()

	for c = 1, radiance_cache.CASCADES do
		local cascade = state.cascades[c]
		block.radiance_cache_cascades[c - 1][0] = cascade.x
		block.radiance_cache_cascades[c - 1][1] = cascade.y
		block.radiance_cache_cascades[c - 1][2] = cascade.z
		block.radiance_cache_cascades[c - 1][3] = cascade.spacing
		block.radiance_cache_cascade_size[c - 1][0] = cascade.size.x
		block.radiance_cache_cascade_size[c - 1][1] = cascade.size.y
		block.radiance_cache_cascade_size[c - 1][2] = cascade.size.z
		block.radiance_cache_cascade_size[c - 1][3] = cascade.holds
	end

	block.radiance_cache_rotation[0] = state.rotation.x
	block.radiance_cache_rotation[1] = state.rotation.y
	block.radiance_cache_rotation[2] = state.rotation.z
	block.radiance_cache_rotation[3] = state.rotation.w
	block.radiance_cache_max_distance = max_ray_distance:Get()

	for c = 1, radiance_cache.CASCADES do
		block.radiance_cache_cascade_update[c - 1][0] = hysteresis:Get() ^ (
				math.min(state.cascades[c].update_time, 0.1 * radiance_cache.GetUpdateInterval(c)) * 60
			)
		block.radiance_cache_cascade_update[c - 1][1] = (state.sun_fast_until or 0) > state.frame and 1 or 0
	end

	block.radiance_cache_ray_clamp = ray_clamp:Get()
	block.radiance_cache_distance_exponent = radiance_cache.DISTANCE_EXPONENT
	block.radiance_cache_normal_bias = radiance_cache.NORMAL_BIAS
	block.radiance_cache_view_scale = render3d.GetSnappedViewScale()
	block.radiance_cache_view_bias = radiance_cache.VIEW_BIAS
	block.radiance_cache_backface_threshold = radiance_cache.BACKFACE_THRESHOLD
	block.radiance_cache_relocation_distance = relocation:Get() and radiance_cache.RELOCATION_DISTANCE or 0
	block.radiance_cache_max_offset = relocation:Get() and radiance_cache.PROBE_MAX_OFFSET or 0
	block.radiance_cache_sky_intensity = radiance_cache.SKY_INTENSITY
	block.radiance_cache_strength = strength:Get()
	block.radiance_cache_light_radius = light_radius:Get()
	block.radiance_cache_cascade_blend = radiance_cache.CASCADE_BLEND
	block.radiance_cache_contrast_ratio = contrast_ratio:Get()
	block.radiance_cache_change_power = change_power:Get()
	block.radiance_cache_debug_scale = debug_scale:Get()
	block.radiance_cache_debug_probes = DEBUG_PROBES[debug_probes:Get()]
	block.radiance_cache_debug_cascade = debug_cascade:Get()
	block.radiance_cache_debug_scene = DEBUG_SCENE[debug_scene:Get()]
	block.radiance_cache_debug_manual_gamma = render.target:RequiresManualGamma() and 1 or 0
	block.radiance_cache_smooth_blend = smooth_blend:Get() and 1 or 0
	block.radiance_cache_visibility_rays = VISIBILITY_RAYS[visibility_rays:Get()]
	block.radiance_cache_visibility_front_faces_only = visibility_front_faces_only:Get() and 1 or 0
	block.radiance_cache_cascade_count = state.cascade_count
	block.radiance_cache_reset_mask = state.reset_mask
	block.radiance_cache_update_mask = state.update_mask
	block.radiance_cache_rt_ready = state.rt_ready and 1 or 0
	block.radiance_cache_env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
	block.radiance_cache_env_irradiance_tex = self:GetTextureIndex(render3d.GetEnvironmentIrradianceTexture())
	block.radiance_cache_ray_tex = pipeline_texture_index(self, "radiance_cache_shade")
	block.radiance_cache_irradiance_tex = pipeline_texture_index(self, "radiance_cache_irradiance")
	block.radiance_cache_distance_tex = pipeline_texture_index(self, "radiance_cache_distance")
	block.radiance_cache_probe_data_tex = pipeline_texture_index(self, "radiance_cache_probe_data")
	block.radiance_cache_emitter_count = scene_emitters.GetActiveCount()
	block.radiance_cache_frame = state.frame
	block.radiance_cache_uniform_rays = radiance_cache.GetUniformRays()
	block.radiance_cache_guide_tex = pipeline_texture_index(self, "radiance_cache_guide")
	local bent_normal = ambient_occlusion.GetBentNormalTexture()
	block.radiance_cache_bent_normal_tex = bent_normal and self:GetTextureIndex(bent_normal) or -1
	clouds.WriteShadowBlock(self, block)
	import("goluwa/render3d/caustics.lua").WriteHitBlock(self, block)
	return block
end

function radiance_cache.WriteBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	gbuffer_layout.WriteBlock(self, block)
	local lights = render3d.GetLights()
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteLightsBlock(block.lights, lights)
	post_source.WritePreExposureBlock(self, block)
	block.light_transmittance = ray_materials.HasDirectTint() and 1 or 0
	block.medium_gi = ray_materials.HasMedium() and 1 or 0
	return radiance_cache.WriteProbeBlock(self, block)
end

local ray_hit_buffer = nil

function radiance_cache.GetRayHitBuffer()
	if not ray_hit_buffer then
		ray_hit_buffer = render.CreateBuffer{
			byte_size = radiance_cache.GetRayCount() * 16,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "device_local"},
			label = "radiance_cache_ray_hits",
		}
	end

	return ray_hit_buffer
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
	):format(radiance_cache.CASCADES, radiance_cache.CASCADES)
)
local RTParamsPointer = ffi.typeof("$*", RTParams)
local rt_params = {}

function radiance_cache.WriteRTParams()
	local frame = render.GetCurrentFrame()
	local buffer = rt_params[frame]

	if not buffer then
		buffer = render.CreateBuffer{
			byte_size = ffi.sizeof(RTParams),
			buffer_usage = {"uniform_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "radiance_cache_rt_params",
			data = RTParams(),
		}
		rt_params[frame] = buffer
	end

	local state = radiance_cache.GetFrameState()
	local p = ffi.cast(RTParamsPointer, buffer:Map(0, ffi.sizeof(RTParams)))

	for c = 1, radiance_cache.CASCADES do
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
	p.emitter_count = scene_emitters.GetActiveCount()
	p.frame = state.frame
	p.light_radius = light_radius:Get()
	p.update_mask = state.update_mask
	p.uniform_rays = radiance_cache.GetUniformRays()
	p.reset_mask = state.reset_mask
	return buffer
end

local payload_glsl = [[
struct Payload
{
    float hit_t;
    uint instance;
    uint primitive;
    uint sun;
    uint seed;
};
]]
radiance_cache.SCENE_FLAGS_GLSL = radiance_cache.ALPHA_TEST and
	"#define RADIANCE_CACHE_SCENE_FLAGS 0u\n" or
	"#define RADIANCE_CACHE_SCENE_FLAGS gl_RayFlagsOpaqueEXT\n"
local raygen_glsl = [[
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
]] .. radiance_cache.SCENE_FLAGS_GLSL .. radiance_cache.GetDefinesGLSL() .. [[

layout(set = 0, binding = 4) uniform sampler2D guide;
#define RADIANCE_CACHE_GUIDE_FETCH(texel) texelFetch(guide, texel, 0)
]] .. radiance_cache.GetRayDirectionGLSL() .. payload_glsl .. scene_hit.GetGLSL(10) .. scene_emitters.GetDeclarationGLSL(6) .. scene_emitters.GetGLSL() .. [[
layout(set = 0, binding = 0) uniform Params
{
    vec4 cascades[RADIANCE_CACHE_CASCADES];
    vec4 size[RADIANCE_CACHE_CASCADES];
    vec4 rotation;
    vec4 sun_direction;
    float max_ray_distance;
    float tmin;
    int emitter_count;
    uint frame;
    float light_radius;
    int update_mask;
    int uniform_rays;
    int reset_mask;
} params;
layout(set = 0, binding = 1) writeonly buffer Hits
{
    uvec4 hits[];
};
layout(set = 0, binding = 2) uniform accelerationStructureEXT scene;
layout(set = 0, binding = 3) uniform sampler2D probe_data;
layout(location = 0) rayPayloadEXT Payload payload;

void main()
{
    uint ray = gl_LaunchIDEXT.x;
    int probe = int(gl_LaunchIDEXT.y);
    int c = int(gl_LaunchIDEXT.z);

    if ((params.update_mask & (1 << c)) == 0) return;

    payload.seed = ray * 747796405u + uint(probe) * 2891336453u + uint(c) * 277803737u + params.frame * 2654435761u;

    ivec3 n = ivec3(params.size[c].xyz);

    if (probe >= n.x * n.y * n.z) return;

    ivec3 base = ivec3(params.cascades[c].xyz);
    ivec3 slot = ivec3(probe % n.x, (probe / n.x) % n.y, probe / (n.x * n.y));
    ivec3 world = base + RADIANCE_CACHE_WRAP(slot - RADIANCE_CACHE_WRAP(base, n), n);
    ivec2 tile = ivec2(probe % (RADIANCE_CACHE_P * RADIANCE_CACHE_P), probe / (RADIANCE_CACHE_P * RADIANCE_CACHE_P) + RADIANCE_CACHE_P * c);
    vec4 data = texelFetch(probe_data, tile, 0);
    bool current = data.w >= 1.0 && ivec3(round(data.xyz)) == world;

    if (radiance_cache_probe_idle(data.w, current && (params.reset_mask & (1 << c)) == 0, probe, c, params.frame)) return;

    vec3 origin = (current ? data.xyz : vec3(world)) * params.cascades[c].w;
    uint index = uint(probe + RADIANCE_CACHE_P * RADIANCE_CACHE_P * RADIANCE_CACHE_P * c) * uint(RADIANCE_CACHE_RAY_STRIDE) + ray;
    const uint shadow_flags = RADIANCE_CACHE_SCENE_FLAGS | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT;

    if (ray >= RADIANCE_CACHE_RAYS) {
        uvec4 result = uvec4(floatBitsToUint(-1.0), 0u, 0u, 0u);

        if (params.emitter_count > 0) {
            int emitter;
            vec3 point;
            float weight = emitter_pick_sample(index, params.frame, origin, vec3(0.0), params.light_radius * params.cascades[c].w, emitter, point);
            vec3 to_point = point - origin;
            float dist = length(to_point);

            if (weight > 0.0 && dist > (0.04 * params.cascades[0].w)) {
                payload.hit_t = 1.0;
                payload.sun = 0u;
                traceRayEXT(scene, shadow_flags, RADIANCE_CACHE_SCENE_MASK, 0, 0, 0, origin, 0.0, to_point / dist, dist - (0.04 * params.cascades[0].w), 0);

                if (payload.hit_t < 0.0) result = uvec4(floatBitsToUint(weight), uint(emitter), 0u, 0u);
            }
        }

        hits[index] = result;
        return;
    }

    vec3 dir = radiance_cache_ray_direction(ray, uint(params.uniform_rays), params.rotation, tile, radiance_cache_guide_valid(tile, world, c));
    payload.sun = 0u;
    float pull = RADIANCE_CACHE_ORIGIN_PULL * params.cascades[c].w;
    traceRayEXT(scene, RADIANCE_CACHE_SCENE_FLAGS, RADIANCE_CACHE_SCENE_MASK, 0, 0, 0, origin - dir * pull, params.tmin, dir, params.max_ray_distance + pull, 0);
    float hit_t = payload.hit_t >= 0.0 ? max(payload.hit_t - pull, 1e-5) : payload.hit_t;
    uint instance = payload.instance;
    uint primitive = payload.primitive;
    uint sun_visible = 0u;

    if (hit_t >= 0.0 && params.sun_direction.w > 0.0) {
        vec3 hit_normal = -scene_hit_tri(instance, primitive).normal;

        if (dot(dir, hit_normal) > 0.0) hit_normal = -hit_normal;

        vec3 sun_direction = normalize(params.sun_direction.xyz);

        if (dot(hit_normal, sun_direction) > 0.0) {
            payload.hit_t = 1.0;
            payload.sun = 1u;
            traceRayEXT(scene, shadow_flags, RADIANCE_CACHE_SCENE_MASK, 0, 0, 0, origin + dir * hit_t + hit_normal * (0.04 * params.cascades[0].w), 0.0, sun_direction, params.max_ray_distance, 0);

            if (payload.hit_t < 0.0) sun_visible = 1u;
        }
    }

    hits[index] = uvec4(floatBitsToUint(hit_t), instance, primitive, sun_visible);
}
]]
local closesthit_glsl = [[
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. scene_hit.GetQueryGLSL() .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = gl_HitTEXT;
    payload.instance = uint(gl_InstanceCustomIndexEXT);
    payload.primitive = scene_shader_primitive();
}
]]

local function build_anyhit_glsl()
	return [[
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 1, binding = 0) uniform sampler2D textures[]] .. render.GetBindlessDescriptorCapacities().textures .. [[];
#define TEXTURE(idx) textures[nonuniformEXT(max(idx, 0))]
hitAttributeEXT vec2 barycentrics;
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;
]] .. scene_hit.GetGLSL(10) .. ray_materials.GetMaterialDeclarationsGLSL(9) .. ray_materials.GetAlphaTestGLSL() .. medium_common.GetGLSL() .. [[

void main()
{
    uint instance = uint(gl_InstanceCustomIndexEXT);
    uint material = scene_instance_material(instance);

    if (payload.sun != 0u && ray_materials[material].glass != 0) ignoreIntersectionEXT;

    if (payload.sun == 0u && ray_materials[material].refractive != 0) ignoreIntersectionEXT;

    if (payload.sun == 0u && ray_material_has_medium(ray_materials[material])) {
        payload.seed = payload.seed * 747796405u + 2891336453u;
        float scatter = medium_scatter_probability(medium_scattering_at(ray_materials[material].medium_scattering, ray_materials[material].medium_porous_scattering, ray_materials[material].medium_porosity), ray_materials[material].medium_thickness);

        if (float(payload.seed >> 8u) * (1.0 / 16777216.0) >= scatter) ignoreIntersectionEXT;
    }

    if (!ray_alpha_passes(instance, scene_shader_primitive(), barycentrics)) ignoreIntersectionEXT;
}
]]
end

local miss_glsl = [[
#extension GL_EXT_ray_tracing : require
]] .. payload_glsl .. [[
layout(location = 0) rayPayloadInEXT Payload payload;

void main()
{
    payload.hit_t = -1.0;
    payload.instance = 0u;
    payload.primitive = 0u;
}
]]
local rt_pipeline = nil

function radiance_cache.GetRTPipeline()
	if not rt_pipeline then
		local RayTracingPipeline = import("goluwa/render/vulkan/ray_tracing_pipeline.lua")
		local header = "#version 460\n" .. glsl_metadata.build_device_defines(render.GetDevice())
		local stages = {
			{name = "raygeneration", code = header .. raygen_glsl},
			{name = "closesthit", code = header .. closesthit_glsl},
			{name = "miss", code = header .. miss_glsl},
		}
		local bindings = {
			{binding_index = 0, type = "uniform_buffer", stageFlags = "all"},
			{binding_index = 1, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 2, type = "acceleration_structure_khr", stageFlags = "all"},
			{binding_index = 3, type = "combined_image_sampler", stageFlags = "all"},
			{binding_index = 4, type = "combined_image_sampler", stageFlags = "all"},
			{binding_index = 6, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 10, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 11, type = "storage_buffer", stageFlags = "all"},
			{binding_index = 12, type = "storage_buffer", stageFlags = "all"},
		}

		if radiance_cache.ALPHA_TEST then
			stages[#stages + 1] = {name = "anyhit", code = header .. build_anyhit_glsl()}
			bindings[#bindings + 1] = {binding_index = 9, type = "storage_buffer", stageFlags = "all"}
		end

		rt_pipeline = RayTracingPipeline.New(
			render.GetDevice(),
			{
				name = "radiance_cache_rt",
				stages = stages,
				bindless = radiance_cache.ALPHA_TEST,
				max_recursion_depth = 1,
				max_ray_payload_size = 16,
				DescriptorSetCount = render.GetSwapchainImageCount() * 16,
				descriptor_sets = {bindings},
			}
		)
	end

	return rt_pipeline
end

return radiance_cache
