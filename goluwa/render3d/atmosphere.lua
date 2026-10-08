local ffi = require("ffi")
local atmosphere = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
local pvars = import("goluwa/cli/pvars.lua")
atmosphere.stars_texture = nil
atmosphere.environment_map_path = nil
atmosphere.environment_map_texture = nil
atmosphere.environment_map_intensity = 1000
atmosphere.environment_map_version = 0
atmosphere.transmittance_texture = nil
atmosphere.multi_scatter_texture = nil
atmosphere.sky_view_textures = atmosphere.sky_view_textures or {}
atmosphere.sky_view_texture_order = atmosphere.sky_view_texture_order or {}
local PI = math.pi
local PLANET_RADIUS = 6371.0
local ATMOSPHERE_RADIUS = 6471.0
local CAMERA_METERS_TO_KM = 0.001
local SEA_LEVEL_EYE_HEIGHT = 1.75 * CAMERA_METERS_TO_KM
local DEFAULT_OCEAN_LEVEL = 0
local CAMERA_TEST_MULTIPLIER = 1
local SKY_VIEW_LUT_WIDTH = 1024
local SKY_VIEW_LUT_HEIGHT = 512
local SKY_VIEW_STEPS = 32
local SKY_VIEW_TEXTURE_CACHE_LIMIT = 16
local SKY_VIEW_POSITION_QUANTIZATION = 2
local SKY_VIEW_DIRECTION_QUANTIZATION = 0.002
local SKY_VIEW_ILLUMINANCE_QUANTIZATION = 1000
local MULTI_SCATTER_LUT_SIZE = 32
local RAYLEIGH_SCALE_HEIGHT = 8.0
local MIE_SCALE_HEIGHT = 1.2
local OZONE_CENTER_HEIGHT = 25.0
local OZONE_WIDTH = 15.0
local RAYLEIGH_BETA = Vec3(0.0058, 0.0135, 0.0331)
local MIE_BETA = 0.021
local MIE_BETA_EXT = 0.021 * 1.1
local OZONE_BETA_ABS = Vec3(0.00065, 0.00188, 0.000085)
local DEFAULT_SUN_ILLUMINANCE = 126000
atmosphere.SUN_ANGULAR_RADIUS = 0.00465
atmosphere.CLOUD_RADIANCE_SCALE = 1 / 16
local DEBUG_DISABLE_SCENERY_FOG = false
local SCENERY_FOG_SCALE_HEIGHT = 0.28
local SCENERY_FOG_EXTINCTION = 0.34
atmosphere.sun_illuminance = atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE
pvars.StartGroup("atmosphere", {store = false})
local fog_density = pvars.Setup2{
	key = "fog_density",
	default = 0.15,
	min = 0,
	help = "density of the low altitude fog at the ground, weather sets it from the visibility",
}
local fog_ray_strength = pvars.Setup2{
	key = "fog_ray_strength",
	default = 1,
	min = 0,
	help = "scales the sunlight the fog scatters toward the viewer, so light shafts get stronger without more fog",
}
pvars.EndGroup()
atmosphere.precipitation_fog_density = 0
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

local function raySphereIntersect(ray_origin, ray_dir, sphere_radius)
	local b = ray_origin.x * ray_dir.x + ray_origin.y * ray_dir.y + ray_origin.z * ray_dir.z
	local c = ray_origin.x * ray_origin.x + ray_origin.y * ray_origin.y + ray_origin.z * ray_origin.z - sphere_radius * sphere_radius
	local discriminant = b * b - c

	if discriminant < 0 then return -1, -1 end

	local sqrt_d = math.sqrt(discriminant)
	return -b - sqrt_d, -b + sqrt_d
end

local function rayleighDensity(height)
	return math.exp(-math.max(height, 0) / RAYLEIGH_SCALE_HEIGHT)
end

local function mieDensity(height)
	local boundary_aerosols = math.exp(-math.max(height, 0) / MIE_SCALE_HEIGHT)
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
	return string.format(
		"%.1f:%.1f:%.1f|%.3f:%.3f:%.3f|%.3f",
		quantize(camera.x, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(camera.y, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(camera.z, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(sun.x, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun.y, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun.z, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun_illuminance, SKY_VIEW_ILLUMINANCE_QUANTIZATION)
	)
end

local atmosphere_shared_glsl = [[
	const float PI = 3.14159265359;
	const float PLANET_RADIUS = 6371.0;
	const float ATMOSPHERE_RADIUS = 6471.0;
	const float RAYLEIGH_SCALE_HEIGHT = 8.0;
	const float MIE_SCALE_HEIGHT = 1.2;
	const float SCENERY_FOG_ENABLED = ]] .. (
		DEBUG_DISABLE_SCENERY_FOG and
		"0.0" or
		"1.0"
	) .. [[;
	const float SCENERY_FOG_SCALE_HEIGHT = ]] .. SCENERY_FOG_SCALE_HEIGHT .. [[;
	const float SCENERY_FOG_TOP_HEIGHT = 1.1;
	const float SCENERY_FOG_TOP_SOFTNESS = 0.3;
	const float SCENERY_FOG_EXTINCTION = ]] .. SCENERY_FOG_EXTINCTION .. [[;
	const float SCENERY_FOG_MIE_G = 0.6;
	const float MIE_BETA = 0.021;
	const float MIE_BETA_EXT = 0.0231;
	const float MIE_G = 0.758;
	const float OZONE_CENTER_HEIGHT = 25.0;
	const float OZONE_WIDTH = 15.0;
	const vec3 RAYLEIGH_BETA = vec3(0.0058, 0.0135, 0.0331);
	const vec3 OZONE_BETA_ABS = vec3(0.00065, 0.00188, 0.000085);
	const vec3 GROUND_ALBEDO = vec3(0.30, 0.27, 0.22);

	#ifndef ATMOSPHERE_SUN_ILLUMINANCE
	#define ATMOSPHERE_SUN_ILLUMINANCE 126000.0
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
	#ifndef ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX
	#define ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX -1
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
	// the low altitude fog's density at the ground (fog_density)
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
	#ifndef ATMOSPHERE_FOG_DENSITY
	#define ATMOSPHERE_FOG_DENSITY ]] .. string.format("%.6f\n", fog_density:Get()) .. [[
	#endif
	#ifndef ATMOSPHERE_PRECIPITATION_FOG_DENSITY
	#define ATMOSPHERE_PRECIPITATION_FOG_DENSITY 0.0
	#endif
	#ifndef ATMOSPHERE_FOG_RAY_STRENGTH
	#define ATMOSPHERE_FOG_RAY_STRENGTH ]] .. string.format("%.6f\n", fog_ray_strength:Get()) .. [[
	#endif

	vec2 ray_sphere_intersect(vec3 ray_origin, vec3 ray_dir, float sphere_radius) {
		float b = dot(ray_origin, ray_dir);
		float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
		float discriminant = b * b - c;

		if (discriminant < 0.0) {
			return vec2(-1.0, -1.0);
		}

		float sqrt_d = sqrt(discriminant);
		return vec2(-b - sqrt_d, -b + sqrt_d);
	}

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

	float scenery_fog_density(vec3 point) {
		if (SCENERY_FOG_ENABLED < 0.5) return 0.0;

		float altitude = max(length(point) - PLANET_RADIUS, 0.0);
		float base_density = exp(-altitude / SCENERY_FOG_SCALE_HEIGHT);
		float top_fade = 1.0 - smoothstep(
			max(SCENERY_FOG_TOP_HEIGHT - SCENERY_FOG_TOP_SOFTNESS, 0.0),
			SCENERY_FOG_TOP_HEIGHT,
			altitude
		);
		return (ATMOSPHERE_FOG_DENSITY * base_density + ATMOSPHERE_PRECIPITATION_FOG_DENSITY) * top_fade;
	}

	float rayleigh_phase(float mu) {
		return 3.0 / (16.0 * PI) * (1.0 + mu * mu);
	}

	float henyey_greenstein_phase(float mu, float g) {
		float gg = g * g;
		return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
	}

	float mie_phase(float mu) {
		float gg = MIE_G * MIE_G;
		float num = 3.0 * (1.0 - gg) * (1.0 + mu * mu);
		float den = (8.0 * PI) * (2.0 + gg) * pow(max(1.0 + gg - 2.0 * MIE_G * mu, 1e-4), 1.5);
		return num / den;
	}

	vec2 get_transmittance_lut_uv(vec3 sample_point, vec3 light_dir) {
		vec3 up = normalize(sample_point);
		float mu = dot(up, light_dir);
		float radius = length(sample_point);
		float u = mu * 0.5 + 0.5;
		float v = clamp((radius - PLANET_RADIUS) / max(ATMOSPHERE_RADIUS - PLANET_RADIUS, 1e-5), 0.0, 1.0);
		return vec2(u, v);
	}

	vec3 sample_transmittance_lut(vec3 sample_point, vec3 light_dir) {
		if (ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX == -1) return vec3(1.0);
		return texture(TEXTURE(ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX), get_transmittance_lut_uv(sample_point, light_dir)).rgb;
	}

	vec3 sample_multi_scatter_lut(vec3 sample_point, vec3 light_dir) {
		if (ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX == -1) return vec3(0.0);
		return texture(TEXTURE(ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX), get_transmittance_lut_uv(sample_point, light_dir)).rgb;
	}

	vec3 compute_view_tau(float rayleigh_od, float mie_od, float ozone_od) {
		return RAYLEIGH_BETA * rayleigh_od + vec3(MIE_BETA_EXT * mie_od) + OZONE_BETA_ABS * ozone_od;
	}

	// Single scattering with the real phase functions plus the multiple
	// scattering estimate from the LUT, marched from t_near to t_far along the
	// ray. Returns radiance and writes the view transmittance of the segment.
	vec3 integrate_scattering(vec3 ray_origin, vec3 ray_dir, float t_near, float t_far, vec3 sun_dir, int steps, vec2 single_scatter_visibility, float multi_scatter_visibility, out vec3 view_transmittance) {
		float step_size = (t_far - t_near) / float(steps);
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		vec3 total = vec3(0.0);
		float mu = dot(ray_dir, sun_dir);
		vec3 phase_r = RAYLEIGH_BETA * (rayleigh_phase(mu) * single_scatter_visibility.x);
		float phase_m = MIE_BETA * mie_phase(mu) * single_scatter_visibility.y;

		for (int i = 0; i < steps; i++) {
			float t = t_near + (float(i) + ATMOSPHERE_SCATTER_JITTER) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			float density_r = rayleigh_density(sample_point);
			float density_m = mie_density(sample_point);
			float density_o = ozone_density(sample_point);
			rayleigh_od += density_r * step_size;
			mie_od += density_m * step_size;
			ozone_od += density_o * step_size;
			vec3 view_t = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
			vec3 sun_t = sample_transmittance_lut(sample_point, sun_dir) * ATMOSPHERE_CLOUD_SHADOW(sample_point);
			vec3 single = (phase_r * density_r + vec3(phase_m * density_m)) * sun_t;
			vec3 multi = sample_multi_scatter_lut(sample_point, sun_dir) * (RAYLEIGH_BETA * density_r + vec3(MIE_BETA * density_m)) * multi_scatter_visibility;
			total += (single + multi) * view_t * step_size;
		}

		view_transmittance = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
		return total * ATMOSPHERE_SUN_ILLUMINANCE;
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

	vec3 get_atmosphere_camera_origin(vec3 cam_pos) {
		vec3 world_camera_offset = cam_pos * ]] .. string.format("%.17g", CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER) .. [[;
		return vec3(
			world_camera_offset.x,
			PLANET_RADIUS + ]] .. string.format("%.17g", SEA_LEVEL_EYE_HEIGHT) .. [[ + world_camera_offset.y,
			world_camera_offset.z
		);
	}

	float get_fog_sun_horizon_visibility(vec3 sun_dir) {
		return smoothstep(-0.08, 0.02, sun_dir.y);
	}
]]

local function build_atmosphere_shader_prelude(extra, prefix)
	return (prefix or "") .. atmosphere_shared_glsl .. "\n" .. extra
end

local transmittance_glsl = build_atmosphere_shader_prelude([[
	const int TRANSMITTANCE_STEPS = 40;

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
		float radius = mix(PLANET_RADIUS, ATMOSPHERE_RADIUS, uv.y);
		vec3 ray_origin = vec3(0.0, radius, 0.0);
		float sin_theta = sqrt(max(1.0 - mu * mu, 0.0));
		vec3 ray_dir = normalize(vec3(sin_theta, mu, 0.0));
		vec2 atmosphere_hit = ray_sphere_intersect_normalized(ray_origin, ray_dir, ATMOSPHERE_RADIUS);
		vec2 ground_hit = ray_sphere_intersect_normalized(ray_origin, ray_dir, PLANET_RADIUS);
		float ray_length = atmosphere_hit.y;

		if (ray_length <= 0.0) return vec4(1.0);
		if (ground_hit.x > 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

		float step_size = ray_length / float(TRANSMITTANCE_STEPS);
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;

		for (int i = 0; i < TRANSMITTANCE_STEPS; i++) {
			float t = (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			rayleigh_od += rayleigh_density(sample_point) * step_size;
			mie_od += mie_density(sample_point) * step_size;
			ozone_od += ozone_density(sample_point) * step_size;
		}

		return vec4(exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od)), 1.0);
	}
]])
local multi_scatter_glsl = build_atmosphere_shader_prelude(
	[[
	const int MULTI_SCATTER_SQRT_DIRECTIONS = 8;
	const int MULTI_SCATTER_STEPS = 20;

	vec4 shade(vec2 uv, vec3 _cube_dir) {
		float mu_s = mix(-1.0, 1.0, uv.x);
		float radius = mix(PLANET_RADIUS, ATMOSPHERE_RADIUS, uv.y);
		vec3 ray_origin = vec3(0.0, radius, 0.0);
		vec3 sun_dir = normalize(vec3(sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0));
		vec3 second_order = vec3(0.0);
		vec3 multi_scatter_transfer = vec3(0.0);
		const float uniform_phase = 1.0 / (4.0 * PI);

		for (int i = 0; i < MULTI_SCATTER_SQRT_DIRECTIONS; i++) {
			for (int j = 0; j < MULTI_SCATTER_SQRT_DIRECTIONS; j++) {
				float cos_theta = 1.0 - 2.0 * (float(i) + 0.5) / float(MULTI_SCATTER_SQRT_DIRECTIONS);
				float sin_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0));
				float phi = 2.0 * PI * (float(j) + 0.5) / float(MULTI_SCATTER_SQRT_DIRECTIONS);
				vec3 ray_dir = vec3(sin_theta * cos(phi), cos_theta, sin_theta * sin(phi));
				float t_near;
				float t_far;
				bool hits_ground;

				if (!get_atmosphere_segment(ray_origin, ray_dir, t_near, t_far, hits_ground)) continue;

				float step_size = (t_far - t_near) / float(MULTI_SCATTER_STEPS);
				vec3 throughput = vec3(1.0);

				for (int k = 0; k < MULTI_SCATTER_STEPS; k++) {
					float t = t_near + (float(k) + 0.5) * step_size;
					vec3 sample_point = ray_origin + ray_dir * t;
					float density_r = rayleigh_density(sample_point);
					float density_m = mie_density(sample_point);
					float density_o = ozone_density(sample_point);
					vec3 sigma_s = RAYLEIGH_BETA * density_r + vec3(MIE_BETA * density_m);
					vec3 sigma_t = compute_view_tau(density_r, density_m, density_o);
					vec3 sun_t = sample_transmittance_lut(sample_point, sun_dir);
					second_order += throughput * sigma_s * sun_t * uniform_phase * step_size;
					multi_scatter_transfer += throughput * sigma_s * step_size;
					throughput *= exp(-sigma_t * step_size);
				}

				if (hits_ground) {
					vec3 ground_point = ray_origin + ray_dir * t_far;
					vec3 ground_up = normalize(ground_point);
					second_order += throughput * GROUND_ALBEDO / PI * sample_transmittance_lut(ground_point, sun_dir) * max(dot(ground_up, sun_dir), 0.0);
				}
			}
		}

		float inv_directions = 1.0 / float(MULTI_SCATTER_SQRT_DIRECTIONS * MULTI_SCATTER_SQRT_DIRECTIONS);
		second_order *= inv_directions;
		multi_scatter_transfer *= inv_directions;
		return vec4(second_order / max(vec3(1.0) - multi_scatter_transfer, vec3(1e-4)), 1.0);
	}
]],
	"#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX 0\n"
)
local SkyViewConstants = ffi.typeof([[struct {
	float camera_position[3];
	float sun_illuminance;
	float sun_direction[3];
}]])
local SKY_VIEW_DECLARATIONS = [[
	layout(push_constant) uniform SkyViewConstants {
		vec3 camera_position;
		float sun_illuminance;
		vec3 sun_direction;
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
		vec3 ray_dir = get_sky_view_ray_dir(uv, up);
		float t_near;
		float t_far;
		bool hits_ground;

		if (!get_atmosphere_segment(ray_origin, ray_dir, t_near, t_far, hits_ground)) return vec4(0.0, 0.0, 0.0, 1.0);

		vec3 view_transmittance;
		vec3 scattered_light = integrate_scattering(ray_origin, ray_dir, t_near, t_far, sky_view.sun_direction, SKY_VIEW_STEPS, vec2(1.0), 1.0, view_transmittance);
		return vec4(scattered_light, dot(view_transmittance, vec3(1.0 / 3.0)));
	}
]],
	"#define ATMOSPHERE_SUN_ILLUMINANCE sky_view.sun_illuminance\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX 0\n" .. "#define ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX 1\n"
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

	bool ray_hits_planet(vec3 dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, normalize(dir), PLANET_RADIUS);
		return ground_hit.x > 0.0;
	}

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

	// Radiance of the Lambertian planet surface seen along dir, before the
	// atmosphere in front of it is applied.
	vec3 get_ground_radiance(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS);
		vec3 ground_point = ray_origin + dir * max(ground_hit.x, 0.0);
		vec3 ground_up = normalize(ground_point);
		vec3 direct = ATMOSPHERE_SUN_ILLUMINANCE * sample_transmittance_lut(ground_point, sun_dir) * max(dot(ground_up, sun_dir), 0.0) * ATMOSPHERE_CLOUD_TRANSMITTANCE;
		vec3 sky = get_sky_irradiance(ray_origin);
		return GROUND_ALBEDO / PI * (direct + sky);
	}

	bool get_aerial_perspective_segment(
		vec3 world_pos,
		vec3 cam_pos,
		out vec3 ray_origin,
		out vec3 ray_dir,
		out float atmosphere_near,
		out float segment_length
	) {
		ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec3 world_delta = (world_pos - cam_pos) * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
		float target_distance = length(world_delta);

		if (target_distance <= 1e-5) return false;

		ray_dir = world_delta / target_distance;
		vec2 atmosphere_hit = ray_sphere_intersect(ray_origin, ray_dir, ATMOSPHERE_RADIUS);

		if (atmosphere_hit.y <= 0.0) return false;

		atmosphere_near = max(atmosphere_hit.x, 0.0);
		float atmosphere_far = min(atmosphere_hit.y, target_distance);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, ray_dir, PLANET_RADIUS);

		if (ground_hit.x > atmosphere_near) {
			atmosphere_far = min(atmosphere_far, ground_hit.x);
		}

		segment_length = atmosphere_far - atmosphere_near;
		return segment_length > 1e-5;
	}

	bool get_scenery_fog_segment_with_ground_clip(
		vec3 ray_origin,
		vec3 ray_dir,
		float max_distance,
		bool clip_to_ground,
		out float fog_near,
		out float fog_length
	) {
		if (SCENERY_FOG_ENABLED < 0.5) return false;

		float fog_outer_radius = PLANET_RADIUS + SCENERY_FOG_TOP_HEIGHT;
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

	bool get_scenery_fog_segment(
		vec3 ray_origin,
		vec3 ray_dir,
		float max_distance,
		out float fog_near,
		out float fog_length
	) {
		return get_scenery_fog_segment_with_ground_clip(
			ray_origin,
			ray_dir,
			max_distance,
			true,
			fog_near,
			fog_length
		);
	}

	// Radiance arriving at a point in the open air, averaged over every
	// direction: the sky above and the sky lit ground below, what DDGI's probes
	// give where there are probes. It doesn't depend on the view, the glow
	// around the sun is the sun's own scattering, which is shadowed.
	vec3 get_scenery_fog_sky_ambient(vec3 ray_origin) {
		vec3 sky_irradiance = get_sky_irradiance(ray_origin);
		return 0.5 * (vec3(1.0) + GROUND_ALBEDO) * sky_irradiance / PI;
	}

	// Sunlight scattered toward the viewer by the fog, forward peaked.
	vec3 get_scenery_fog_sun(vec3 ray_origin, vec3 ray_dir, vec3 sun_dir) {
		return ATMOSPHERE_SUN_ILLUMINANCE * sample_transmittance_lut(ray_origin, sun_dir) * henyey_greenstein_phase(dot(ray_dir, sun_dir), SCENERY_FOG_MIE_G) * ATMOSPHERE_FOG_RAY_STRENGTH;
	}

	// In-scattered radiance of the low altitude fog. gi_irradiance stands in
	// for the sky where the sky is hidden (sky_visibility).
	vec3 get_scenery_fog_color(vec3 ray_origin, vec3 ray_dir, vec3 sun_dir, float sun_visibility, vec3 gi_irradiance, float sky_visibility) {
		vec3 ambient = mix(gi_irradiance / PI, get_scenery_fog_sky_ambient(ray_origin), clamp(sky_visibility, 0.0, 1.0));
		vec3 lit = ambient + get_scenery_fog_sun(ray_origin, ray_dir, sun_dir) * clamp(sun_visibility, 0.0, 1.0);
		return ATMOSPHERE_FOG_COLOR.w > 0.5 ? lit * ATMOSPHERE_FOG_COLOR.rgb : lit;
	}

	// rgb = light the fog scatters toward the viewer along the segment, a = its transmittance
	vec4 integrate_scenery_fog_segment(
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
		float scenery_fog_od = 0.0;

		for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
			float t = fog_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			scenery_fog_od += scenery_fog_density(sample_point) * step_size;
		}

		float fog_transmittance = exp(-scenery_fog_od * SCENERY_FOG_EXTINCTION);
		vec3 scenery_fog = get_scenery_fog_color(ray_origin, ray_dir, sun_dir, sun_visibility, gi_irradiance, sky_visibility) * (1.0 - fog_transmittance);
		return vec4(scenery_fog, fog_transmittance);
	}

	vec3 apply_scenery_fog_segment(
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
		vec4 fog = integrate_scenery_fog_segment(ray_origin, ray_dir, fog_near, fog_length, sun_dir, sun_visibility, gi_irradiance, sky_visibility);
		return scene_color * fog.a + fog.rgb;
	}

	// the air between start (km along the ray) and world_pos
	vec3 apply_atmospheric_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility, float sky_visibility, float start) {
		if (ATMOSPHERE_ENABLED == 0) return scene_color;

		vec3 ray_origin;
		vec3 ray_dir;
		float atmosphere_near;
		float segment_length;

		if (!get_aerial_perspective_segment(world_pos, cam_pos, ray_origin, ray_dir, atmosphere_near, segment_length)) {
			return scene_color;
		}

		float atmosphere_far = atmosphere_near + segment_length;
		atmosphere_near = max(atmosphere_near, start);

		if (atmosphere_far <= atmosphere_near) return scene_color;

		vec3 view_transmittance;
		vec3 scattered_light = integrate_scattering(
			ray_origin,
			ray_dir,
			atmosphere_near,
			atmosphere_far,
			sun_dir,
			AERIAL_PERSPECTIVE_STEPS,
			vec2(clamp(sun_visibility, 0.0, 1.0)),
			clamp(sky_visibility, 0.0, 1.0),
			view_transmittance
		);
		return scene_color * view_transmittance + scattered_light;
	}

	vec3 apply_scenery_fog(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility, vec3 gi_irradiance, float sky_visibility) {
		vec3 ray_origin;
		vec3 ray_dir;
		float atmosphere_near;
		float segment_length;

		if (!get_aerial_perspective_segment(world_pos, cam_pos, ray_origin, ray_dir, atmosphere_near, segment_length)) {
			return scene_color;
		}

		float fog_near;
		float fog_length;

		if (!get_scenery_fog_segment(ray_origin, ray_dir, atmosphere_near + segment_length, fog_near, fog_length)) {
			return scene_color;
		}

		return apply_scenery_fog_segment(scene_color, ray_origin, ray_dir, fog_near, fog_length, sun_dir, sun_visibility, gi_irradiance, sky_visibility);
	}

	vec3 apply_scenery_fog_ray(vec3 scene_color, vec3 ray_dir, vec3 sun_dir, vec3 cam_pos, float max_distance, float sun_visibility, vec3 gi_irradiance, float sky_visibility) {
		if (ATMOSPHERE_ENABLED == 0) return scene_color;

		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		float fog_near;
		float fog_length;

		if (!get_scenery_fog_segment(ray_origin, normalize(ray_dir), max_distance, fog_near, fog_length)) {
			return scene_color;
		}

		return apply_scenery_fog_segment(scene_color, ray_origin, normalize(ray_dir), fog_near, fog_length, sun_dir, sun_visibility, gi_irradiance, sky_visibility);
	}

	vec3 apply_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility, vec3 gi_irradiance, float sky_visibility) {
		scene_color = apply_atmospheric_aerial_perspective(scene_color, world_pos, sun_dir, cam_pos, sun_visibility, sky_visibility, 0.0);
		return apply_scenery_fog(scene_color, world_pos, sun_dir, cam_pos, sun_visibility, gi_irradiance, sky_visibility);
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
		return ATMOSPHERE_SUN_DISC_ILLUMINANCE / solid_angle * limb * edge * sample_transmittance_lut(ray_origin, sun_dir);
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

local function destroy_multi_scatter_texture()
	if atmosphere.multi_scatter_texture then
		atmosphere.multi_scatter_texture:Remove()
	end

	atmosphere.multi_scatter_texture = nil
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
	tex:Shade(transmittance_glsl)
	return tex
end

local function create_multi_scatter_texture()
	local tex = create_lut_texture(MULTI_SCATTER_LUT_SIZE, MULTI_SCATTER_LUT_SIZE)
	tex:Shade(multi_scatter_glsl, {textures = {atmosphere.GetTransmittanceTexture()}})
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

local function destroy_all_sky_view_textures()
	for key in pairs(atmosphere.sky_view_textures) do
		destroy_sky_view_texture(key)
	end

	atmosphere.sky_view_texture_order = {}
end

do
	local CONTRAST_THRESHOLD = -math.log(0.02)
	local SEA_LEVEL_EXTINCTION_PER_METER = SCENERY_FOG_EXTINCTION * math.exp(-SEA_LEVEL_EYE_HEIGHT / SCENERY_FOG_SCALE_HEIGHT) * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER

	function atmosphere.SetFogColor(radiance)
		atmosphere.fog_color = radiance
	end

	function atmosphere.SetVisibility(meters)
		fog_density:Set(CONTRAST_THRESHOLD / meters / SEA_LEVEL_EXTINCTION_PER_METER)
	end

	function atmosphere.GetVisibility()
		return CONTRAST_THRESHOLD / (fog_density:Get() * SEA_LEVEL_EXTINCTION_PER_METER)
	end

	function atmosphere.SetPrecipitationExtinction(extinction_per_km)
		atmosphere.precipitation_fog_density = extinction_per_km / SCENERY_FOG_EXTINCTION
	end
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

	local function luminance(v)
		return v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722
	end

	function atmosphere.GetOvercastLuminance(sun_dir, moon_dir, moon_illuminance)
		local clear_illuminance = atmosphere.GetSunIlluminance() * luminance(atmosphere.GetTransmittance(sun_dir)) * math.max(sun_dir.y, 0)

		if moon_dir then
			clear_illuminance = clear_illuminance + moon_illuminance * luminance(atmosphere.GetTransmittance(moon_dir)) * math.max(moon_dir.y, 0)
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

function atmosphere.GetSunIlluminance()
	return atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE
end

local function create_sky_view_texture(cam_pos, sun_dir)
	local tex = create_lut_texture(SKY_VIEW_LUT_WIDTH, SKY_VIEW_LUT_HEIGHT)
	local camera = get_shader_camera_position(cam_pos)
	local sun = get_normalized_sun_direction(sun_dir)
	tex:Shade(
		sky_view_glsl,
		{
			textures = {atmosphere.GetTransmittanceTexture(), atmosphere.GetMultiScatterTexture()},
			custom_declarations = SKY_VIEW_DECLARATIONS,
			fragment_push_constants = {
				size = ffi.sizeof(SkyViewConstants),
				data = SkyViewConstants(
					{camera.x, camera.y, camera.z},
					atmosphere.sun_illuminance or DEFAULT_SUN_ILLUMINANCE,
					{sun.x, sun.y, sun.z}
				),
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

function atmosphere.GetMultiScatterTexture()
	if
		not atmosphere.multi_scatter_texture or
		not atmosphere.multi_scatter_texture:IsValid()
	then
		destroy_multi_scatter_texture()
		atmosphere.multi_scatter_texture = create_multi_scatter_texture()
	end

	return atmosphere.multi_scatter_texture
end

function atmosphere.GetSkyViewTexture(cam_pos, sun_dir)
	local key = get_sky_view_texture_key(cam_pos, sun_dir)
	local tex = atmosphere.sky_view_textures[key]

	if tex and tex:IsValid() then
		touch_sky_view_texture_key(key)
		return tex
	end

	destroy_sky_view_texture(key)
	tex = create_sky_view_texture(cam_pos, sun_dir)
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
		{"atmosphere_multi_scatter_texture_index", "int"},
		{"atmosphere_sky_view_texture_index", "int"},
		{"atmosphere_stars_texture_index", "int"},
		{"atmosphere_environment_texture_index", "int"},
		{"atmosphere_environment_intensity", "float"},
		{"atmosphere_fog_density", "float"},
		{"atmosphere_precipitation_fog_density", "float"},
		{"atmosphere_fog_ray_strength", "float"},
		{"atmosphere_fog_color", "vec4"},
		{"atmosphere_cloud_sky_texture_index", "int"},
		{"atmosphere_cloud_transmittance", "float"},
		{"atmosphere_sun_direction", "vec3"},
		{"atmosphere_sun_disc_illuminance", "float"},
		{"atmosphere_moon_direction", "vec3"},
		{"atmosphere_moon_sky_scale", "float"},
		{"atmosphere_moon_sky_view_texture_index", "int"},
		{"atmosphere_moon_angular_radius", "float"},
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
		block.atmosphere_multi_scatter_texture_index = pipeline:GetTextureIndex(atmosphere.GetMultiScatterTexture())
		block.atmosphere_sky_view_texture_index = pipeline:GetTextureIndex(atmosphere.GetSkyViewTexture(cam_pos, sky_sun_dir))
		block.atmosphere_stars_texture_index = pipeline:GetTextureIndex(atmosphere.GetStarsTexture())
		block.atmosphere_fog_density = environment_map and 0 or fog_density:Get()
		block.atmosphere_precipitation_fog_density = environment_map and 0 or atmosphere.precipitation_fog_density
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
end

function atmosphere.GetGLSLDefines(uniform_name, sun_illuminance_expr)
	return "#define ATMOSPHERE_SUN_ILLUMINANCE " .. sun_illuminance_expr .. "\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_transmittance_texture_index\n" .. "#define ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_multi_scatter_texture_index\n" .. "#define ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_sky_view_texture_index\n" .. "#define ATMOSPHERE_STARS_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_stars_texture_index\n" .. "#define ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_environment_texture_index\n" .. "#define ATMOSPHERE_ENVIRONMENT_INTENSITY " .. uniform_name .. ".atmosphere_environment_intensity\n" .. "#define ATMOSPHERE_FOG_DENSITY " .. uniform_name .. ".atmosphere_fog_density\n" .. "#define ATMOSPHERE_PRECIPITATION_FOG_DENSITY " .. uniform_name .. ".atmosphere_precipitation_fog_density\n" .. "#define ATMOSPHERE_FOG_RAY_STRENGTH " .. uniform_name .. ".atmosphere_fog_ray_strength\n" .. "#define ATMOSPHERE_FOG_COLOR " .. uniform_name .. ".atmosphere_fog_color\n" .. "#define ATMOSPHERE_CLOUD_SKY_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_cloud_sky_texture_index\n" .. "#define ATMOSPHERE_CLOUD_TRANSMITTANCE " .. uniform_name .. ".atmosphere_cloud_transmittance\n" .. "#define ATMOSPHERE_SKY_SUN_DIRECTION " .. uniform_name .. ".atmosphere_sun_direction\n" .. "#define ATMOSPHERE_SUN_DISC_ILLUMINANCE " .. uniform_name .. ".atmosphere_sun_disc_illuminance\n" .. "#define ATMOSPHERE_MOON_DIRECTION " .. uniform_name .. ".atmosphere_moon_direction\n" .. "#define ATMOSPHERE_MOON_SKY_SCALE " .. uniform_name .. ".atmosphere_moon_sky_scale\n" .. "#define ATMOSPHERE_MOON_SKY_VIEW_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_moon_sky_view_texture_index\n" .. "#define ATMOSPHERE_MOON_ANGULAR_RADIUS " .. uniform_name .. ".atmosphere_moon_angular_radius\n" .. "#define ATMOSPHERE_CELESTIAL_X " .. uniform_name .. ".atmosphere_celestial_x\n" .. "#define ATMOSPHERE_CELESTIAL_Y " .. uniform_name .. ".atmosphere_celestial_y\n" .. "#define ATMOSPHERE_CELESTIAL_Z " .. uniform_name .. ".atmosphere_celestial_z\n" .. "#define ATMOSPHERE_ENABLED " .. uniform_name .. ".atmosphere_enabled\n"
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
			vec4 atmosphere_sample = sample_sky_view_lut(atmos_dir, atmos_cam_pos);

			if (ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX != -1) {
				// equirect, the top row is up, same layout as the stars texture
				vec2 environment_uv = vec2(atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(atmos_dir.y, -1.0, 1.0)) / PI);
				sky_color_output = textureLod(TEXTURE(ATMOSPHERE_ENVIRONMENT_TEXTURE_INDEX), environment_uv, 0.0).rgb * ATMOSPHERE_ENVIRONMENT_INTENSITY;
			} else if (ATMOSPHERE_ENABLED == 0) {
				sky_color_output = vec3(0.0);
			} else if (ray_hits_planet(atmos_dir, atmos_cam_pos)) {
				sky_color_output = get_ground_radiance(atmos_dir, atmos_sun_dir, atmos_cam_pos) * atmosphere_sample.a + atmosphere_sample.rgb;
			} else {
				vec3 atmosphere_color = atmosphere_sample.rgb;
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

function atmosphere.GetTransmittance(sunDir, camPos)
	camPos = camPos or Vec3(0, 0, 0)
	local rayOrigin = Vec3(
		camPos.x * CAMERA_METERS_TO_KM,
		PLANET_RADIUS + SEA_LEVEL_EYE_HEIGHT + camPos.y * CAMERA_METERS_TO_KM,
		camPos.z * CAMERA_METERS_TO_KM
	)
	local tmin, tmax = raySphereIntersect(rayOrigin, sunDir, ATMOSPHERE_RADIUS)

	if tmax <= 0 then return Vec3(0, 0, 0) end

	tmin = math.max(tmin, 0)
	local groundMin = raySphereIntersect(rayOrigin, sunDir, PLANET_RADIUS)

	if groundMin > 0 then return Vec3(0, 0, 0) end

	local numSamples = 16
	local segmentLength = (tmax - tmin) / numSamples
	local opticalDepthR = 0
	local opticalDepthM = 0
	local opticalDepthO = 0

	for i = 0, numSamples - 1 do
		local samplePos = rayOrigin + sunDir * (tmin + segmentLength * (i + 0.5))
		local height = samplePos:GetLength() - PLANET_RADIUS
		opticalDepthR = opticalDepthR + rayleighDensity(height) * segmentLength
		opticalDepthM = opticalDepthM + mieDensity(height) * segmentLength
		opticalDepthO = opticalDepthO + ozoneDensity(height) * segmentLength
	end

	local tau = RAYLEIGH_BETA * opticalDepthR + Vec3(MIE_BETA_EXT, MIE_BETA_EXT, MIE_BETA_EXT) * opticalDepthM + OZONE_BETA_ABS * opticalDepthO
	return Vec3(math.exp(-tau.x), math.exp(-tau.y), math.exp(-tau.z))
end

if HOTRELOAD then
	destroy_transmittance_texture()
	destroy_multi_scatter_texture()
	destroy_all_sky_view_textures()
end

return atmosphere
