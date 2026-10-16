local ffi = require("ffi")
local atmosphere = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local pvars = import("goluwa/cli/pvars.lua")
local scattering = import("goluwa/render3d/atmosphere_scattering.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local math3d = import("goluwa/render3d/math3d.lua")
atmosphere.stars_texture = nil
atmosphere.environment_map_path = nil
atmosphere.environment_map_texture = nil
atmosphere.environment_map_intensity = 1000
atmosphere.environment_map_version = 0
atmosphere.transmittance_texture = nil
atmosphere.scattering_texture = nil
atmosphere.scattering_source_texture = nil
atmosphere.scattering_ambient_texture = nil
atmosphere.sky_view_textures = atmosphere.sky_view_textures or {}
atmosphere.sky_view_texture_order = atmosphere.sky_view_texture_order or {}
local PI = math.pi
local PLANET_RADIUS = 6371.0
local ATMOSPHERE_RADIUS = 6471.0
local CAMERA_METERS_TO_KM = 0.001
local SEA_LEVEL_EYE_HEIGHT = 1.75 * CAMERA_METERS_TO_KM
atmosphere.SEA_LEVEL_EYE_HEIGHT = SEA_LEVEL_EYE_HEIGHT
local DEFAULT_OCEAN_LEVEL = 0
local CAMERA_TEST_MULTIPLIER = 1
local SKY_VIEW_LUT_WIDTH = 1024
local SKY_VIEW_LUT_HEIGHT = 512
local SKY_VIEW_STEPS = 128
local SKY_VIEW_TEXTURE_CACHE_LIMIT = 16
-- the table is baked at the quantised camera and sun elevation of its key, never at whatever asked for it first: the
-- environment probe at the origin and the view at 600 m shared a 2 km cell, and the one that got there first decided
-- what the sky looked like, the sea level bake has 7 percent more air to look through. The air changes with height, the
-- sideways position only tilts the horizon, so the height is quantised finely and the position coarsely (km)
local SKY_VIEW_POSITION_QUANTIZATION = 5
local SKY_VIEW_HEIGHT_QUANTIZATION = 0.1
-- the sky view table is parametrised by the azimuth from the sun, so it depends on the sun's elevation over the horizon
-- alone. It was keyed by the direction's components in steps of 0.002 (0.12 degrees): the table baked for the first sun in
-- a step served the rest of it, the sky stood still and jumped 3 percent every 0.12 degrees of the sun's motion, and at a
-- sunset, where it changes fastest, the staircase was a visible flicker. 0.005 degrees is under 0.3 percent there
local SKY_VIEW_ELEVATION_QUANTIZATION = math.rad(0.005)
local SKY_VIEW_ILLUMINANCE_QUANTIZATION = 1000
local RAYLEIGH_SCALE_HEIGHT = 8.0
local OZONE_CENTER_HEIGHT = 25.0
local OZONE_WIDTH = 15.0
local RAYLEIGH_BETA = Vec3(0.0058, 0.0135, 0.0331)
-- aerosol: Angstrom exponent, single scattering albedo and asymmetry of clear continental air. The extinction per
-- channel is at the wavelengths the rgb Rayleigh and ozone constants stand for. How much of it there is comes from
-- atmosphere.SetAerosolVisibility
atmosphere.DEFAULT_AEROSOL = {angstrom = 1.3, albedo = 0.95, g = 0.7, scale_height = 1.2}
-- angstrom, albedo, g and scale height: the shader reads them as one vec4 in this order
local aerosol_shape = {
	atmosphere.DEFAULT_AEROSOL.angstrom,
	atmosphere.DEFAULT_AEROSOL.albedo,
	atmosphere.DEFAULT_AEROSOL.g,
	atmosphere.DEFAULT_AEROSOL.scale_height,
}
local RAYLEIGH_GREEN_EXTINCTION = 0.0135
-- Koschmieder: the distance at which contrast falls to 2 percent, times the extinction coefficient
local VISIBILITY_OPTICAL_DEPTH = -math.log(0.02)
local AEROSOL_SPECTRUM = Vec3(0, 1, 0)
local AEROSOL_ALBEDO, AEROSOL_G, AEROSOL_HEIGHT = 0, 0, 0
local MIE_BETA_EXT = Vec3(0, 0, 0)
local MIE_BETA = Vec3(0, 0, 0)
local aerosol_extinction = 0
local OZONE_BETA_ABS = Vec3(0.00065, 0.00188, 0.000085)
-- the luminous solar constant: 127.5 klux (Gueymard 2005, the ASTM spectrum and 1366 W/m2), 127.0 for today's 1361 W/m2
atmosphere.DEFAULT_SUN_ILLUMINANCE = 127000
local DEFAULT_SUN_ILLUMINANCE = atmosphere.DEFAULT_SUN_ILLUMINANCE
atmosphere.SUN_ANGULAR_RADIUS = 0.00465
-- the colour of the sunlight above the atmosphere as linear sRGB with a luminance of 1, a 5778 K blackbody (chromaticity
-- 0.3263 0.3359), warmer than the D65 white of the display. The direct light, the sky, the fog and the sun disc all
-- start from it, so a white balance has one illuminant to undo.
atmosphere.SUN_COLOR = Vec3(1.1093, 0.9763, 0.9133)
atmosphere.CLOUD_RADIANCE_SCALE = 1 / 16
local DEBUG_DISABLE_GROUND_FOG = false
local GROUND_FOG_SCALE_HEIGHT = 0.28
local GROUND_FOG_TOP_HEIGHT = 1.1
atmosphere.GROUND_FOG_SCALE_HEIGHT = GROUND_FOG_SCALE_HEIGHT
atmosphere.GROUND_FOG_TOP_HEIGHT = GROUND_FOG_TOP_HEIGHT
atmosphere.sun_illuminance = atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE
pvars.StartGroup("Environment", "Fog", {store = false, prefix = "fog_"})
local fog_ray_strength = pvars.Setup2{
	key = "fog_ray_strength",
	default = 1,
	min = 0,
	help = "scales the sunlight the fog scatters toward the viewer, so light shafts get stronger without more fog",
}
pvars.EndGroup()
atmosphere.precipitation_extinction = 0
atmosphere.wind = Vec3(0, 0, 0)
atmosphere.temperature = 15
atmosphere.cloud_sky_texture = nil
atmosphere.cloud_transmittance = 1
atmosphere.sky = nil
atmosphere.enabled = true

local function normalize_components(x, y, z)
	local length = math.sqrt(x * x + y * y + z * z)

	if length <= 0 then return 0, 1, 0 end

	return x / length, y / length, z / length
end

local function get_shader_camera_position(cam_pos)
	cam_pos = cam_pos or Vec3(0, 0, 0)
	return {
		x = cam_pos.x * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER,
		y = PLANET_RADIUS + SEA_LEVEL_EYE_HEIGHT + cam_pos.y * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER,
		z = cam_pos.z * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER,
	}
end

local function rayleighDensity(height)
	return math.exp(-math.max(height, 0) / RAYLEIGH_SCALE_HEIGHT)
end

local function mieDensity(height)
	local boundary_aerosols = math.exp(-math.max(height, 0) / aerosol_shape[4])
	local upper_haze = 0.07 * math.exp(-math.max(height, 0) / 8.0)
	return boundary_aerosols + upper_haze
end

local function ozoneDensity(height)
	return math.max(0, 1.0 - math.abs(height - OZONE_CENTER_HEIGHT) / OZONE_WIDTH)
end

local function get_normalized_sun_direction(sun_dir)
	sun_dir = sun_dir or Vec3(0, 1, 0)
	local x, y, z = normalize_components(sun_dir.x, sun_dir.y, sun_dir.z)
	return {x = x, y = y, z = z}
end

local function quantize(value, step)
	return math.floor(value / step + 0.5) * step
end

local function get_sky_view_texture_key(cam_pos, sun_dir)
	local camera = get_shader_camera_position(cam_pos)
	local sun = get_normalized_sun_direction(sun_dir)
	local sun_illuminance = atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE
	local length = math.sqrt(camera.x * camera.x + camera.y * camera.y + camera.z * camera.z)
	local elevation = math.asin(math.max(-1, math.min(1, (sun.x * camera.x + sun.y * camera.y + sun.z * camera.z) / length)))
	local x = quantize(camera.x, SKY_VIEW_POSITION_QUANTIZATION)
	local y = quantize(camera.y, SKY_VIEW_HEIGHT_QUANTIZATION)
	local z = quantize(camera.z, SKY_VIEW_POSITION_QUANTIZATION)
	elevation = quantize(elevation, SKY_VIEW_ELEVATION_QUANTIZATION)
	return string.format("%.1f:%.1f:%.1f|%.6f|%.3f", x, y, z, elevation, quantize(sun_illuminance, SKY_VIEW_ILLUMINANCE_QUANTIZATION)),
	x,
	y,
	z,
	elevation
end

local atmosphere_shared_glsl = glsl_common.GetConstantsGLSL() .. glsl_common.GetRaySphereGLSL() .. glsl_common.GetPhaseGLSL() .. [[
	const float PLANET_RADIUS = 6371.0;
	const float ATMOSPHERE_RADIUS = 6471.0;
	const float RAYLEIGH_SCALE_HEIGHT = 8.0;
	const float GROUND_FOG_ENABLED = ]] .. (
		DEBUG_DISABLE_GROUND_FOG and
		"0.0" or
		"1.0"
	) .. [[;
	const float GROUND_FOG_SCALE_HEIGHT = ]] .. GROUND_FOG_SCALE_HEIGHT .. [[;
	const float GROUND_FOG_TOP_HEIGHT = ]] .. GROUND_FOG_TOP_HEIGHT .. [[;
	const float GROUND_FOG_TOP_SOFTNESS = 0.3;
	const float GROUND_FOG_MIE_G = 0.6;
	// the share of the sun's energy a fog layer takes out of the beam that ends up as the mean radiance inside it: the rest
	// leaves through the top, and the ground takes some
	// The fog's light is fitted to a path tracer (a grey fog, g 0.6, albedo 1) over visibilities of 300 m to 20 km and suns
	// of 25 and 60 degrees, 9.6 percent rms (test/harnesses/fog/sky.lua, the offline fit is described in docs). A thin fog
	// scatters the sky's mean radiance; a thick one is lit by the irradiance that enters its top and scatters it again
	const float GROUND_FOG_IRRADIANCE_FRACTION = 0.33;
	const float GROUND_FOG_IRRADIANCE_THICKNESS = 1.685;
	const int GROUND_FOG_OCTAVES = 3;
	const float GROUND_FOG_OCTAVE_SCATTER = 0.95;
	const float GROUND_FOG_OCTAVE_EXTINCTION = 0.544;
	const float GROUND_FOG_OCTAVE_PHASE = 0.669;
	const float GROUND_FOG_OCTAVE_THICKNESS = 0.929;
	// the aerosol's scattering and extinction per km at sea level, the pass provides the extinction at 550 nm
	// ATMOSPHERE_AEROSOL_SHAPE is (angstrom exponent, single scattering albedo, asymmetry, scale height in km)
	#define AEROSOL_SPECTRUM vec3(pow(680.0 / 550.0, -ATMOSPHERE_AEROSOL_SHAPE.x), 1.0, pow(440.0 / 550.0, -ATMOSPHERE_AEROSOL_SHAPE.x))
	#define AEROSOL_ALBEDO (ATMOSPHERE_AEROSOL_SHAPE.y)
	#define MIE_BETA_EXT (ATMOSPHERE_AEROSOL_EXTINCTION * AEROSOL_SPECTRUM)
	#define MIE_BETA (MIE_BETA_EXT * AEROSOL_ALBEDO)
	#define MIE_G (ATMOSPHERE_AEROSOL_SHAPE.z)
	#define MIE_SCALE_HEIGHT (ATMOSPHERE_AEROSOL_SHAPE.w)
	const float OZONE_CENTER_HEIGHT = 25.0;
	const float OZONE_WIDTH = 15.0;
	const vec3 RAYLEIGH_BETA = vec3(0.0058, 0.0135, 0.0331);
	const vec3 OZONE_BETA_ABS = vec3(0.00065, 0.00188, 0.000085);
	const vec3 GROUND_ALBEDO = vec3(0.30, 0.27, 0.22);
	const vec3 SUN_COLOR = vec3(]] .. string.format("%.4f, %.4f, %.4f", atmosphere.SUN_COLOR.x, atmosphere.SUN_COLOR.y, atmosphere.SUN_COLOR.z) .. [[);

	#ifndef ATMOSPHERE_SUN_ILLUMINANCE
	#define ATMOSPHERE_SUN_ILLUMINANCE ]] .. string.format("%.1f", DEFAULT_SUN_ILLUMINANCE) .. [[

	#endif
	#ifndef ATMOSPHERE_FOG_COLOR
	#define ATMOSPHERE_FOG_COLOR vec4(0.0)
	#endif
	#ifndef ATMOSPHERE_ENABLED
	#define ATMOSPHERE_ENABLED 1
	#endif
	#ifndef ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX
	#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_SCATTERING_TEXTURE_INDEX
	#define ATMOSPHERE_SCATTERING_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX
	#define ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_SCATTERING_AMBIENT_TEXTURE_INDEX
	#define ATMOSPHERE_SCATTERING_AMBIENT_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX
	#define ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_STARS_TEXTURE_INDEX
	#define ATMOSPHERE_STARS_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX
	#define ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_ENVIRONMENT_INTENSITY
	#define ATMOSPHERE_ENVIRONMENT_INTENSITY 1.0
	#endif
	#ifndef ATMOSPHERE_SKY_SUN_DIRECTION
	#define ATMOSPHERE_SKY_SUN_DIRECTION vec3(0.0, 1.0, 0.0)
	#endif
	#ifndef ATMOSPHERE_SUN_DISC_ILLUMINANCE
	#define ATMOSPHERE_SUN_DISC_ILLUMINANCE ATMOSPHERE_SUN_ILLUMINANCE
	#endif
	#ifndef ATMOSPHERE_MOON_DIRECTION
	#define ATMOSPHERE_MOON_DIRECTION vec3(0.0, -1.0, 0.0)
	#endif
	#ifndef ATMOSPHERE_MOON_SKY_SCALE
	#define ATMOSPHERE_MOON_SKY_SCALE 0.0
	#endif
	#ifndef ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX
	#define ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_MOON_ANGULAR_RADIUS
	#define ATMOSPHERE_MOON_ANGULAR_RADIUS 0.0
	#endif
	#ifndef ATMOSPHERE_CELESTIAL_X
	#define ATMOSPHERE_CELESTIAL_X vec3(1.0, 0.0, 0.0)
	#endif
	#ifndef ATMOSPHERE_CELESTIAL_Y
	#define ATMOSPHERE_CELESTIAL_Y vec3(0.0, 1.0, 0.0)
	#endif
	#ifndef ATMOSPHERE_CELESTIAL_Z
	#define ATMOSPHERE_CELESTIAL_Z vec3(0.0, 0.0, 1.0)
	#endif
	#ifndef ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX
	#define ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX -1
	#endif
	#ifndef ATMOSPHERE_CLOUD_TRANSMITTANCE
	#define ATMOSPHERE_CLOUD_TRANSMITTANCE 1.0
	#endif
	// what the clouds let through of the sun to a point (km, planet centered). a pass that has the
	// clouds' shadow map defines it to shadow the air, which gives crepuscular rays
	#ifndef ATMOSPHERE_CLOUD_SHADOW
	#define ATMOSPHERE_CLOUD_SHADOW(point) 1.0
	#endif
	// where in each step integrate_scattering samples, a pass can jitter it against banding
	#ifndef ATMOSPHERE_SCATTER_JITTER
	#define ATMOSPHERE_SCATTER_JITTER 0.5
	#endif
	// the ground fog's extinction per km at the ground, and the rain and snow's, which does not thin out with height
	#ifndef ATMOSPHERE_GROUND_FOG_EXTINCTION
	#define ATMOSPHERE_GROUND_FOG_EXTINCTION 0.0
	#endif
	#ifndef ATMOSPHERE_PRECIPITATION_EXTINCTION
	#define ATMOSPHERE_PRECIPITATION_EXTINCTION 0.0
	#endif
	#ifndef ATMOSPHERE_FOG_RAY_STRENGTH
	#define ATMOSPHERE_FOG_RAY_STRENGTH ]] .. string.format("%.6f\n", fog_ray_strength:Get()) .. [[
	#endif

	float rayleigh_density(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		return exp(-max(altitude, 0.0) / RAYLEIGH_SCALE_HEIGHT);
	}

	float mie_density(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		float boundary_aerosols = exp(-max(altitude, 0.0) / MIE_SCALE_HEIGHT);
		float upper_haze = 0.07 * exp(-max(altitude, 0.0) / 8.0);
		return boundary_aerosols + upper_haze;
	}

	float ozone_density(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		return max(0.0, 1.0 - abs(altitude - OZONE_CENTER_HEIGHT) / OZONE_WIDTH);
	}

	// extinction per km of the ground fog and the precipitation
	float ground_fog_extinction(vec3 point) {
		if (GROUND_FOG_ENABLED < 0.5) return 0.0;

		float altitude = max(length(point) - PLANET_RADIUS, 0.0);
		float height_falloff = exp(-altitude / GROUND_FOG_SCALE_HEIGHT);
		float top_fade = 1.0 - smoothstep(
			max(GROUND_FOG_TOP_HEIGHT - GROUND_FOG_TOP_SOFTNESS, 0.0),
			GROUND_FOG_TOP_HEIGHT,
			altitude
		);
		return (ATMOSPHERE_GROUND_FOG_EXTINCTION * height_falloff + ATMOSPHERE_PRECIPITATION_EXTINCTION) * top_fade;
	}

	float mie_phase(float mu) {
		float gg = MIE_G * MIE_G;
		float num = 3.0 * (1.0 - gg) * (1.0 + mu * mu);
		float den = (8.0 * PI) * (2.0 + gg) * pow(max(1.0 + gg - 2.0 * MIE_G * mu, 1e-4), 1.5);
		return num / den;
	}

	// the tables' height axis is the square root of the altitude, 64 rows over 100 km would put the first one 0.8 km up,
	// above most of the aerosol, and a viewer at the ground would see the air of that height
	float get_lut_radius(float v) {
		return PLANET_RADIUS + (ATMOSPHERE_RADIUS - PLANET_RADIUS) * v * v;
	}

	vec2 get_transmittance_lut_uv(vec3 sample_point, vec3 light_dir) {
		vec3 up = normalize(sample_point);
		float mu = dot(up, light_dir);
		float radius = length(sample_point);
		float u = mu * 0.5 + 0.5;
		float v = sqrt(clamp((radius - PLANET_RADIUS) / max(ATMOSPHERE_RADIUS - PLANET_RADIUS, 1e-5), 0.0, 1.0));
		return vec2(u, v);
	}

	vec3 sample_transmittance_lut(vec3 sample_point, vec3 light_dir) {
		if (ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX == -1) return vec3(1.0);
		return texture(TEXTURE(ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX), get_transmittance_lut_uv(sample_point, light_dir)).rgb;
	}

	]] .. scattering.LOOKUP_GLSL .. [[

	vec3 compute_view_tau(float rayleigh_od, float mie_od, float ozone_od) {
		return RAYLEIGH_BETA * rayleigh_od + MIE_BETA_EXT * mie_od + OZONE_BETA_ABS * ozone_od;
	}

	// How far along a segment the s-th part of a march is (s from 0 to 1). The air thins out exponentially, so near the
	// viewer the steps want to be short and on a path of a thousand km long; ATMOSPHERE_LOG_MARCH spaces them
	// geometrically from 20 m out so that every scale gets the same number of steps (the quadratic spacing put 10 of 128
	// steps in the first 10 km, and in a 6 km haze the near field is 1.5 km), the default is quadratic
	float get_march_distance(float s, float segment) {
		#ifdef ATMOSPHERE_LOG_MARCH
		float base = clamp(segment / 0.02, 2.0, 1e6);
		return segment * (exp2(log2(base) * s) - 1.0) / (base - 1.0);
		#else
		return segment * s * s;
		#endif
	}

	// Single scattering with the real phase functions marched from t_near to t_far along the ray, plus the light that
	// scattered more than once from the table (the light that arrives along the ray from its end onward is the table at
	// the start less what is left of the table at the end). Returns radiance and writes the view transmittance of the segment.
	vec3 integrate_scattering(vec3 ray_origin, vec3 ray_dir, float t_near, float t_far, vec3 sun_dir, int steps, vec2 single_scatter_visibility, float multi_scatter_visibility, out vec3 view_transmittance) {
		float segment = t_far - t_near;
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		vec3 total = vec3(0.0);
		float mu = dot(ray_dir, sun_dir);
		vec3 phase_r = RAYLEIGH_BETA * (phase_rayleigh(mu) * single_scatter_visibility.x);
		vec3 phase_m = MIE_BETA * (mie_phase(mu) * single_scatter_visibility.y);

		for (int i = 0; i < steps; i++) {
			float s0 = float(i) / float(steps);
			float s1 = float(i + 1) / float(steps);
			float t0 = t_near + get_march_distance(s0, segment);
			float step_size = get_march_distance(s1, segment) - get_march_distance(s0, segment);
			float t = t0 + ATMOSPHERE_SCATTER_JITTER * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			float density_r = rayleigh_density(sample_point);
			float density_m = mie_density(sample_point);
			float density_o = ozone_density(sample_point);
			rayleigh_od += density_r * step_size;
			mie_od += density_m * step_size;
			ozone_od += density_o * step_size;
			vec3 view_t = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
			vec3 sun_t = sample_transmittance_lut(sample_point, sun_dir) * ATMOSPHERE_CLOUD_SHADOW(sample_point);
			vec3 single = (phase_r * density_r + phase_m * density_m) * sun_t;
			total += single * view_t * step_size;
		}

		view_transmittance = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
		vec3 multi = vec3(0.0);

		if (ATMOSPHERE_SCATTERING_TEXTURE_INDEX != -1) {
			vec3 start_point = ray_origin + ray_dir * t_near;
			float r_start = length(start_point);
			vec3 up_start = start_point / r_start;
			multi = sc_lookup(ATMOSPHERE_SCATTERING_TEXTURE_INDEX, r_start, dot(up_start, ray_dir), dot(up_start, sun_dir), mu);
			vec3 end_point = ray_origin + ray_dir * t_far;
			float r_end = length(end_point);
			vec3 up_end = end_point / r_end;
			multi -= view_transmittance * sc_lookup(ATMOSPHERE_SCATTERING_TEXTURE_INDEX, r_end, dot(up_end, ray_dir), dot(up_end, sun_dir), mu);
		}

		return (total + max(multi, vec3(0.0)) * multi_scatter_visibility) * ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR;
	}

	// Clips the ray to the atmosphere and the planet. Returns false when the
	// ray never enters the atmosphere.
	bool get_atmosphere_segment(vec3 ray_origin, vec3 ray_dir, out float t_near, out float t_far, out bool hits_ground) {
		vec2 atmosphere_hit = ray_sphere_intersect(ray_origin, ray_dir, ATMOSPHERE_RADIUS);
		hits_ground = false;

		if (atmosphere_hit.y <= 0.0) return false;

		t_near = max(atmosphere_hit.x, 0.0);
		t_far = atmosphere_hit.y;
		vec2 ground_hit = ray_sphere_intersect(ray_origin, ray_dir, PLANET_RADIUS);

		if (ground_hit.x > t_near) {
			t_far = min(t_far, ground_hit.x);
			hits_ground = true;
		}

		return t_far - t_near > 1e-5;
	}

	vec3 get_sky_view_forward(vec3 up, vec3 sun_dir) {
		vec3 projected_sun = sun_dir - up * dot(sun_dir, up);
		float projected_length = length(projected_sun);

		if (projected_length < 1e-4) {
			vec3 fallback_axis = abs(up.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			projected_sun = normalize(cross(cross(up, fallback_axis), up));
		} else {
			projected_sun /= projected_length;
		}

		return projected_sun;
	}

	// The sky has no ground. Whatever is below the horizon is geometry that writes depth, so
	// empty pixels there continue the haze of the horizon, from any height, instead of showing
	// a floor at the planet's height. Returns the direction the sky is looked up along.
	vec3 get_sky_lookup_dir(vec3 dir, vec3 ray_origin, vec3 sun_dir) {
		vec3 up = normalize(ray_origin);
		float horizon_elevation = -acos(clamp(PLANET_RADIUS / length(ray_origin), 0.0, 1.0)) + 0.0005;

		if (asin(clamp(dot(dir, up), -1.0, 1.0)) >= horizon_elevation) return dir;

		vec3 horizontal = dir - up * dot(dir, up);
		horizontal = length(horizontal) > 1e-4 ? normalize(horizontal) : get_sky_view_forward(up, sun_dir);
		return normalize(horizontal * cos(horizon_elevation) + up * sin(horizon_elevation));
	}

	vec3 get_atmosphere_camera_origin(vec3 cam_pos) {
		vec3 world_camera_offset = cam_pos * ]] .. string.format("%.17g", CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER) .. [[;
		return vec3(
			world_camera_offset.x,
			PLANET_RADIUS + ]] .. string.format("%.17g", SEA_LEVEL_EYE_HEIGHT) .. [[ + world_camera_offset.y,
			world_camera_offset.z
		);
	}

]] .. glsl_common.GetSunHorizonVisibilityGLSL() .. [[
]]

-- The sunlight through the air, folded with the sun's spectrum and the eye: the same air (Rayleigh, aerosol, ozone) at
-- 41 wavelengths instead of three. The three channel coefficients of the sky tables are tuned to the scattered light and
-- give a direct beam that was 5 percent too bright at 60 degrees, 27 at 10 and twice as bright at 1 degree, and too red.
-- weights[c] are the 5778 K blackbody times the CIE 1931 observer (Wyman, Sloan and Shirley 2013) in linear sRGB channel c,
-- normalised to add up to 1
local SPECTRUM = {wavelengths = {}, rayleigh = {}, ozone = {}, aerosol = {}, weights = {{}, {}, {}}}

do
	local function lobe(l, mu, s1, s2)
		local t = (l - mu) / (l < mu and s1 or s2)
		return math.exp(-0.5 * t * t)
	end

	local sums = {0, 0, 0}

	for l = 380, 780, 10 do
		local i = #SPECTRUM.wavelengths + 1
		local um = l / 1000
		SPECTRUM.wavelengths[i] = l
		-- Bodhaine's Rayleigh optical depth of the whole atmosphere, per scale height
		SPECTRUM.rayleigh[i] = 0.008569 * um ^ -4 * (1 + 0.0113 * um ^ -2 + 0.00013 * um ^ -4) / RAYLEIGH_SCALE_HEIGHT
		-- the Chappuis band of 300 DU of ozone, a gaussian fit, spread over the layer's width
		SPECTRUM.ozone[i] = 5.1e-21 * math.exp(-0.5 * ((l - 603) / 58) ^ 2) * 8.06e18 / OZONE_WIDTH
		SPECTRUM.aerosol[i] = 1
		local x = 1.056 * lobe(l, 599.8, 37.9, 31.0) + 0.362 * lobe(l, 442.0, 16.0, 26.7) - 0.065 * lobe(l, 501.1, 20.4, 26.2)
		local y = 0.821 * lobe(l, 568.8, 46.9, 40.5) + 0.286 * lobe(l, 530.9, 16.3, 31.1)
		local z = 1.217 * lobe(l, 437.0, 11.8, 36.0) + 0.681 * lobe(l, 459.0, 26.0, 13.8)
		local sun = 1 / ((l * 1e-9) ^ 5 * (math.exp(1.4388e-2 / (l * 1e-9 * 5778)) - 1))
		local rgb = {
			3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
			-0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
			0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
		}

		for c = 1, 3 do
			SPECTRUM.weights[c][i] = sun * rgb[c]
			sums[c] = sums[c] + sun * rgb[c]
		end
	end

	for c = 1, 3 do
		for i = 1, #SPECTRUM.wavelengths do
			SPECTRUM.weights[c][i] = SPECTRUM.weights[c][i] / sums[c]
		end
	end
end

local function glsl_array(name, values)
	local parts = {}

	for i, v in ipairs(values) do
		parts[i] = string.format("%.9g", v)
	end

	return string.format("const float %s[%d] = float[%d](%s);\n", name, #values, #values, table.concat(parts, ", "))
end

local function build_atmosphere_shader_prelude(extra, prefix)
	return (prefix or "") .. atmosphere_shared_glsl .. "\n" .. extra
end

local transmittance_glsl = build_atmosphere_shader_prelude([[
	const int TRANSMITTANCE_STEPS = 40;
	const int SPECTRAL_COUNT = ]] .. #SPECTRUM.wavelengths .. [[;
	const int SPECTRAL_FIRST_WAVELENGTH = ]] .. SPECTRUM.wavelengths[1] .. [[;
	const int SPECTRAL_STEP = ]] .. (SPECTRUM.wavelengths[2] - SPECTRUM.wavelengths[1]) .. [[;

	]] .. glsl_array("SPECTRAL_RAYLEIGH", SPECTRUM.rayleigh) .. glsl_array("SPECTRAL_OZONE", SPECTRUM.ozone) .. glsl_array("SPECTRAL_WEIGHT_R", SPECTRUM.weights[1]) .. glsl_array("SPECTRAL_WEIGHT_G", SPECTRUM.weights[2]) .. glsl_array("SPECTRAL_WEIGHT_B", SPECTRUM.weights[3]) .. [[

	vec2 ray_sphere_intersect_normalized(vec3 ray_origin, vec3 ray_dir, float sphere_radius) {
		vec3 oc = ray_origin / sphere_radius;
		float b = dot(oc, ray_dir);
		float c = dot(oc, oc) - 1.0;
		float discriminant = b * b - c;

		if (discriminant < -1e-6) {
			return vec2(-1.0, -1.0);
		}

		float sqrt_d = sqrt(max(discriminant, 0.0));
		return vec2((-b - sqrt_d) * sphere_radius, (-b + sqrt_d) * sphere_radius);
	}

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float mu = mix(-1.0, 1.0, uv.x);
		float radius = get_lut_radius(uv.y);
		vec3 ray_origin = vec3(0.0, radius, 0.0);
		float sin_theta = sqrt(max(1.0 - mu * mu, 0.0));
		vec3 ray_dir = normalize(vec3(sin_theta, mu, 0.0));
		vec2 atmosphere_hit = ray_sphere_intersect_normalized(ray_origin, ray_dir, ATMOSPHERE_RADIUS);
		vec2 ground_hit = ray_sphere_intersect_normalized(ray_origin, ray_dir, PLANET_RADIUS);
		float ray_length = atmosphere_hit.y;

		if (ray_length <= 0.0) return vec4(1.0);
		if (ground_hit.x > 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;

		// the aerosol layer is 1.2 km deep and the path up to 100 km long, so the samples crowd towards the viewer
		for (int i = 0; i < TRANSMITTANCE_STEPS; i++) {
			float u0 = float(i) / float(TRANSMITTANCE_STEPS);
			float u1 = float(i + 1) / float(TRANSMITTANCE_STEPS);
			float step_size = ray_length * (u1 * u1 - u0 * u0);
			float u = 0.5 * (u0 + u1);
			float t = ray_length * u * u;
			vec3 sample_point = ray_origin + ray_dir * t;
			rayleigh_od += rayleigh_density(sample_point) * step_size;
			mie_od += mie_density(sample_point) * step_size;
			ozone_od += ozone_density(sample_point) * step_size;
		}

		vec3 transmitted = vec3(0.0);

		for (int i = 0; i < SPECTRAL_COUNT; i++) {
			float t = exp(-(SPECTRAL_RAYLEIGH[i] * rayleigh_od + ATMOSPHERE_AEROSOL_EXTINCTION * pow((float(SPECTRAL_FIRST_WAVELENGTH) + float(SPECTRAL_STEP) * float(i)) / 550.0, -ATMOSPHERE_AEROSOL_SHAPE.x) * mie_od + SPECTRAL_OZONE[i] * ozone_od));
			transmitted += vec3(SPECTRAL_WEIGHT_R[i], SPECTRAL_WEIGHT_G[i], SPECTRAL_WEIGHT_B[i]) * t;
		}

		return vec4(max(transmitted, vec3(0.0)), 1.0);
	}
]], "#define ATMOSPHERE_AEROSOL_EXTINCTION aerosol.extinction\n#define ATMOSPHERE_AEROSOL_SHAPE aerosol.shape\n")
-- what the lut shaders that have no uniform block get the aerosol from
local AerosolConstants = ffi.typeof([[struct {
	float shape[4];
	float extinction;
}]])
local AEROSOL_DECLARATIONS = [[
	layout(push_constant) uniform AerosolConstants {
		vec4 shape;
		float extinction;
	} aerosol;
]]

local function get_aerosol_push_constants()
	return {
		size = ffi.sizeof(AerosolConstants),
		data = AerosolConstants({aerosol_shape, aerosol_extinction}),
	}
end

local SkyViewConstants = ffi.typeof([[struct {
	float camera_position[3];
	float sun_illuminance;
	float sun_direction[3];
	float aerosol_extinction;
	float aerosol_shape[4];
	int transmittance_index;
	int scattering_index;
}]])
local SKY_VIEW_DECLARATIONS = [[
	layout(push_constant) uniform SkyViewConstants {
		vec3 camera_position;
		float sun_illuminance;
		vec3 sun_direction;
		float aerosol_extinction;
		vec4 aerosol_shape;
		int transmittance_index;
		int scattering_index;
	} sky_view;
]]
local sky_view_glsl = build_atmosphere_shader_prelude(
	[[
	const int SKY_VIEW_STEPS = ]] .. SKY_VIEW_STEPS .. [[;

	vec3 get_sky_view_ray_dir(vec2 uv, vec3 up) {
		vec3 forward = get_sky_view_forward(up, sky_view.sun_direction);
		vec3 right = normalize(cross(forward, up));
		float azimuth = (uv.x * 2.0 - 1.0) * PI;
		float elevation = (uv.y * uv.y - 0.5) * PI;
		float cos_elevation = cos(elevation);
		vec3 horizontal = cos(azimuth) * forward + sin(azimuth) * right;
		return normalize(horizontal * cos_elevation + up * sin(elevation));
	}

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		vec3 ray_origin = sky_view.camera_position;
		vec3 up = normalize(ray_origin);
		vec3 ray_dir = get_sky_lookup_dir(get_sky_view_ray_dir(uv, up), ray_origin, sky_view.sun_direction);
		float t_near;
		float t_far;
		bool hits_ground;

		if (!get_atmosphere_segment(ray_origin, ray_dir, t_near, t_far, hits_ground)) return vec4(0.0, 0.0, 0.0, 1.0);

		vec3 view_transmittance;
		vec3 scattered_light = integrate_scattering(ray_origin, ray_dir, t_near, t_far, sky_view.sun_direction, SKY_VIEW_STEPS, vec2(1.0), 1.0, view_transmittance);
		return vec4(scattered_light, dot(view_transmittance, vec3(1.0 / 3.0)));
	}
]],
	"#define ATMOSPHERE_LOG_MARCH 1\n#define ATMOSPHERE_SUN_ILLUMINANCE sky_view.sun_illuminance\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX sky_view.transmittance_index\n" .. "#define ATMOSPHERE_SCATTERING_TEXTURE_INDEX sky_view.scattering_index\n" .. "#define ATMOSPHERE_AEROSOL_EXTINCTION sky_view.aerosol_extinction\n" .. "#define ATMOSPHERE_AEROSOL_SHAPE sky_view.aerosol_shape\n"
)
local atmosphere_glsl = build_atmosphere_shader_prelude(
	[[
	const int PRIMARY_STEPS = 32;
	const int AERIAL_PERSPECTIVE_STEPS = 32;
	const float CAMERA_METERS_TO_KM = ]] .. CAMERA_METERS_TO_KM .. [[;
	const float CAMERA_TEST_MULTIPLIER = ]] .. CAMERA_TEST_MULTIPLIER .. [[;
	const float SEA_LEVEL_EYE_HEIGHT = ]] .. SEA_LEVEL_EYE_HEIGHT .. [[;
	const float SUN_ANGULAR_RADIUS = ]] .. atmosphere.SUN_ANGULAR_RADIUS .. [[;
	const float CLOUD_RADIANCE_SCALE = ]] .. string.format("%.8f", atmosphere.CLOUD_RADIANCE_SCALE) .. [[;

	// Ray marched sky for when no sky view LUT is bound. rgb = in-scattered
	// radiance, a = mean view transmittance up to the ground or the edge of
	// the atmosphere.
	vec4 get_atmosphere_from_origin(vec3 ray_origin, vec3 dir, vec3 sun_dir) {
		float t_near;
		float t_far;
		bool hits_ground;

		if (!get_atmosphere_segment(ray_origin, dir, t_near, t_far, hits_ground)) return vec4(0.0, 0.0, 0.0, 1.0);

		vec3 view_transmittance;
		vec3 scattered_light = integrate_scattering(ray_origin, dir, t_near, t_far, sun_dir, PRIMARY_STEPS, vec2(1.0), 1.0, view_transmittance);
		return vec4(scattered_light, dot(view_transmittance, vec3(1.0 / 3.0)));
	}

	vec4 get_atmosphere(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		return get_atmosphere_from_origin(get_atmosphere_camera_origin(cam_pos), normalize(dir), sun_dir);
	}

	vec2 get_sky_view_lut_uv(vec3 dir, vec3 sun_dir, vec3 ray_origin) {
		vec3 up = normalize(ray_origin);
		vec3 forward = get_sky_view_forward(up, sun_dir);
		vec3 right = normalize(cross(forward, up));
		float elevation = asin(clamp(dot(dir, up), -1.0, 1.0));
		float encoded_v = clamp(elevation / PI + 0.5, 0.0, 1.0);
		vec3 horizontal = dir - up * dot(dir, up);
		float horizontal_length = length(horizontal);

		if (horizontal_length > 1e-4) {
			horizontal /= horizontal_length;
		} else {
			horizontal = forward;
		}

		float azimuth = atan(dot(horizontal, right), dot(horizontal, forward));
		float u = azimuth / (2.0 * PI) + 0.5;
		float v = sqrt(encoded_v);
		return vec2(u, clamp(v, 0.0, 1.0));
	}

	// the cloud sky dome is an equirect around the camera, denser toward the horizon
	vec2 get_cloud_sky_uv(vec3 dir) {
		float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
		float e = asin(clamp(dir.y, -1.0, 1.0)) / (0.5 * PI);
		return vec2(u, 0.5 + 0.5 * sign(e) * sqrt(abs(e)));
	}

	// the clouds in front of the sky seen along dir: what they let through of it, and the light they
	// and the air in front of them add
	vec3 apply_sky_clouds(vec3 sky, vec3 dir) {
		if (ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX == -1) return sky;

		vec4 clouds = textureLod(TEXTURE(ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX), get_cloud_sky_uv(dir), 0.0);
		return sky * clouds.a + clouds.rgb / CLOUD_RADIANCE_SCALE;
	}

	// the clear sky lit by the sun and the moon, not by the primary light which is the moon at night
	vec4 sample_sky_view_lut_from_origin(vec3 dir, vec3 ray_origin) {
		if (ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX == -1) {
			return get_atmosphere_from_origin(ray_origin, dir, ATMOSPHERE_SKY_SUN_DIRECTION);
		}

		vec4 sky = texture(TEXTURE(ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX), get_sky_view_lut_uv(dir, ATMOSPHERE_SKY_SUN_DIRECTION, ray_origin));

		if (ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX != -1) {
			sky.rgb += texture(TEXTURE(ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX), get_sky_view_lut_uv(dir, ATMOSPHERE_MOON_DIRECTION, ray_origin)).rgb * ATMOSPHERE_MOON_SKY_SCALE;
		}

		return sky;
	}

	vec4 sample_sky_view_lut(vec3 dir, vec3 cam_pos) {
		return sample_sky_view_lut_from_origin(normalize(dir), get_atmosphere_camera_origin(cam_pos));
	}

	// Irradiance arriving on an upward facing surface from the sky dome,
	// estimated from five sky samples: the zenith and four directions at 30
	// degrees elevation around the sun azimuth.
	vec3 get_sky_irradiance_sample(vec3 dir, vec3 ray_origin, bool with_clouds) {
		vec3 sky = sample_sky_view_lut_from_origin(dir, ray_origin).rgb;
		return with_clouds ? apply_sky_clouds(sky, dir) : sky;
	}

	vec3 get_sky_irradiance_ex(vec3 ray_origin, bool with_clouds) {
		vec3 up = normalize(ray_origin);
		vec3 forward = get_sky_view_forward(up, ATMOSPHERE_SKY_SUN_DIRECTION);
		vec3 right = normalize(cross(forward, up));
		const float cos_elevation = 0.8660254;
		const float sin_elevation = 0.5;
		vec3 radiance = get_sky_irradiance_sample(up, ray_origin, with_clouds) * 0.25;
		radiance += get_sky_irradiance_sample(normalize(forward * cos_elevation + up * sin_elevation), ray_origin, with_clouds) * 0.1875;
		radiance += get_sky_irradiance_sample(normalize(-forward * cos_elevation + up * sin_elevation), ray_origin, with_clouds) * 0.1875;
		radiance += get_sky_irradiance_sample(normalize(right * cos_elevation + up * sin_elevation), ray_origin, with_clouds) * 0.1875;
		radiance += get_sky_irradiance_sample(normalize(-right * cos_elevation + up * sin_elevation), ray_origin, with_clouds) * 0.1875;
		return radiance * PI;
	}

	vec3 get_sky_irradiance(vec3 ray_origin) {
		return get_sky_irradiance_ex(ray_origin, true);
	}

	// without the clouds, the light falling on them from above
	vec3 get_sky_irradiance_clear(vec3 ray_origin) {
		return get_sky_irradiance_ex(ray_origin, false);
	}

	// Two integrals of the sky dome above a point: the mean radiance (uniform in solid angle) and the irradiance on an
	// upward facing surface (cosine weighted). The clear sky's come from the scattering table at the point's height
	// and the sun's elevation, the clouds (their transmittance and light, the dome texture) are folded in by a
	// quadrature of the dome alone, as if the clear sky were the same in every direction
	void get_sky_hemisphere_integrals(vec3 point, bool with_clouds, out vec3 mean_radiance, out vec3 irradiance) {
		mean_radiance = vec3(0.0);
		irradiance = vec3(0.0);

		if (ATMOSPHERE_SCATTERING_AMBIENT_TEXTURE_INDEX == -1) return;

		float r = length(point);
		vec3 up = point / r;
		sc_ambient(ATMOSPHERE_SCATTERING_AMBIENT_TEXTURE_INDEX, r, dot(up, ATMOSPHERE_SKY_SUN_DIRECTION), mean_radiance, irradiance);
		mean_radiance *= ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR;
		irradiance *= ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR;

		if (!with_clouds || ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX == -1) return;

		vec3 forward = get_sky_view_forward(up, ATMOSPHERE_SKY_SUN_DIRECTION);
		vec3 right = normalize(cross(forward, up));
		const int zenith_steps = 4;
		const int azimuth_steps = 8;
		float d_theta = 1.5707963 / float(zenith_steps);
		float d_phi = 6.2831853 / float(azimuth_steps);
		float weight = 0.0;
		float weight_cos = 0.0;
		float alpha = 0.0;
		float alpha_cos = 0.0;
		vec3 light = vec3(0.0);
		vec3 light_cos = vec3(0.0);

		for (int i = 0; i < zenith_steps; i++) {
			float theta = (float(i) + 0.5) * d_theta;
			float solid_angle = sin(theta) * d_theta * d_phi;

			for (int j = 0; j < azimuth_steps; j++) {
				float phi = (float(j) + 0.5) * d_phi;
				vec3 dir = up * cos(theta) + (forward * cos(phi) + right * sin(phi)) * sin(theta);
				vec4 clouds = textureLod(TEXTURE(ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX), get_cloud_sky_uv(dir), 0.0);
				clouds.rgb /= CLOUD_RADIANCE_SCALE;
				weight += solid_angle;
				weight_cos += solid_angle * cos(theta);
				alpha += clouds.a * solid_angle;
				alpha_cos += clouds.a * solid_angle * cos(theta);
				light += clouds.rgb * solid_angle;
				light_cos += clouds.rgb * solid_angle * cos(theta);
			}
		}

		mean_radiance = mean_radiance * (alpha / weight) + light / 6.2831853;
		irradiance = irradiance * (alpha_cos / weight_cos) + light_cos;
	}

	// What the sky does not draw: the radiance of flat ground under it, albedo / pi times the sun
	// and the sky's light on it. The environment probes use it below the horizon, the surfaces
	// they light (where there are no DDGI probes) see the ground there, not the haze of the horizon.
	vec3 get_ground_radiance(vec3 ray_origin, vec3 sun_dir) {
		vec3 up = normalize(ray_origin);
		vec3 sun_irradiance = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(ray_origin, sun_dir) * max(dot(up, sun_dir), 0.0);
		vec3 mean_radiance;
		vec3 sky_irradiance;
		get_sky_hemisphere_integrals(ray_origin, true, mean_radiance, sky_irradiance);
		return GROUND_ALBEDO / PI * (sun_irradiance + sky_irradiance);
	}

	bool get_ground_fog_segment_with_ground_clip(
		vec3 ray_origin,
		vec3 ray_dir,
		float max_distance,
		bool clip_to_ground,
		out float fog_near,
		out float fog_length
	) {
		if (GROUND_FOG_ENABLED < 0.5) return false;

		float fog_outer_radius = PLANET_RADIUS + GROUND_FOG_TOP_HEIGHT;
		vec2 fog_hit = ray_sphere_intersect(ray_origin, ray_dir, fog_outer_radius);

		if (fog_hit.y <= 0.0) return false;

		vec2 ground_hit = ray_sphere_intersect(ray_origin, ray_dir, PLANET_RADIUS);
		float origin_radius = length(ray_origin);
		float fog_far = fog_hit.y;

		fog_near = origin_radius <= fog_outer_radius ? 0.0 : max(fog_hit.x, 0.0);

		if (clip_to_ground && ground_hit.x > fog_near) {
			fog_far = min(fog_far, ground_hit.x);
		}

		if (max_distance > 0.0) {
			fog_far = min(fog_far, max_distance);
		}

		fog_length = fog_far - fog_near;
		return fog_length > 1e-5;
	}

	bool get_ground_fog_segment(
		vec3 ray_origin,
		vec3 ray_dir,
		float max_distance,
		out float fog_near,
		out float fog_length
	) {
		return get_ground_fog_segment_with_ground_clip(
			ray_origin,
			ray_dir,
			max_distance,
			true,
			fog_near,
			fog_length
		);
	}

	// The share of the sun that gets through the fog layer to a point (not the sun's own air, see sample_transmittance_lut):
	// the optical depth of the layer above the point along the sun's slant, the exponential part
	// in closed form, the precipitation (uniform up to the top) added.
	float ground_fog_sun_transmittance(float altitude, float sun_up, float fog_extinction, float precipitation_extinction) {
		if (GROUND_FOG_ENABLED < 0.5 || altitude >= GROUND_FOG_TOP_HEIGHT) return 1.0;

		altitude = max(altitude, 0.0);
		float optical_depth = fog_extinction * GROUND_FOG_SCALE_HEIGHT * (exp(-altitude / GROUND_FOG_SCALE_HEIGHT) - exp(-GROUND_FOG_TOP_HEIGHT / GROUND_FOG_SCALE_HEIGHT)) + precipitation_extinction * (GROUND_FOG_TOP_HEIGHT - altitude);
		return exp(-optical_depth / max(sun_up, 0.05));
	}

	float get_ground_fog_sun_transmittance(vec3 point, vec3 sun_dir) {
		return ground_fog_sun_transmittance(length(point) - PLANET_RADIUS, dot(normalize(point), sun_dir), ATMOSPHERE_GROUND_FOG_EXTINCTION, ATMOSPHERE_PRECIPITATION_EXTINCTION);
	}

	// the optical depth of the whole layer straight up
	float get_ground_fog_layer_optical_depth() {
		return ATMOSPHERE_GROUND_FOG_EXTINCTION * GROUND_FOG_SCALE_HEIGHT * (1.0 - exp(-GROUND_FOG_TOP_HEIGHT / GROUND_FOG_SCALE_HEIGHT)) + ATMOSPHERE_PRECIPITATION_EXTINCTION * GROUND_FOG_TOP_HEIGHT;
	}

	// Radiance arriving at a point in the open air, averaged over every direction: the sky above and the sunlit,
	// sky lit ground below, what DDGI's probes give where there are probes. It doesn't depend on the view, the glow
	// around the sun is the sun's own scattering, which is shadowed.
	vec3 get_ground_fog_sky_ambient(vec3 ray_origin) {
		vec3 mean_radiance;
		vec3 sky_irradiance;
		get_sky_hemisphere_integrals(ray_origin, true, mean_radiance, sky_irradiance);
		vec3 up = normalize(ray_origin);
		vec3 sun_dir = ATMOSPHERE_SKY_SUN_DIRECTION;
		vec3 sun_irradiance = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(ray_origin, sun_dir) * max(dot(up, sun_dir), 0.0);
		vec3 sky_light = 0.5 * (mean_radiance + GROUND_ALBEDO / PI * (sky_irradiance + sun_irradiance));
		// the thicker the layer the less the open air's light is what lights it: what enters the top of it, the sun's
		// and the sky's irradiance, is scattered over and over and fills it (it fades with the layer's optical depth)
		float thickness = 1.0 - exp(-get_ground_fog_layer_optical_depth());
		return sky_light * (1.0 - thickness) + (sky_irradiance + sun_irradiance) * (GROUND_FOG_IRRADIANCE_FRACTION * pow(thickness, GROUND_FOG_IRRADIANCE_THICKNESS) / PI);
	}

	// Sunlight scattered toward the viewer by the fog: the single scattering, forward peaked, and octaves of it for the
	// light that scattered more than once (Wrenninge's approximation of multiple scattering): octave n has its scattering
	// weight, its extinction and its phase asymmetry scaled by A^n, B^n, C^n, so the glow round the sun is broad and
	// follows the sun, which an isotropic ambient does not. The octaves are weighted by how thick the layer is, a thin
	// one has no light that scattered twice (the octaves alone put a quarter too much into a 5 km fog and too little into
	// a 300 m one). In a dense fog the single scattering is a tenth of the light, the rest is the multiple scattering.
	vec3 get_ground_fog_sun(vec3 ray_origin, vec3 ray_dir, vec3 sun_dir) {
		float altitude = length(ray_origin) - PLANET_RADIUS;
		float sun_up = dot(normalize(ray_origin), sun_dir);
		float mu = dot(ray_dir, sun_dir);
		float thickness = pow(1.0 - exp(-get_ground_fog_layer_optical_depth()), GROUND_FOG_OCTAVE_THICKNESS);
		float octaves = 0.0;
		float a = 1.0;
		float b = 1.0;
		float c = 1.0;

		for (int n = 0; n < GROUND_FOG_OCTAVES; n++) {
			octaves += a * (n == 0 ? 1.0 : thickness) * ground_fog_sun_transmittance(altitude, sun_up, ATMOSPHERE_GROUND_FOG_EXTINCTION * b, ATMOSPHERE_PRECIPITATION_EXTINCTION * b) * phase_henyey_greenstein(mu, GROUND_FOG_MIE_G * c);
			a *= GROUND_FOG_OCTAVE_SCATTER;
			b *= GROUND_FOG_OCTAVE_EXTINCTION;
			c *= GROUND_FOG_OCTAVE_PHASE;
		}

		return ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(ray_origin, sun_dir) * octaves * ATMOSPHERE_FOG_RAY_STRENGTH;
	}

	// What the fog layer and the precipitation scatter towards a viewer looking along ray_dir, per km, at a point: the light
	// of the open air around it (ambient) and the sun's beam through the layer above it. The froxel volume and the
	// analytic integration of a single ray evaluate this at every sample, with the shadow and the light that are there
	vec3 get_ground_fog_in_scatter(vec3 point, vec3 ray_dir, vec3 sun_dir, float sun_visibility, vec3 ambient) {
		vec3 lit = ambient + get_ground_fog_sun(point, ray_dir, sun_dir) * clamp(sun_visibility, 0.0, 1.0);

		if (ATMOSPHERE_FOG_COLOR.w > 0.5) lit *= ATMOSPHERE_FOG_COLOR.rgb;

		return lit * ground_fog_extinction(point);
	}

	// rgb = light the fog scatters toward the viewer along the segment, a = its transmittance. Marched, the sun's beam
	// and the extinction taken at each sample. gi_irradiance stands in for the sky where the sky is hidden (sky_visibility)
	vec4 integrate_ground_fog_segment(
		vec3 ray_origin,
		vec3 ray_dir,
		float fog_near,
		float fog_length,
		vec3 sun_dir,
		float sun_visibility,
		vec3 gi_irradiance,
		float sky_visibility
	) {
		if (ATMOSPHERE_ENABLED == 0) return vec4(0.0, 0.0, 0.0, 1.0);

		float step_size = fog_length / float(AERIAL_PERSPECTIVE_STEPS);
		vec3 ambient = mix(gi_irradiance / PI, get_ground_fog_sky_ambient(ray_origin), clamp(sky_visibility, 0.0, 1.0));
		float transmittance = 1.0;
		vec3 scattered = vec3(0.0);

		for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
			vec3 sample_point = ray_origin + ray_dir * (fog_near + (float(i) + 0.5) * step_size);
			float extinction = ground_fog_extinction(sample_point);
			float step_transmittance = exp(-extinction * step_size);
			vec3 in_scatter = get_ground_fog_in_scatter(sample_point, ray_dir, sun_dir, sun_visibility, ambient);
			scattered += transmittance * in_scatter * (extinction > 1e-9 ? (1.0 - step_transmittance) / extinction : step_size);
			transmittance *= step_transmittance;
		}

		return vec4(scattered, transmittance);
	}

	vec3 apply_ground_fog_segment(
		vec3 scene_color,
		vec3 ray_origin,
		vec3 ray_dir,
		float fog_near,
		float fog_length,
		vec3 sun_dir,
		float sun_visibility,
		vec3 gi_irradiance,
		float sky_visibility
	) {
		vec4 fog = integrate_ground_fog_segment(ray_origin, ray_dir, fog_near, fog_length, sun_dir, sun_visibility, gi_irradiance, sky_visibility);
		return scene_color * fog.a + fog.rgb;
	}

	vec3 apply_ground_fog_ray(vec3 scene_color, vec3 ray_dir, vec3 sun_dir, vec3 cam_pos, float max_distance, float sun_visibility, vec3 gi_irradiance, float sky_visibility) {
		if (ATMOSPHERE_ENABLED == 0) return scene_color;

		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		float fog_near;
		float fog_length;

		if (!get_ground_fog_segment(ray_origin, normalize(ray_dir), max_distance, fog_near, fog_length)) {
			return scene_color;
		}

		return apply_ground_fog_segment(scene_color, ray_origin, normalize(ray_dir), fog_near, fog_length, sun_dir, sun_visibility, gi_irradiance, sky_visibility);
	}

	// the sun's disc at its real luminance, illuminance over its solid angle (~2e9 cd/m2 at noon), darker
	// and redder toward its edge where the view grazes the photosphere
	vec3 get_sun_disc(vec3 dir, vec3 cam_pos) {
		vec3 sun_dir = ATMOSPHERE_SKY_SUN_DIRECTION;
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);

		if (ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS).x > 0.0) return vec3(0.0);

		// the chord, acos is too coarse in float this close to 1
		float r = length(normalize(dir) - sun_dir) / SUN_ANGULAR_RADIUS;

		if (r > 1.02) return vec3(0.0);

		float edge = clamp((1.0 - r) / 0.04 + 0.5, 0.0, 1.0);
		float mu = sqrt(max(1.0 - r * r, 0.0));
		// linear limb darkening, the disc's average of 1 - u (1 - mu) is 1 - u / 3
		const vec3 LIMB_DARKENING = vec3(0.50, 0.62, 0.72);
		vec3 limb = (1.0 - LIMB_DARKENING * (1.0 - mu)) / (1.0 - LIMB_DARKENING / 3.0);
		float solid_angle = PI * SUN_ANGULAR_RADIUS * SUN_ANGULAR_RADIUS;
		return ATMOSPHERE_SUN_DISC_ILLUMINANCE / solid_angle * SUN_COLOR * limb * edge * sample_transmittance_lut(ray_origin, sun_dir);
	}
]]
)

function atmosphere.SetStarsTexture(texture)
	atmosphere.stars_texture = texture
end

function atmosphere.GetStarsTexture()
	return atmosphere.stars_texture
end

function atmosphere.SetOceanLevel(level)
	atmosphere.ocean_level = level
end

function atmosphere.GetOceanLevel()
	if atmosphere.ocean_level == nil then
		atmosphere.ocean_level = DEFAULT_OCEAN_LEVEL
	end

	return atmosphere.ocean_level
end

local function destroy_transmittance_texture()
	if atmosphere.transmittance_texture then
		atmosphere.transmittance_texture:Remove()
	end

	atmosphere.transmittance_texture = nil
end


local function create_lut_texture(width, height)
	return Texture.New{
		width = width,
		height = height,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

local function create_transmittance_texture()
	local tex = create_lut_texture(256, 64)
	tex:Shade(transmittance_glsl, {custom_declarations = AEROSOL_DECLARATIONS, fragment_push_constants = get_aerosol_push_constants()})
	return tex
end


local function destroy_sky_view_texture(key)
	local tex = atmosphere.sky_view_textures[key]

	if tex then tex:Remove() end

	atmosphere.sky_view_textures[key] = nil
end

local function touch_sky_view_texture_key(key)
	for i = 1, #atmosphere.sky_view_texture_order do
		if atmosphere.sky_view_texture_order[i] == key then
			table.remove(atmosphere.sky_view_texture_order, i)

			break
		end
	end

	table.insert(atmosphere.sky_view_texture_order, key)
end

local function destroy_scattering_texture()
	if atmosphere.scattering_texture then
		atmosphere.scattering_texture:Remove()
		atmosphere.scattering_source_texture:Remove()
		atmosphere.scattering_ambient_texture:Remove()
		atmosphere.scattering_texture = nil
		atmosphere.scattering_source_texture = nil
		atmosphere.scattering_ambient_texture = nil
	end
end

local function destroy_all_sky_view_textures()
	for key in pairs(atmosphere.sky_view_textures) do
		destroy_sky_view_texture(key)
	end

	atmosphere.sky_view_texture_order = {}
end

do
	local EYE_FALLOFF = math.exp(-SEA_LEVEL_EYE_HEIGHT / GROUND_FOG_SCALE_HEIGHT)
	atmosphere.DEFAULT_AEROSOL_VISIBILITY = 55000
	atmosphere.DEFAULT_GROUND_FOG_VISIBILITY = 140000
	atmosphere.aerosol_visibility = atmosphere.aerosol_visibility or atmosphere.DEFAULT_AEROSOL_VISIBILITY
	atmosphere.ground_fog_visibility = atmosphere.ground_fog_visibility or atmosphere.DEFAULT_GROUND_FOG_VISIBILITY
	atmosphere.precipitation_extinction = atmosphere.precipitation_extinction or 0

	function atmosphere.SetFogColor(radiance)
		atmosphere.fog_color = radiance
	end

	local function get_aerosol_extinction_550()
		return math.max(VISIBILITY_OPTICAL_DEPTH / (atmosphere.aerosol_visibility / 1000) - RAYLEIGH_GREEN_EXTINCTION, 0)
	end

	-- extinction per km of the ground fog where the fog is thickest, at the ground
	local function get_ground_fog_extinction()
		if atmosphere.ground_fog_visibility == math.huge then return 0 end

		return VISIBILITY_OPTICAL_DEPTH / (atmosphere.ground_fog_visibility / 1000) / EYE_FALLOFF
	end

	-- the clear air, Rayleigh scattering and the aerosol: how far a viewer at the ground sees through it, in meters
	-- (the distance where contrast falls to 2 percent). A new value rebakes the lookup tables
	function atmosphere.SetAerosolVisibility(meters)
		atmosphere.aerosol_visibility = meters
		atmosphere.UpdateAerosol()
	end

	-- the particles: angstrom exponent (how fast the extinction falls with wavelength, larger is smaller particles), single
	-- scattering albedo (1 scatters everything, lower absorbs, smoke and soot are around 0.85), asymmetry of the phase
	-- function (1 is all forward) and the scale height of the layer in km. Takes the table GetAerosol returns
	function atmosphere.SetAerosol(params)
		aerosol_shape[1] = params.angstrom
		aerosol_shape[2] = params.albedo
		aerosol_shape[3] = params.g
		aerosol_shape[4] = params.scale_height
		atmosphere.UpdateAerosol()
	end

	function atmosphere.GetAerosol()
		return {
			angstrom = aerosol_shape[1],
			albedo = aerosol_shape[2],
			g = aerosol_shape[3],
			scale_height = aerosol_shape[4],
		}
	end

	-- a new amount or kind of aerosol rebakes the lookup tables
	function atmosphere.UpdateAerosol()
		local ext = get_aerosol_extinction_550()
		local spectrum = Vec3((680 / 550) ^ -aerosol_shape[1], 1, (440 / 550) ^ -aerosol_shape[1])

		if
			ext == aerosol_extinction and
			spectrum.x == AEROSOL_SPECTRUM.x and
			aerosol_shape[2] == AEROSOL_ALBEDO and
			aerosol_shape[3] == AEROSOL_G and
			aerosol_shape[4] == AEROSOL_HEIGHT
		then
			return
		end

		aerosol_extinction = ext
		AEROSOL_SPECTRUM = spectrum
		AEROSOL_ALBEDO, AEROSOL_G, AEROSOL_HEIGHT = aerosol_shape[2], aerosol_shape[3], aerosol_shape[4]
		MIE_BETA_EXT = AEROSOL_SPECTRUM * ext
		MIE_BETA = MIE_BETA_EXT * AEROSOL_ALBEDO

		for i, wavelength in ipairs(SPECTRUM.wavelengths) do
			SPECTRUM.aerosol[i] = (wavelength / 550) ^ -aerosol_shape[1]
		end

		destroy_transmittance_texture()
		destroy_scattering_texture()
		destroy_all_sky_view_textures()
	end

	function atmosphere.GetAerosolVisibility()
		return atmosphere.aerosol_visibility
	end

	-- the ground hugging fog on its own, math.huge for none
	function atmosphere.SetGroundFogVisibility(meters)
		atmosphere.ground_fog_visibility = meters
	end

	function atmosphere.GetGroundFogVisibility()
		return atmosphere.ground_fog_visibility
	end

	-- extinction per km of the rain and snow, they do not thin out with height
	function atmosphere.SetPrecipitationExtinction(extinction_per_km)
		atmosphere.precipitation_extinction = extinction_per_km
	end

	-- everything together, the distance a viewer at the ground sees through the air, the fog and the precipitation
	function atmosphere.GetVisibility()
		local ground_fog = get_ground_fog_extinction() * EYE_FALLOFF
		return VISIBILITY_OPTICAL_DEPTH / (RAYLEIGH_GREEN_EXTINCTION + get_aerosol_extinction_550() + ground_fog + atmosphere.precipitation_extinction) * 1000
	end

	atmosphere.GetGroundFogExtinction = get_ground_fog_extinction
	atmosphere.UpdateAerosol()
end

do
	local REFERENCE_WIND_SPEED = 4

	function atmosphere.SetWind(velocity)
		atmosphere.wind = velocity
	end

	function atmosphere.GetWind()
		return atmosphere.wind
	end

	function atmosphere.SetTemperature(celsius)
		atmosphere.temperature = celsius
	end

	function atmosphere.GetTemperature()
		return atmosphere.temperature
	end

	function atmosphere.GetWindStrength()
		return atmosphere.wind:GetLength() / REFERENCE_WIND_SPEED
	end
end

do
	local OVERCAST_TRANSMITTANCE = 0.3
	local CLEAR_SKY_IRRADIANCE_RATIO = 1.15


	function atmosphere.GetOvercastLuminance(sun_dir, moon_dir, moon_illuminance)
		local clear_illuminance = atmosphere.GetSunIlluminance() * atmosphere.GetTransmittance(sun_dir):GetLuminance() * math.max(sun_dir.y, 0)

		if moon_dir then
			clear_illuminance = clear_illuminance + moon_illuminance * atmosphere.GetTransmittance(moon_dir):GetLuminance() * math.max(moon_dir.y, 0)
		end

		return clear_illuminance * CLEAR_SKY_IRRADIANCE_RATIO * OVERCAST_TRANSMITTANCE * 9 / (
				7 * math.pi
			)
	end
end

function atmosphere.SetSky(sky)
	atmosphere.sky = sky
end

function atmosphere.GetSky()
	return atmosphere.sky
end

function atmosphere.SetCloudSky(texture, mean_transmittance)
	atmosphere.cloud_sky_texture = texture
	atmosphere.cloud_transmittance = mean_transmittance
end

function atmosphere.SetEnabled(enabled)
	atmosphere.enabled = enabled
end

function atmosphere.IsEnabled()
	return atmosphere.enabled and atmosphere.environment_map_path == nil
end

do
	local sampler = {
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "repeat",
		wrap_t = "clamp_to_edge",
	}

	local function bump_environment_map_version()
		atmosphere.environment_map_version = atmosphere.environment_map_version + 1
	end

	function atmosphere.SetEnvironmentMap(path)
		if path == "" then path = nil end

		atmosphere.environment_map_path = path
		atmosphere.environment_map_texture = path and
			Texture.New{
				path = path,
				sampler = sampler,
				on_ready = bump_environment_map_version,
			} or
			nil
		bump_environment_map_version()
	end
end

function atmosphere.GetEnvironmentMap()
	return atmosphere.environment_map_path
end

function atmosphere.SetEnvironmentMapIntensity(intensity)
	atmosphere.environment_map_intensity = intensity
	atmosphere.environment_map_version = atmosphere.environment_map_version + 1
end

function atmosphere.GetEnvironmentMapIntensity()
	return atmosphere.environment_map_intensity
end

function atmosphere.GetEnvironmentMapVersion()
	return atmosphere.environment_map_version
end

function atmosphere.SetSunIlluminance(illuminance)
	illuminance = illuminance or DEFAULT_SUN_ILLUMINANCE

	if atmosphere.sun_illuminance == illuminance then return end

	atmosphere.sun_illuminance = illuminance
	destroy_all_sky_view_textures()
end

-- the share of the sun that gets through the ground fog layer to a point (the GLSL ground_fog_sun_transmittance), height_m
-- over the ground, sun_up the sine of the sun's elevation
function atmosphere.GetGroundFogSunTransmittance(sun_up, height_m)
	local altitude = math.max(SEA_LEVEL_EYE_HEIGHT + height_m * CAMERA_METERS_TO_KM, 0)

	if altitude >= GROUND_FOG_TOP_HEIGHT then return 1 end

	local depth = atmosphere.GetGroundFogExtinction() * GROUND_FOG_SCALE_HEIGHT * (math.exp(-altitude / GROUND_FOG_SCALE_HEIGHT) - math.exp(-GROUND_FOG_TOP_HEIGHT / GROUND_FOG_SCALE_HEIGHT)) + atmosphere.precipitation_extinction * (GROUND_FOG_TOP_HEIGHT - altitude)
	return math.exp(-depth / math.max(sun_up, 0.05))
end

function atmosphere.GetSunIlluminance()
	return atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE
end

local function create_sky_view_texture(x, y, z, elevation)
	local tex = create_lut_texture(SKY_VIEW_LUT_WIDTH, SKY_VIEW_LUT_HEIGHT)
	local length = math.sqrt(x * x + y * y + z * z)
	local ux, uy, uz = x / length, y / length, z / length
	local hx, hy, hz = uy, -ux, 0
	local hl = math.sqrt(hx * hx + hy * hy)
	hx, hy = hx / hl, hy / hl
	local cos_e, sin_e = math.cos(elevation), math.sin(elevation)
	local transmittance = atmosphere.GetTransmittanceTexture()
	local scattering_table = atmosphere.GetScatteringTexture()
	tex:Shade(
		sky_view_glsl,
		{
			textures = {transmittance, scattering_table},
			custom_declarations = SKY_VIEW_DECLARATIONS,
			fragment_push_constants = {
				size = ffi.sizeof(SkyViewConstants),
				get_data = function(_, _, pipeline)
					return SkyViewConstants(
						{x, y, z},
						atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE,
						{hx * cos_e + ux * sin_e, hy * cos_e + uy * sin_e, hz * cos_e + uz * sin_e},
						aerosol_extinction,
						aerosol_shape,
						pipeline:GetTextureIndex(transmittance),
						pipeline:GetTextureIndex(scattering_table)
					)
				end,
			},
		}
	)
	return tex
end

function atmosphere.GetTransmittanceTexture()
	if
		not atmosphere.transmittance_texture or
		not atmosphere.transmittance_texture:IsValid()
	then
		destroy_transmittance_texture()
		atmosphere.transmittance_texture = create_transmittance_texture()
	end

	return atmosphere.transmittance_texture
end


function atmosphere.GetScatteringTexture()
	if not atmosphere.scattering_texture or not atmosphere.scattering_texture:IsValid() then
		destroy_scattering_texture()
		atmosphere.scattering_texture, atmosphere.scattering_source_texture, atmosphere.scattering_ambient_texture = scattering.Create(build_atmosphere_shader_prelude, atmosphere.GetTransmittanceTexture(), aerosol_extinction, aerosol_shape)
	end

	return atmosphere.scattering_texture
end

function atmosphere.GetScatteringSourceTexture()
	atmosphere.GetScatteringTexture()
	return atmosphere.scattering_source_texture
end

function atmosphere.GetScatteringAmbientTexture()
	atmosphere.GetScatteringTexture()
	return atmosphere.scattering_ambient_texture
end

function atmosphere.GetSkyViewTexture(cam_pos, sun_dir)
	local key, x, y, z, elevation = get_sky_view_texture_key(cam_pos, sun_dir)
	local tex = atmosphere.sky_view_textures[key]

	if tex and tex:IsValid() then
		touch_sky_view_texture_key(key)
		return tex
	end

	destroy_sky_view_texture(key)
	tex = create_sky_view_texture(x, y, z, elevation)
	atmosphere.sky_view_textures[key] = tex
	touch_sky_view_texture_key(key)

	while #atmosphere.sky_view_texture_order > SKY_VIEW_TEXTURE_CACHE_LIMIT do
		local oldest = table.remove(atmosphere.sky_view_texture_order, 1)

		if oldest ~= key then destroy_sky_view_texture(oldest) end
	end

	return tex
end

function atmosphere.GetBlockLayout()
	return {
		{"atmosphere_transmittance_texture_index", "int"},
		{"atmosphere_scattering_texture_index", "int"},
		{"atmosphere_scattering_source_texture_index", "int"},
		{"atmosphere_scattering_ambient_texture_index", "int"},
		{"atmosphere_sky_view_texture_index", "int"},
		{"atmosphere_stars_texture_index", "int"},
		{"atmosphere_environment_texture_index", "int"},
		{"atmosphere_environment_intensity", "float"},
		{"atmosphere_ground_fog_extinction", "float"},
		{"atmosphere_precipitation_extinction", "float"},
		{"atmosphere_aerosol_extinction", "float"},
		{"atmosphere_fog_ray_strength", "float"},
		{"atmosphere_fog_color", "vec4"},
		{"atmosphere_cloud_sky_texture_index", "int"},
		{"atmosphere_cloud_transmittance", "float"},
		{"atmosphere_aerosol_angstrom", "float"},
		{"atmosphere_aerosol_albedo", "float"},
		{"atmosphere_sun_direction", "vec3"},
		{"atmosphere_sun_disc_illuminance", "float"},
		{"atmosphere_moon_direction", "vec3"},
		{"atmosphere_moon_sky_scale", "float"},
		{"atmosphere_moon_sky_view_texture_index", "int"},
		{"atmosphere_moon_angular_radius", "float"},
		{"atmosphere_aerosol_g", "float"},
		{"atmosphere_aerosol_scale_height", "float"},
		{"atmosphere_celestial_x", "vec3"},
		{"atmosphere_celestial_y", "vec3"},
		{"atmosphere_celestial_z", "vec3"},
		{"atmosphere_enabled", "int"},
	}
end

do
	local function write_vec3(field, v)
		field[0] = v.x
		field[1] = v.y
		field[2] = v.z
	end

	function atmosphere.WriteBlock(pipeline, block, cam_pos, sun_dir)
		local sky = atmosphere.sky
		local sky_sun_dir = sky and sky.sun_direction or sun_dir
		local environment_map = atmosphere.environment_map_texture
		block.atmosphere_enabled = atmosphere.IsEnabled() and 1 or 0
		block.atmosphere_environment_texture_index = environment_map and
			environment_map:IsReady() and
			pipeline:GetTextureIndex(environment_map) or
			-1
		block.atmosphere_environment_intensity = atmosphere.environment_map_intensity
		block.atmosphere_transmittance_texture_index = pipeline:GetTextureIndex(atmosphere.GetTransmittanceTexture())
		block.atmosphere_scattering_texture_index = pipeline:GetTextureIndex(atmosphere.GetScatteringTexture())
		block.atmosphere_scattering_source_texture_index = pipeline:GetTextureIndex(atmosphere.GetScatteringSourceTexture())
		block.atmosphere_scattering_ambient_texture_index = pipeline:GetTextureIndex(atmosphere.GetScatteringAmbientTexture())
		block.atmosphere_sky_view_texture_index = pipeline:GetTextureIndex(atmosphere.GetSkyViewTexture(cam_pos, sky_sun_dir))
		block.atmosphere_stars_texture_index = pipeline:GetTextureIndex(atmosphere.GetStarsTexture())
		block.atmosphere_ground_fog_extinction = environment_map and 0 or atmosphere.GetGroundFogExtinction()
		block.atmosphere_precipitation_extinction = environment_map and 0 or atmosphere.precipitation_extinction
		block.atmosphere_aerosol_extinction = aerosol_extinction
		block.atmosphere_aerosol_angstrom = aerosol_shape[1]
		block.atmosphere_aerosol_albedo = aerosol_shape[2]
		block.atmosphere_aerosol_g = aerosol_shape[3]
		block.atmosphere_aerosol_scale_height = aerosol_shape[4]
		block.atmosphere_fog_ray_strength = fog_ray_strength:Get()
		local fog_color = atmosphere.fog_color
		block.atmosphere_fog_color[0] = fog_color and fog_color.x or 0
		block.atmosphere_fog_color[1] = fog_color and fog_color.y or 0
		block.atmosphere_fog_color[2] = fog_color and fog_color.z or 0
		block.atmosphere_fog_color[3] = fog_color and 1 or 0
		block.atmosphere_cloud_sky_texture_index = atmosphere.cloud_sky_texture and
			pipeline:GetTextureIndex(atmosphere.cloud_sky_texture) or
			-1
		block.atmosphere_cloud_transmittance = atmosphere.cloud_transmittance
		write_vec3(block.atmosphere_sun_direction, sky_sun_dir)
		block.atmosphere_sun_disc_illuminance = atmosphere.GetSunIlluminance()

		if sky then
			write_vec3(block.atmosphere_moon_direction, sky.moon_direction)
			block.atmosphere_moon_sky_scale = sky.moon_illuminance / atmosphere.GetSunIlluminance()
			block.atmosphere_moon_sky_view_texture_index = pipeline:GetTextureIndex(atmosphere.GetSkyViewTexture(cam_pos, sky.moon_direction))
			block.atmosphere_moon_angular_radius = sky.moon_angular_radius
			write_vec3(block.atmosphere_celestial_x, sky.celestial_x)
			write_vec3(block.atmosphere_celestial_y, sky.celestial_y)
			write_vec3(block.atmosphere_celestial_z, sky.celestial_z)
		else
			write_vec3(block.atmosphere_moon_direction, Vec3(0, -1, 0))
			block.atmosphere_moon_sky_scale = 0
			block.atmosphere_moon_sky_view_texture_index = -1
			block.atmosphere_moon_angular_radius = 0
			write_vec3(block.atmosphere_celestial_x, Vec3(1, 0, 0))
			write_vec3(block.atmosphere_celestial_y, Vec3(0, 1, 0))
			write_vec3(block.atmosphere_celestial_z, Vec3(0, 0, 1))
		end
	end

	local sun_down = Vec3(0, -1, 0)
	local axis_x = Vec3(1, 0, 0)
	local axis_y = Vec3(0, 1, 0)
	local axis_z = Vec3(0, 0, 1)

	function atmosphere.WriteDisabledBlock(pipeline, block, environment_map, intensity)
		block.atmosphere_enabled = 0
		block.atmosphere_environment_texture_index = environment_map and
			environment_map:IsReady() and
			pipeline:GetTextureIndex(environment_map) or
			-1
		block.atmosphere_environment_intensity = intensity
		block.atmosphere_transmittance_texture_index = -1
		block.atmosphere_scattering_texture_index = -1
		block.atmosphere_scattering_source_texture_index = -1
		block.atmosphere_scattering_ambient_texture_index = -1
		block.atmosphere_sky_view_texture_index = -1
		block.atmosphere_stars_texture_index = -1
		block.atmosphere_ground_fog_extinction = 0
		block.atmosphere_precipitation_extinction = 0
		block.atmosphere_aerosol_extinction = 0
		block.atmosphere_aerosol_angstrom = aerosol_shape[1]
		block.atmosphere_aerosol_albedo = aerosol_shape[2]
		block.atmosphere_aerosol_g = aerosol_shape[3]
		block.atmosphere_aerosol_scale_height = aerosol_shape[4]
		block.atmosphere_fog_ray_strength = 0
		block.atmosphere_fog_color[0] = 0
		block.atmosphere_fog_color[1] = 0
		block.atmosphere_fog_color[2] = 0
		block.atmosphere_fog_color[3] = 0
		block.atmosphere_cloud_sky_texture_index = -1
		block.atmosphere_cloud_transmittance = 1
		write_vec3(block.atmosphere_sun_direction, sun_down)
		block.atmosphere_sun_disc_illuminance = 0
		write_vec3(block.atmosphere_moon_direction, sun_down)
		block.atmosphere_moon_sky_scale = 0
		block.atmosphere_moon_sky_view_texture_index = -1
		block.atmosphere_moon_angular_radius = 0
		write_vec3(block.atmosphere_celestial_x, axis_x)
		write_vec3(block.atmosphere_celestial_y, axis_y)
		write_vec3(block.atmosphere_celestial_z, axis_z)
	end
end

function atmosphere.GetGLSLDefines(uniform_name, sun_illuminance_expr)
	return "#define ATMOSPHERE_SUN_ILLUMINANCE " .. sun_illuminance_expr .. "\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_transmittance_texture_index\n" .. "#define ATMOSPHERE_SCATTERING_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_scattering_texture_index\n" .. "#define ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_scattering_source_texture_index\n" .. "#define ATMOSPHERE_SCATTERING_AMBIENT_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_scattering_ambient_texture_index\n" .. "#define ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_sky_view_texture_index\n" .. "#define ATMOSPHERE_STARS_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_stars_texture_index\n" .. "#define ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_environment_texture_index\n" .. "#define ATMOSPHERE_ENVIRONMENT_INTENSITY " .. uniform_name .. ".atmosphere_environment_intensity\n" .. "#define ATMOSPHERE_GROUND_FOG_EXTINCTION " .. uniform_name .. ".atmosphere_ground_fog_extinction\n" .. "#define ATMOSPHERE_PRECIPITATION_EXTINCTION " .. uniform_name .. ".atmosphere_precipitation_extinction\n" .. "#define ATMOSPHERE_AEROSOL_EXTINCTION " .. uniform_name .. ".atmosphere_aerosol_extinction\n" .. "#define ATMOSPHERE_AEROSOL_SHAPE vec4(" .. uniform_name .. ".atmosphere_aerosol_angstrom, " .. uniform_name .. ".atmosphere_aerosol_albedo, " .. uniform_name .. ".atmosphere_aerosol_g, " .. uniform_name .. ".atmosphere_aerosol_scale_height)\n" .. "#define ATMOSPHERE_FOG_RAY_STRENGTH " .. uniform_name .. ".atmosphere_fog_ray_strength\n" .. "#define ATMOSPHERE_FOG_COLOR " .. uniform_name .. ".atmosphere_fog_color\n" .. "#define ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_cloud_sky_texture_index\n" .. "#define ATMOSPHERE_CLOUD_TRANSMITTANCE " .. uniform_name .. ".atmosphere_cloud_transmittance\n" .. "#define ATMOSPHERE_SKY_SUN_DIRECTION " .. uniform_name .. ".atmosphere_sun_direction\n" .. "#define ATMOSPHERE_SUN_DISC_ILLUMINANCE " .. uniform_name .. ".atmosphere_sun_disc_illuminance\n" .. "#define ATMOSPHERE_MOON_DIRECTION " .. uniform_name .. ".atmosphere_moon_direction\n" .. "#define ATMOSPHERE_MOON_SKY_SCALE " .. uniform_name .. ".atmosphere_moon_sky_scale\n" .. "#define ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_moon_sky_view_texture_index\n" .. "#define ATMOSPHERE_MOON_ANGULAR_RADIUS " .. uniform_name .. ".atmosphere_moon_angular_radius\n" .. "#define ATMOSPHERE_CELESTIAL_X " .. uniform_name .. ".atmosphere_celestial_x\n" .. "#define ATMOSPHERE_CELESTIAL_Y " .. uniform_name .. ".atmosphere_celestial_y\n" .. "#define ATMOSPHERE_CELESTIAL_Z " .. uniform_name .. ".atmosphere_celestial_z\n" .. "#define ATMOSPHERE_ENABLED " .. uniform_name .. ".atmosphere_enabled\n"
end

function atmosphere.GetGLSLCode()
	return atmosphere_glsl .. import("goluwa/render3d/atmospheres/night_sky.lua")
end

function atmosphere.GetAerialPerspectiveGLSLCode()
	return atmosphere_glsl
end

function atmosphere.GetGLSLMainCode(dir_var, sun_dir_var, cam_pos_var, options)
	options = options or {}
	local disc_code = ""

	if options.include_sun_disc ~= false then
		disc_code = "atmosphere_color += get_sun_disc(atmos_dir, atmos_cam_pos) + get_moon_disc(atmos_dir, atmos_cam_pos);"
	end

	return [[
		{
			vec3 atmos_dir = normalize(]] .. dir_var .. [[);
			vec3 atmos_sun_dir = normalize(]] .. sun_dir_var .. [[);
			vec3 atmos_cam_pos = ]] .. cam_pos_var .. [[;

			if (ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX != -1) {
				// equirect, the top row is up, same layout as the stars texture
				vec2 environment_uv = vec2(atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(atmos_dir.y, -1.0, 1.0)) / PI);
				sky_color_output = textureLod(TEXTURE(ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX), environment_uv, 0.0).rgb * ATMOSPHERE_ENVIRONMENT_INTENSITY;
			} else if (ATMOSPHERE_ENABLED == 0) {
				sky_color_output = vec3(0.0);
			} else {
				vec4 atmosphere_sample = sample_sky_view_lut(atmos_dir, atmos_cam_pos);
				// a view that has the air in its volume (volumetric fog pass) wants only what is behind it
				vec3 atmosphere_color = (]] .. (options.air or "true") .. [[) ? atmosphere_sample.rgb : vec3(0.0);
				]] .. disc_code .. [[
				vec3 space_color;

				if (ATMOSPHERE_STARS_TEXTURE_INDEX != -1) {
					float u = atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5;
					float v = asin(clamp(atmos_dir.y, -1.0, 1.0)) / PI + 0.5;
					space_color = texture(TEXTURE(ATMOSPHERE_STARS_TEXTURE_INDEX), vec2(u, -v)).rgb;
				} else {
					space_color = get_night_sky(atmos_dir);
				}

				// space is behind the air, by day the sky outshines it
				sky_color_output = atmosphere_color + space_color * atmosphere_sample.a;
			}

			if (ATMOSPHERE_ENABLED != 0 && (]] .. (
			options.clouds or
			"true"
		) .. [[)) {
				sky_color_output = apply_sky_clouds(sky_color_output, atmos_dir);
			}
		}
	]]
end

function atmosphere.FoldTransmittance(rayleigh_depth, aerosol_depth, ozone_depth)
	local transmitted = {0, 0, 0}

	for i = 1, #SPECTRUM.wavelengths do
		local t = math.exp(-(SPECTRUM.rayleigh[i] * rayleigh_depth + MIE_BETA_EXT.y * SPECTRUM.aerosol[i] * aerosol_depth + SPECTRUM.ozone[i] * ozone_depth))

		for c = 1, 3 do
			transmitted[c] = transmitted[c] + SPECTRUM.weights[c][i] * t
		end
	end

	return Vec3(math.max(transmitted[1], 0), math.max(transmitted[2], 0), math.max(transmitted[3], 0))
end

function atmosphere.GetTransmittance(sunDir, camPos)
	camPos = camPos or Vec3(0, 0, 0)
	local rayOrigin = Vec3(
		camPos.x * CAMERA_METERS_TO_KM,
		PLANET_RADIUS + SEA_LEVEL_EYE_HEIGHT + camPos.y * CAMERA_METERS_TO_KM,
		camPos.z * CAMERA_METERS_TO_KM
	)
	local tmin, tmax = math3d.RaySphereIntersect(rayOrigin, sunDir, ATMOSPHERE_RADIUS)

	if tmax <= 0 then return Vec3(0, 0, 0) end

	tmin = math.max(tmin, 0)
	local groundMin = math3d.RaySphereIntersect(rayOrigin, sunDir, PLANET_RADIUS)

	if groundMin > 0 then return Vec3(0, 0, 0) end

	-- the aerosol layer is 1.2 km deep and the path 100 km long, so the samples crowd towards the viewer
	local numSamples = 64
	local length = tmax - tmin
	local opticalDepthR = 0
	local opticalDepthM = 0
	local opticalDepthO = 0

	for i = 0, numSamples - 1 do
		local u0, u1 = i / numSamples, (i + 1) / numSamples
		local segmentLength = length * (u1 * u1 - u0 * u0)
		local u = (u0 + u1) / 2
		local samplePos = rayOrigin + sunDir * (tmin + length * u * u)
		local height = samplePos:GetLength() - PLANET_RADIUS
		opticalDepthR = opticalDepthR + rayleighDensity(height) * segmentLength
		opticalDepthM = opticalDepthM + mieDensity(height) * segmentLength
		opticalDepthO = opticalDepthO + ozoneDensity(height) * segmentLength
	end

	return atmosphere.FoldTransmittance(opticalDepthR, opticalDepthM, opticalDepthO)
end

if HOTRELOAD then
	destroy_transmittance_texture()
	destroy_scattering_texture()
	destroy_all_sky_view_textures()
end

return atmosphere
