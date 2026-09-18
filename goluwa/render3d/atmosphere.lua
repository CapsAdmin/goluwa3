local atmosphere = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
atmosphere.stars_texture = nil
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
local CAMERA_TEST_MULTIPLIER = 1 --000.0
local SKY_VIEW_LUT_WIDTH = 1024
local SKY_VIEW_LUT_HEIGHT = 512
local SKY_VIEW_STEPS = 32
local SKY_VIEW_TEXTURE_CACHE_LIMIT = 16
local SKY_VIEW_POSITION_QUANTIZATION = 2
local SKY_VIEW_DIRECTION_QUANTIZATION = 0.002
local MULTI_SCATTER_LUT_SIZE = 32
local RAYLEIGH_SCALE_HEIGHT = 8.0
local MIE_SCALE_HEIGHT = 1.2
local OZONE_CENTER_HEIGHT = 25.0
local OZONE_WIDTH = 15.0
local RAYLEIGH_BETA = Vec3(0.0058, 0.0135, 0.0331)
local MIE_BETA = 0.021
local MIE_BETA_EXT = 0.021 * 1.1
local OZONE_BETA_ABS = Vec3(0.00065, 0.00188, 0.000085)
local DEFAULT_SUN_INTENSITY = 1.0
local SUN_RADIUS = 500.0
local SUN_DISTANCE = 100000.0
local DEBUG_DISABLE_SCENERY_FOG = false
atmosphere.sun_intensity = atmosphere.sun_intensity or DEFAULT_SUN_INTENSITY

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

local function format_vec3_glsl(vec)
	return string.format("vec3(%.17g, %.17g, %.17g)", vec.x, vec.y, vec.z)
end

local function quantize(value, step)
	return math.floor(value / step + 0.5) * step
end

local function get_sky_view_texture_key(cam_pos, sun_dir)
	local camera = get_shader_camera_position(cam_pos)
	local sun = get_normalized_sun_direction(sun_dir)
	local sun_intensity = atmosphere.sun_intensity or DEFAULT_SUN_INTENSITY
	return string.format(
		"%.1f:%.1f:%.1f|%.3f:%.3f:%.3f|%.3f",
		quantize(camera.x, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(camera.y, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(camera.z, SKY_VIEW_POSITION_QUANTIZATION),
		quantize(sun.x, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun.y, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun.z, SKY_VIEW_DIRECTION_QUANTIZATION),
		quantize(sun_intensity, 0.01)
	)
end

--[[
	All GLSL below reads its inputs through macros so that the same code works
	inside LUT bakes (constant indices) and inside render passes (uniform block
	fields). Passes get them from atmosphere.GetGLSLDefines(uniform_name, ...).

	ATMOSPHERE_SUN_INTENSITY                 sun irradiance at the top of the atmosphere
	ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX   2d LUT, u = cos(sun zenith), v = altitude
	ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX   2d LUT, same parametrization, multiple scattering (Hillaire 2020)
	ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX        2d LUT of the sky around the camera, rgb = in-scatter, a = transmittance
	ATMOSPHERE_STARS_TEXTURE_INDEX           optional equirect star map

	Distances are kilometers. Radiance is in units where a white Lambertian
	surface lit head on by the sun without atmosphere reflects
	ATMOSPHERE_SUN_INTENSITY / PI.
]]
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
	const float SCENERY_FOG_SCALE_HEIGHT = 0.28;
	const float SCENERY_FOG_BASE_DENSITY = 0.5;
	const float SCENERY_FOG_TOP_HEIGHT = 1.1;
	const float SCENERY_FOG_TOP_SOFTNESS = 0.3;
	const float SCENERY_FOG_EXTINCTION = 0.34;
	const float SCENERY_FOG_MIE_G = 0.6;
	const float MIE_BETA = 0.021;
	const float MIE_BETA_EXT = 0.0231;
	const float MIE_G = 0.758;
	const float OZONE_CENTER_HEIGHT = 25.0;
	const float OZONE_WIDTH = 15.0;
	const vec3 RAYLEIGH_BETA = vec3(0.0058, 0.0135, 0.0331);
	const vec3 OZONE_BETA_ABS = vec3(0.00065, 0.00188, 0.000085);
	const vec3 GROUND_ALBEDO = vec3(0.30, 0.27, 0.22);

	#ifndef ATMOSPHERE_SUN_INTENSITY
	#define ATMOSPHERE_SUN_INTENSITY 1.0
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
		return SCENERY_FOG_BASE_DENSITY * base_density * top_fade;
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
	// ray. single_scatter_visibility.x scales the Rayleigh term and .y the Mie
	// term (used to darken in-scatter along shadowed paths). Returns radiance
	// and writes the view transmittance of the segment.
	vec3 integrate_scattering(vec3 ray_origin, vec3 ray_dir, float t_near, float t_far, vec3 sun_dir, int steps, vec2 single_scatter_visibility, out vec3 view_transmittance) {
		float step_size = (t_far - t_near) / float(steps);
		float rayleigh_od = 0.0;
		float mie_od = 0.0;
		float ozone_od = 0.0;
		vec3 total = vec3(0.0);
		float mu = dot(ray_dir, sun_dir);
		vec3 phase_r = RAYLEIGH_BETA * (rayleigh_phase(mu) * single_scatter_visibility.x);
		float phase_m = MIE_BETA * mie_phase(mu) * single_scatter_visibility.y;

		for (int i = 0; i < steps; i++) {
			float t = t_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			float density_r = rayleigh_density(sample_point);
			float density_m = mie_density(sample_point);
			float density_o = ozone_density(sample_point);
			rayleigh_od += density_r * step_size;
			mie_od += density_m * step_size;
			ozone_od += density_o * step_size;
			vec3 view_t = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
			vec3 sun_t = sample_transmittance_lut(sample_point, sun_dir);
			vec3 single = (phase_r * density_r + vec3(phase_m * density_m)) * sun_t;
			vec3 multi = sample_multi_scatter_lut(sample_point, sun_dir) * (RAYLEIGH_BETA * density_r + vec3(MIE_BETA * density_m));
			total += (single + multi) * view_t * step_size;
		}

		view_transmittance = exp(-compute_view_tau(rayleigh_od, mie_od, ozone_od));
		return total * ATMOSPHERE_SUN_INTENSITY;
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
--[[
	Multiple scattering LUT after Hillaire 2020 "A Scalable and Production
	Ready Sky and Atmosphere Rendering Technique". For every (sun zenith,
	altitude) pair it integrates single scattering with an isotropic phase over
	the sphere of directions (second order luminance L2) together with the
	fraction of light that scatters again (f_ms). The infinite series of
	further bounces is approximated as L2 / (1 - f_ms). Baked with unit sun
	intensity and scaled at use.
]]
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

local function build_sky_view_glsl(cam_pos, sun_dir)
	local camera = get_shader_camera_position(cam_pos)
	local sun = get_normalized_sun_direction(sun_dir)
	local sun_intensity = atmosphere.sun_intensity or DEFAULT_SUN_INTENSITY
	return build_atmosphere_shader_prelude(
		[[
		const int SKY_VIEW_STEPS = ]] .. SKY_VIEW_STEPS .. [[;
		const vec3 SKY_VIEW_CAMERA_POSITION = ]] .. format_vec3_glsl(camera) .. [[;
		const vec3 SKY_VIEW_SUN_DIRECTION = ]] .. format_vec3_glsl(sun) .. [[;

		vec3 get_sky_view_ray_dir(vec2 uv, vec3 up) {
			vec3 forward = get_sky_view_forward(up, SKY_VIEW_SUN_DIRECTION);
			vec3 right = normalize(cross(forward, up));
			float azimuth = (uv.x * 2.0 - 1.0) * PI;
			float elevation = (uv.y * uv.y - 0.5) * PI;
			float cos_elevation = cos(elevation);
			vec3 horizontal = cos(azimuth) * forward + sin(azimuth) * right;
			return normalize(horizontal * cos_elevation + up * sin(elevation));
		}

		vec4 shade(vec2 uv, vec3 _cube_dir) {
			vec3 ray_origin = SKY_VIEW_CAMERA_POSITION;
			vec3 up = normalize(ray_origin);
			vec3 ray_dir = get_sky_view_ray_dir(uv, up);
			float t_near;
			float t_far;
			bool hits_ground;

			if (!get_atmosphere_segment(ray_origin, ray_dir, t_near, t_far, hits_ground)) return vec4(0.0, 0.0, 0.0, 1.0);

			vec3 view_transmittance;
			vec3 scattered_light = integrate_scattering(ray_origin, ray_dir, t_near, t_far, SKY_VIEW_SUN_DIRECTION, SKY_VIEW_STEPS, vec2(1.0), view_transmittance);
			return vec4(scattered_light, dot(view_transmittance, vec3(1.0 / 3.0)));
		}
	]],
		"#define ATMOSPHERE_SUN_INTENSITY " .. string.format("%.17g", sun_intensity) .. "\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX 0\n" .. "#define ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX 1\n"
	)
end

local atmosphere_glsl = build_atmosphere_shader_prelude(
	[[
	const int PRIMARY_STEPS = 32;
	const int AERIAL_PERSPECTIVE_STEPS = 32;
	const float CAMERA_METERS_TO_KM = ]] .. CAMERA_METERS_TO_KM .. [[;
	const float CAMERA_TEST_MULTIPLIER = ]] .. CAMERA_TEST_MULTIPLIER .. [[;
	const float SEA_LEVEL_EYE_HEIGHT = ]] .. SEA_LEVEL_EYE_HEIGHT .. [[;
	const float SUN_RADIUS = ]] .. SUN_RADIUS .. [[;
	const float SUN_DISTANCE = ]] .. SUN_DISTANCE .. [[;

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
		vec3 scattered_light = integrate_scattering(ray_origin, dir, t_near, t_far, sun_dir, PRIMARY_STEPS, vec2(1.0), view_transmittance);
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

	vec4 sample_sky_view_lut_from_origin(vec3 dir, vec3 sun_dir, vec3 ray_origin) {
		if (ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX == -1) {
			return get_atmosphere_from_origin(ray_origin, dir, sun_dir);
		}

		return texture(TEXTURE(ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX), get_sky_view_lut_uv(dir, sun_dir, ray_origin));
	}

	vec4 sample_sky_view_lut(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		return sample_sky_view_lut_from_origin(normalize(dir), normalize(sun_dir), get_atmosphere_camera_origin(cam_pos));
	}

	// Irradiance arriving on an upward facing surface from the sky dome,
	// estimated from five sky samples: the zenith and four directions at 30
	// degrees elevation around the sun azimuth.
	vec3 get_sky_irradiance(vec3 sun_dir, vec3 ray_origin) {
		vec3 up = normalize(ray_origin);
		vec3 forward = get_sky_view_forward(up, sun_dir);
		vec3 right = normalize(cross(forward, up));
		const float cos_elevation = 0.8660254;
		const float sin_elevation = 0.5;
		vec3 radiance = sample_sky_view_lut_from_origin(up, sun_dir, ray_origin).rgb * 0.25;
		radiance += sample_sky_view_lut_from_origin(normalize(forward * cos_elevation + up * sin_elevation), sun_dir, ray_origin).rgb * 0.1875;
		radiance += sample_sky_view_lut_from_origin(normalize(-forward * cos_elevation + up * sin_elevation), sun_dir, ray_origin).rgb * 0.1875;
		radiance += sample_sky_view_lut_from_origin(normalize(right * cos_elevation + up * sin_elevation), sun_dir, ray_origin).rgb * 0.1875;
		radiance += sample_sky_view_lut_from_origin(normalize(-right * cos_elevation + up * sin_elevation), sun_dir, ray_origin).rgb * 0.1875;
		return radiance * PI;
	}

	// Radiance of the Lambertian planet surface seen along dir, before the
	// atmosphere in front of it is applied.
	vec3 get_ground_radiance(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS);
		vec3 ground_point = ray_origin + dir * max(ground_hit.x, 0.0);
		vec3 ground_up = normalize(ground_point);
		vec3 direct = ATMOSPHERE_SUN_INTENSITY * sample_transmittance_lut(ground_point, sun_dir) * max(dot(ground_up, sun_dir), 0.0);
		vec3 sky = get_sky_irradiance(sun_dir, ray_origin);
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

	// In-scattered radiance of the low altitude fog: the sky seen along the
	// ray (kept just above the horizon so the ground fill does not leak in)
	// stands in for the light arriving from every direction, plus sunlight
	// scattered toward the viewer with a forward peaked phase function.
	vec3 get_scenery_fog_color(vec3 ray_origin, vec3 ray_dir, vec3 sun_dir, float sun_visibility) {
		vec3 up = normalize(ray_origin);
		float elevation = max(asin(clamp(dot(ray_dir, up), -1.0, 1.0)), 0.25);
		vec3 horizontal = ray_dir - up * dot(ray_dir, up);
		float horizontal_length = length(horizontal);
		horizontal = horizontal_length > 1e-4 ? horizontal / horizontal_length : get_sky_view_forward(up, sun_dir);
		vec3 sky_dir = normalize(horizontal * cos(elevation) + up * sin(elevation));
		vec3 ambient = sample_sky_view_lut_from_origin(sky_dir, sun_dir, ray_origin).rgb;
		vec3 sun_transmittance = sample_transmittance_lut(ray_origin, sun_dir);
		float phase = henyey_greenstein_phase(dot(ray_dir, sun_dir), SCENERY_FOG_MIE_G);
		vec3 direct = ATMOSPHERE_SUN_INTENSITY * sun_transmittance * phase * clamp(sun_visibility, 0.0, 1.0);
		return ambient + direct;
	}

	vec3 apply_scenery_fog_segment(
		vec3 scene_color,
		vec3 ray_origin,
		vec3 ray_dir,
		float fog_near,
		float fog_length,
		vec3 sun_dir,
		float sun_visibility
	) {
		float step_size = fog_length / float(AERIAL_PERSPECTIVE_STEPS);
		float scenery_fog_od = 0.0;

		for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
			float t = fog_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			scenery_fog_od += scenery_fog_density(sample_point) * step_size;
		}

		float scenery_fog_tau = scenery_fog_od * SCENERY_FOG_EXTINCTION;
		vec3 fog_transmittance = exp(-vec3(scenery_fog_tau));
		vec3 scenery_fog = get_scenery_fog_color(ray_origin, ray_dir, sun_dir, sun_visibility) * (1.0 - fog_transmittance);
		return scene_color * fog_transmittance + scenery_fog;
	}

	vec3 apply_atmospheric_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility) {
		vec3 ray_origin;
		vec3 ray_dir;
		float atmosphere_near;
		float segment_length;

		if (!get_aerial_perspective_segment(world_pos, cam_pos, ray_origin, ray_dir, atmosphere_near, segment_length)) {
			return scene_color;
		}

		vec2 single_scatter_visibility = vec2(
			mix(0.45, 1.0, clamp(sun_visibility, 0.0, 1.0)),
			mix(0.12, 1.0, clamp(sun_visibility, 0.0, 1.0))
		);
		vec3 view_transmittance;
		vec3 scattered_light = integrate_scattering(
			ray_origin,
			ray_dir,
			atmosphere_near,
			atmosphere_near + segment_length,
			sun_dir,
			AERIAL_PERSPECTIVE_STEPS,
			single_scatter_visibility,
			view_transmittance
		);
		return scene_color * view_transmittance + scattered_light;
	}

	vec3 apply_scenery_fog(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility) {
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

		return apply_scenery_fog_segment(scene_color, ray_origin, ray_dir, fog_near, fog_length, sun_dir, sun_visibility);
	}

	vec3 apply_scenery_fog_ray(vec3 scene_color, vec3 ray_dir, vec3 sun_dir, vec3 cam_pos, float max_distance, float sun_visibility) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		float fog_near;
		float fog_length;

		if (!get_scenery_fog_segment(ray_origin, normalize(ray_dir), max_distance, fog_near, fog_length)) {
			return scene_color;
		}

		return apply_scenery_fog_segment(scene_color, ray_origin, normalize(ray_dir), fog_near, fog_length, sun_dir, sun_visibility);
	}

	vec3 apply_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, float sun_visibility) {
		scene_color = apply_atmospheric_aerial_perspective(scene_color, world_pos, sun_dir, cam_pos, sun_visibility);
		return apply_scenery_fog(scene_color, world_pos, sun_dir, cam_pos, sun_visibility);
	}

	vec3 get_sun_disc(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS);
		if (ground_hit.x > 0.0) return vec3(0.0);

		float sun_angular_radius = SUN_RADIUS / SUN_DISTANCE;
		float theta = acos(clamp(dot(normalize(dir), normalize(sun_dir)), -1.0, 1.0));
		float disk = smoothstep(sun_angular_radius * 1.04, sun_angular_radius * 0.96, theta);
		float corona_inner = exp(-theta / max(sun_angular_radius * 5.5, 1e-5));
		float corona_outer = exp(-theta / max(sun_angular_radius * 8.0, 1e-5));
		vec3 radiance = vec3(16.0 * disk) + vec3(1.0, 0.95, 0.86) * (2.0 * corona_inner) + vec3(1.0, 0.98, 0.95) * corona_outer;
		vec3 transmittance = sample_transmittance_lut(ray_origin, sun_dir);
		float horizon_fade = smoothstep(-0.12, 0.04, sun_dir.y);
		return radiance * ATMOSPHERE_SUN_INTENSITY * transmittance * horizon_fade;
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
	if atmosphere.transmittance_texture and atmosphere.transmittance_texture.Remove then
		atmosphere.transmittance_texture:Remove()
	end

	atmosphere.transmittance_texture = nil
end

local function destroy_multi_scatter_texture()
	if atmosphere.multi_scatter_texture and atmosphere.multi_scatter_texture.Remove then
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

	if tex and tex.Remove then tex:Remove() end

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

function atmosphere.SetSunIntensity(intensity)
	intensity = intensity or DEFAULT_SUN_INTENSITY

	if atmosphere.sun_intensity == intensity then return end

	atmosphere.sun_intensity = intensity
	destroy_all_sky_view_textures()
end

function atmosphere.GetSunIntensity()
	return atmosphere.sun_intensity or DEFAULT_SUN_INTENSITY
end

local function create_sky_view_texture(cam_pos, sun_dir)
	local tex = create_lut_texture(SKY_VIEW_LUT_WIDTH, SKY_VIEW_LUT_HEIGHT)
	tex:Shade(
		build_sky_view_glsl(cam_pos, sun_dir),
		{
			textures = {atmosphere.GetTransmittanceTexture(), atmosphere.GetMultiScatterTexture()},
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
	}
end

function atmosphere.WriteBlock(pipeline, block, cam_pos, sun_dir)
	block.atmosphere_transmittance_texture_index = pipeline:GetTextureIndex(atmosphere.GetTransmittanceTexture())
	block.atmosphere_multi_scatter_texture_index = pipeline:GetTextureIndex(atmosphere.GetMultiScatterTexture())
	block.atmosphere_sky_view_texture_index = pipeline:GetTextureIndex(atmosphere.GetSkyViewTexture(cam_pos, sun_dir))
	block.atmosphere_stars_texture_index = pipeline:GetTextureIndex(atmosphere.GetStarsTexture())
end

function atmosphere.GetGLSLDefines(uniform_name, sun_intensity_expr)
	return "#define ATMOSPHERE_SUN_INTENSITY " .. sun_intensity_expr .. "\n" .. "#define ATMOSPHERE_TRANSMITTANCE_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_transmittance_texture_index\n" .. "#define ATMOSPHERE_MULTI_SCATTER_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_multi_scatter_texture_index\n" .. "#define ATMOSPHERE_SKY_VIEW_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_sky_view_texture_index\n" .. "#define ATMOSPHERE_STARS_TEXTURE_INDEX " .. uniform_name .. ".atmosphere_stars_texture_index\n"
end

function atmosphere.GetGLSLCode()
	return atmosphere_glsl .. import("goluwa/render3d/atmospheres/night_sky.lua")
end

function atmosphere.GetAerialPerspectiveGLSLCode()
	return atmosphere_glsl
end

function atmosphere.GetSurfaceAerialPerspectiveGLSLCode(background_color_expr)
	background_color_expr = background_color_expr or "vec3(0.0)"
	return atmosphere_glsl .. [[
		vec3 get_atmosphere_background_color(vec3 dir) {
			return clamp(]] .. background_color_expr .. [[, vec3(0.0), vec3(65504.0));
		}

		vec3 apply_surface_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos) {
			return apply_atmospheric_aerial_perspective(scene_color, world_pos, sun_dir, cam_pos, 1.0);
		}
	]]
end

-- Writes the sky radiance seen along dir_var into a vec3 named
-- sky_color_output that must already be declared. options.include_sun_disc
-- defaults to true; environment probes leave it out since the sun is lit
-- analytically.
function atmosphere.GetGLSLMainCode(dir_var, sun_dir_var, cam_pos_var, options)
	options = options or {}
	local sun_disc_code = ""

	if options.include_sun_disc ~= false then
		sun_disc_code = "atmosphere_color += get_sun_disc(atmos_dir, atmos_sun_dir, atmos_cam_pos);"
	end

	return [[
		{
			vec3 atmos_dir = normalize(]] .. dir_var .. [[);
			vec3 atmos_sun_dir = normalize(]] .. sun_dir_var .. [[);
			vec3 atmos_cam_pos = ]] .. cam_pos_var .. [[;
			vec4 atmosphere_sample = sample_sky_view_lut(atmos_dir, atmos_sun_dir, atmos_cam_pos);

			if (ray_hits_planet(atmos_dir, atmos_cam_pos)) {
				sky_color_output = get_ground_radiance(atmos_dir, atmos_sun_dir, atmos_cam_pos) * atmosphere_sample.a + atmosphere_sample.rgb;
			} else {
				vec3 atmosphere_color = atmosphere_sample.rgb;
				]] .. sun_disc_code .. [[
				float day_factor = smoothstep(-0.16, 0.06, atmos_sun_dir.y);
				float sky_luminance = dot(atmosphere_color, vec3(0.2126, 0.7152, 0.0722));
				float blend_factor = max(day_factor, clamp(sky_luminance * 0.5, 0.0, 1.0));
				vec3 space_color;

				if (ATMOSPHERE_STARS_TEXTURE_INDEX != -1) {
					float u = atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5;
					float v = asin(clamp(atmos_dir.y, -1.0, 1.0)) / PI + 0.5;
					space_color = texture(TEXTURE(ATMOSPHERE_STARS_TEXTURE_INDEX), vec2(u, -v)).rgb;
					space_color = pow(space_color, vec3(10.0)) * 0.5;
				} else {
					space_color = get_stars(atmos_dir, atmos_sun_dir);
				}

				sky_color_output = mix(space_color, atmosphere_color, blend_factor);
			}
		}
	]]
end

function atmosphere.GetSunColor(sunDir, camPos)
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
	local attenuation = Vec3(math.exp(-tau.x), math.exp(-tau.y), math.exp(-tau.z))
	local baseSunColor = Vec3(1.0, 0.98, 0.95)
	return attenuation * baseSunColor
end

if HOTRELOAD then
	destroy_transmittance_texture()
	destroy_multi_scatter_texture()
	destroy_all_sky_view_textures()
end

return atmosphere
