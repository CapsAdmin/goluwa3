local atmosphere = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local Texture = import("goluwa/render/texture.lua")
atmosphere.stars_texture = nil
atmosphere.transmittance_texture = nil
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
local SKY_VIEW_TEXTURE_CACHE_LIMIT = 4
local SKY_VIEW_POSITION_QUANTIZATION = 2
local SKY_VIEW_DIRECTION_QUANTIZATION = 0.002
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
local transmittance_glsl = [[
	const int TRANSMITTANCE_STEPS = 40;
	const float PI = 3.14159265359;
	const float PLANET_RADIUS = 6371.0;
	const float ATMOSPHERE_RADIUS = 6471.0;
	const float RAYLEIGH_SCALE_HEIGHT = 8.0;
	const float MIE_SCALE_HEIGHT = 1.2;
	const float OZONE_CENTER_HEIGHT = 25.0;
	const float OZONE_WIDTH = 15.0;
	const vec3 RAYLEIGH_BETA = vec3(0.0058, 0.0135, 0.0331);
	const float MIE_BETA_EXT = 0.0231;
	const vec3 OZONE_BETA_ABS = vec3(0.00065, 0.00188, 0.000085);

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

	float rayleigh_density_lut(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		return exp(-max(altitude, 0.0) / RAYLEIGH_SCALE_HEIGHT);
	}

	float mie_density_lut(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		float boundary_aerosols = exp(-max(altitude, 0.0) / MIE_SCALE_HEIGHT);
		float upper_haze = 0.07 * exp(-max(altitude, 0.0) / 8.0);
		return boundary_aerosols + upper_haze;
	}

	float ozone_density_lut(vec3 point) {
		float altitude = length(point) - PLANET_RADIUS;
		return max(0.0, 1.0 - abs(altitude - OZONE_CENTER_HEIGHT) / OZONE_WIDTH);
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
			rayleigh_od += rayleigh_density_lut(sample_point) * step_size;
			mie_od += mie_density_lut(sample_point) * step_size;
			ozone_od += ozone_density_lut(sample_point) * step_size;
		}

		vec3 tau = RAYLEIGH_BETA * rayleigh_od + vec3(MIE_BETA_EXT * mie_od) + OZONE_BETA_ABS * ozone_od;
		return vec4(exp(-tau), 1.0);
	}
]]

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
	const float MIE_BETA = 0.021;
	const float MIE_BETA_EXT = 0.0231;
	const float MIE_G = 0.758;
	const float OZONE_CENTER_HEIGHT = 25.0;
	const float OZONE_WIDTH = 15.0;
	const vec3 RAYLEIGH_BETA = vec3(0.0058, 0.0135, 0.0331);
	const vec3 OZONE_BETA_ABS = vec3(0.00065, 0.00188, 0.000085);

	#ifndef ATMOSPHERE_SUN_INTENSITY
	#define ATMOSPHERE_SUN_INTENSITY 1.0
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

	vec3 compute_view_tau(float rayleigh_od, float mie_od, float ozone_od) {
		return RAYLEIGH_BETA * rayleigh_od + vec3(MIE_BETA_EXT * mie_od) + OZONE_BETA_ABS * ozone_od;
	}

	vec3 get_ambient_color(vec3 sun_dir) {
		float sun_height = sun_dir.y;
		vec3 day_ambient = vec3(0.4, 0.6, 0.9) * 0.3;
		vec3 sunset_ambient = vec3(0.8, 0.4, 0.2) * 0.15;
		vec3 night_ambient = vec3(0.05, 0.08, 0.15) * 0.05;

		if (sun_height > 0.0) {
			return mix(sunset_ambient, day_ambient, pow(sun_height, 0.5));
		}

		float t = clamp(sun_height + 0.2, 0.0, 1.0) / 0.2;
		return mix(night_ambient, sunset_ambient, t);
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

	float get_fog_sun_horizon_visibility(vec3 sun_dir) {
		return smoothstep(-0.08, 0.02, sun_dir.y);
	}

	const float CLOUD_CUMULUS_BASE_HEIGHT = 1.2;
	const float CLOUD_CUMULUS_TOP_HEIGHT = 2.4;
	const float CLOUD_ALTO_BASE_HEIGHT = 3.2;
	const float CLOUD_ALTO_TOP_HEIGHT = 3.68;
	const float CLOUD_CIRRUS_HEIGHT = 6.0;
	const float CLOUD_CIRRUS_THICKNESS = 0.9;
	const float CLOUD_EXTINCTION = 1.35;

	struct CloudsParameters {
		float cumulus_coverage;
		float cumulus_detail_weight;
		vec2 cumulus_edge_sharpening;
		float cumulus_extinction;
		float cumulus_scattering;
		float alto_coverage;
		float alto_detail_weight;
		vec2 alto_edge_sharpening;
		float alto_extinction;
		float alto_scattering;
		float cirrus_amount;
	};

	struct CloudsResult {
		vec3 scattering;
		float transmittance;
		float apparent_distance;
	};

	vec3 get_scenery_fog_color(vec3 ray_dir, vec3 sun_dir, float sun_visibility) {
		vec3 ambient = get_ambient_color(sun_dir);
		float day_factor = smoothstep(-0.08, 0.2, sun_dir.y);
		float horizon_visibility = get_fog_sun_horizon_visibility(sun_dir);
		float ambient_visibility = smoothstep(-0.04, 0.1, sun_dir.y);
		float forward_scatter = pow(clamp(dot(ray_dir, sun_dir) * 0.5 + 0.5, 0.0, 1.0), 8.0);
		vec3 sun_tint = mix(vec3(1.0, 0.6, 0.42), vec3(1.0, 0.97, 0.92), day_factor);
		float direct_visibility = horizon_visibility * clamp(sun_visibility, 0.0, 1.0);
		vec3 indirect = ambient * ambient_visibility * 0.8;
		vec3 direct = sun_tint * (0.03 + 0.1 * forward_scatter) * direct_visibility;
		return indirect + direct * ATMOSPHERE_SUN_INTENSITY;
	}

	float cloud_henyey_greenstein(float mu, float g) {
		float gg = g * g;
		return (1.0 - gg) / (4.0 * PI * pow(max(1.0 + gg - 2.0 * g * mu, 1e-4), 1.5));
	}

	float clouds_phase_single(float cos_theta) {
		float forward = max(cloud_henyey_greenstein(cos_theta, 0.82), cloud_henyey_greenstein(cos_theta, 0.55));
		float backward = cloud_henyey_greenstein(cos_theta, -0.2);
		return 0.8 * forward + 0.2 * backward;
	}

	float clouds_phase_multi(float cos_theta, vec3 g) {
		return
			0.65 * cloud_henyey_greenstein(cos_theta, g.x) +
			0.10 * cloud_henyey_greenstein(cos_theta, g.y) +
			0.25 * cloud_henyey_greenstein(cos_theta, -g.z);
	}

	float clouds_powder_effect(float density, float cos_theta) {
		float powder = PI * density / (density + 0.15);
		return mix(powder, 1.0, 0.8 * pow(clamp(cos_theta * 0.5 + 0.5, 0.0, 1.0), 2.0));
	}

	float cloud_lift(float value, float power) {
		value = clamp(value, 0.0, 1.0);
		return value / max(value + pow(max(1.0 - value, 0.0), power), 1e-5);
	}

	float cloud_hash12(vec2 p) {
		return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
	}

	ivec2 cloud_wrap_noise_coord(ivec2 coord, ivec2 size) {
		return ivec2(
			(coord.x % size.x + size.x) % size.x,
			(coord.y % size.y + size.y) % size.y
		);
	}

	float sample_cloud_noise_texel(int blue_noise_texture_index, ivec2 coord, ivec2 size) {
		return texelFetch(TEXTURE(blue_noise_texture_index), cloud_wrap_noise_coord(coord, size), 0).r;
	}

	float cloud_noise(vec2 p) {
		vec2 cell = floor(p);
		vec2 frac_uv = fract(p);
		frac_uv = frac_uv * frac_uv * (3.0 - 2.0 * frac_uv);
		float a = cloud_hash12(cell);
		float b = cloud_hash12(cell + vec2(1.0, 0.0));
		float c = cloud_hash12(cell + vec2(0.0, 1.0));
		float d = cloud_hash12(cell + vec2(1.0, 1.0));
		return mix(mix(a, b, frac_uv.x), mix(c, d, frac_uv.x), frac_uv.y);
	}

	float cloud_blue_noise(vec2 p, int blue_noise_texture_index) {
		if (blue_noise_texture_index == -1) {
			return cloud_noise(p);
		}

		ivec2 noise_size = textureSize(TEXTURE(blue_noise_texture_index), 0);
		vec2 cell_uv = p * 5.0;
		ivec2 cell = ivec2(floor(cell_uv));
		vec2 frac_uv = fract(cell_uv);
		frac_uv = frac_uv * frac_uv * (3.0 - 2.0 * frac_uv);
		float a = sample_cloud_noise_texel(blue_noise_texture_index, cell + ivec2(0, 0), noise_size);
		float b = sample_cloud_noise_texel(blue_noise_texture_index, cell + ivec2(1, 0), noise_size);
		float c = sample_cloud_noise_texel(blue_noise_texture_index, cell + ivec2(0, 1), noise_size);
		float d = sample_cloud_noise_texel(blue_noise_texture_index, cell + ivec2(1, 1), noise_size);
		return mix(mix(a, b, frac_uv.x), mix(c, d, frac_uv.x), frac_uv.y);
	}

	float cloud_blue_noise_raw(vec2 p, int blue_noise_texture_index) {
		if (blue_noise_texture_index == -1) {
			return cloud_hash12(floor(p));
		}

		ivec2 noise_size = textureSize(TEXTURE(blue_noise_texture_index), 0);
		ivec2 cell = ivec2(floor(p));
		return sample_cloud_noise_texel(blue_noise_texture_index, cell, noise_size);
	}

	float cloud_volume_noise(vec3 p, int blue_noise_texture_index) {
		float xy = cloud_blue_noise(p.xy, blue_noise_texture_index);
		float xz = cloud_blue_noise(p.xz + vec2(17.0, -9.0), blue_noise_texture_index);
		float yz = cloud_blue_noise(p.yz + vec2(-4.0, 11.0), blue_noise_texture_index);
		return (xy + xz + yz) / 3.0;
	}

	float cloud_volume_granular_noise(vec3 p, int blue_noise_texture_index) {
		float xy = cloud_blue_noise_raw(p.xy, blue_noise_texture_index);
		float xz = cloud_blue_noise_raw(p.xz + vec2(17.0, -9.0), blue_noise_texture_index);
		float yz = cloud_blue_noise_raw(p.yz + vec2(-4.0, 11.0), blue_noise_texture_index);
		return (xy + xz + yz) / 3.0;
	}

	CloudsParameters get_clouds_parameters(vec3 sun_dir) {
		CloudsParameters params;
		float daylight = smoothstep(-0.08, 0.18, sun_dir.y);
		params.cumulus_coverage = 0.80;
		params.cumulus_detail_weight = 0.22;
		params.cumulus_edge_sharpening = vec2(3.0, 10.0);
		params.cumulus_extinction = mix(0.08, 0.12, daylight);
		params.cumulus_scattering = params.cumulus_extinction * 0.85;
		params.alto_coverage = 0.56;
		params.alto_detail_weight = 0.14;
		params.alto_edge_sharpening = vec2(2.0, 7.0);
		params.alto_extinction = mix(0.03, 0.05, daylight);
		params.alto_scattering = params.alto_extinction * 0.9;
		params.cirrus_amount = 0.42;
		return params;
	}

	bool get_cloud_layer_segment(vec3 ray_origin, vec3 ray_dir, float inner_radius, float outer_radius, float max_distance, out float segment_near, out float segment_length) {
		vec2 outer_hit = ray_sphere_intersect(ray_origin, ray_dir, outer_radius);
		if (outer_hit.y <= 0.0) return false;

		vec2 inner_hit = ray_sphere_intersect(ray_origin, ray_dir, inner_radius);
		float origin_radius = length(ray_origin);
		segment_near = 0.0;
		float segment_far = outer_hit.y;

		if (origin_radius < inner_radius) {
			if (inner_hit.y <= 0.0) return false;
			segment_near = max(inner_hit.y, 0.0);
		} else if (origin_radius > outer_radius) {
			segment_near = max(outer_hit.x, 0.0);
			if (inner_hit.x > segment_near) {
				segment_far = min(segment_far, inner_hit.x);
			}
		} else {
			segment_near = 0.0;
			if (inner_hit.x > 0.0) {
				segment_far = min(segment_far, inner_hit.x);
			}
		}

		if (max_distance > 0.0) {
			segment_far = min(segment_far, max_distance);
		}

		segment_length = segment_far - segment_near;
		return segment_length > 1e-5;
	}

	vec2 get_cloud_uv(vec3 cloud_point, float scale) {
		return cloud_point.xz * scale;
	}

	float get_cloud_altitude_fraction(vec3 sample_point, float base_height, float top_height) {
		float altitude = length(sample_point) - PLANET_RADIUS;
		return clamp((altitude - base_height) / max(top_height - base_height, 1e-5), 0.0, 1.0);
	}

	float clouds_cumulus_density(vec3 sample_point, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float altitude = length(sample_point) - PLANET_RADIUS;
		if (altitude < CLOUD_CUMULUS_BASE_HEIGHT || altitude > CLOUD_CUMULUS_TOP_HEIGHT) return 0.0;

		float height_u = get_cloud_altitude_fraction(sample_point, CLOUD_CUMULUS_BASE_HEIGHT, CLOUD_CUMULUS_TOP_HEIGHT);
		vec2 wind = vec2(cloud_time * 0.0022, cloud_time * -0.0010);
		vec2 base_pos = get_cloud_uv(sample_point, 0.045) + wind;
		float coverage = mix(params.cumulus_coverage * 0.65, params.cumulus_coverage, cloud_blue_noise(base_pos * 0.25, blue_noise_texture_index));
		float shape = cloud_blue_noise(base_pos, blue_noise_texture_index);
		float density = smoothstep(0.92 - coverage, 1.0, shape);
		float detail = cloud_volume_noise(vec3(base_pos * 3.2, height_u * 5.0), blue_noise_texture_index);
		float erosion = cloud_volume_noise(vec3(base_pos * 7.0 + vec2(9.0, -3.0), height_u * 9.0), blue_noise_texture_index);
		float granular = cloud_volume_granular_noise(vec3(base_pos * 18.0 + vec2(4.0, -7.0), height_u * 14.0), blue_noise_texture_index);
		float granular_fine = cloud_volume_granular_noise(vec3(base_pos * 36.0 + vec2(-11.0, 5.0), height_u * 24.0), blue_noise_texture_index);
		density -= params.cumulus_detail_weight * detail * (1.0 - density);
		density -= 0.08 * erosion * (1.0 - density);
		density -= 0.16 * granular * (0.35 + 0.65 * height_u) * (1.0 - density);
		density -= 0.08 * granular_fine * smoothstep(0.15, 0.85, height_u) * (1.0 - density);
		density = min(density + 0.08 * coverage, 1.0);
		density -= smoothstep(0.2, 1.0, height_u) * 0.55;
		density *= smoothstep(0.0, 0.2, height_u);
		density = max(density, 0.0);
		density = cloud_lift(density, mix(params.cumulus_edge_sharpening.x, params.cumulus_edge_sharpening.y, height_u));
		density *= 1.0 - 0.18 * pow(max(granular - 0.55, 0.0), 1.5);
		density *= mix(0.1, 1.0, smoothstep(0.2, 0.7, height_u));
		return density;
	}

	float clouds_altocumulus_density(vec3 sample_point, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float altitude = length(sample_point) - PLANET_RADIUS;
		if (altitude < CLOUD_ALTO_BASE_HEIGHT || altitude > CLOUD_ALTO_TOP_HEIGHT) return 0.0;

		float height_u = get_cloud_altitude_fraction(sample_point, CLOUD_ALTO_BASE_HEIGHT, CLOUD_ALTO_TOP_HEIGHT);
		vec2 wind = vec2(cloud_time * 0.0030, cloud_time * 0.0007);
		vec2 base_pos = get_cloud_uv(sample_point, 0.028) + wind;
		float coverage = mix(params.alto_coverage * 0.5, params.alto_coverage, cloud_blue_noise(base_pos * 0.3 + vec2(0.3, 0.6), blue_noise_texture_index));
		float shape = cloud_blue_noise(base_pos * 1.3 + vec2(0.2, -0.4), blue_noise_texture_index);
		float density = smoothstep(0.95 - coverage, 1.0, shape);
		float detail = cloud_volume_noise(vec3(base_pos * 4.5 + vec2(6.0, 1.0), height_u * 6.0), blue_noise_texture_index);
		float granular = cloud_volume_granular_noise(vec3(base_pos * 22.0 + vec2(3.0, -8.0), height_u * 18.0), blue_noise_texture_index);
		float granular_fine = cloud_volume_granular_noise(vec3(base_pos * 44.0 + vec2(-9.0, 4.0), height_u * 28.0), blue_noise_texture_index);
		density -= params.alto_detail_weight * detail * (1.0 - density);
		density -= 0.12 * granular * (1.0 - density);
		density -= 0.06 * granular_fine * smoothstep(0.1, 0.9, height_u) * (1.0 - density);
		density = min(density + 0.06 * coverage, 1.0);
		density -= smoothstep(0.2, 1.0, height_u) * 0.6;
		density *= smoothstep(0.0, 0.2, height_u);
		density = max(density, 0.0);
		density = cloud_lift(density, mix(params.alto_edge_sharpening.x, params.alto_edge_sharpening.y, height_u));
		density *= 1.0 - 0.12 * pow(max(granular - 0.58, 0.0), 1.4);
		density *= mix(0.1, 1.0, smoothstep(0.2, 0.7, height_u));
		return density;
	}

	float clouds_cirrus_density(vec3 sample_point, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float altitude = length(sample_point) - PLANET_RADIUS;
		float height_u = 0.5 + (altitude - CLOUD_CIRRUS_HEIGHT) / max(CLOUD_CIRRUS_THICKNESS, 1e-5);
		if (height_u < 0.0 || height_u > 1.0) return 0.0;
		vec2 wind = vec2(cloud_time * 0.0040, cloud_time * -0.0015);
		vec2 base_pos = get_cloud_uv(sample_point, 0.014) + wind;
		float macro = 0.7 * cloud_blue_noise(base_pos * 0.6, blue_noise_texture_index) + 0.3 * cloud_blue_noise(base_pos * 2.0 + vec2(0.7, 0.2), blue_noise_texture_index);
		float wisps = cloud_blue_noise(base_pos * 5.0 - vec2(0.4, 0.9), blue_noise_texture_index);
		float height_shape = 1.0 - abs(1.0 - 2.0 * height_u);
		float density = smoothstep(0.62 - params.cirrus_amount, 1.0, macro);
		density -= 0.18 * wisps;
		return pow(max(density, 0.0), 3.0) * height_shape * height_shape * 0.55;
	}

	float get_cloud_medium_density(vec3 sample_point, float cloud_time, int blue_noise_texture_index);

	float sample_cloud_optical_depth(vec3 ray_origin, vec3 ray_dir, float cloud_time, int blue_noise_texture_index, int step_count) {
		float segment_near;
		float segment_length;
		if (!get_cloud_layer_segment(ray_origin, ray_dir, PLANET_RADIUS + CLOUD_CUMULUS_BASE_HEIGHT, PLANET_RADIUS + CLOUD_ALTO_TOP_HEIGHT, -1.0, segment_near, segment_length)) {
			return 0.0;
		}

		float step_size = segment_length / float(step_count);
		float optical_depth = 0.0;

		for (int i = 0; i < step_count; i++) {
			float t = segment_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			optical_depth += get_cloud_medium_density(sample_point, cloud_time, blue_noise_texture_index) * step_size;
		}

		return optical_depth;
	}

	CloudsResult blend_cloud_layers(CloudsResult back_layer, CloudsResult front_layer) {
		bool front_is_nearer = front_layer.apparent_distance < back_layer.apparent_distance;
		vec3 scattering_behind = front_is_nearer ? back_layer.scattering : front_layer.scattering;
		vec3 scattering_front = front_is_nearer ? front_layer.scattering : back_layer.scattering;
		float front_transmittance = front_is_nearer ? front_layer.transmittance : back_layer.transmittance;
		return CloudsResult(
			scattering_front + front_transmittance * scattering_behind,
			back_layer.transmittance * front_layer.transmittance,
			min(back_layer.apparent_distance, front_layer.apparent_distance)
		);
	}

	float get_cloud_shadow_visibility(vec3 camera_origin, vec3 sample_point, vec3 up, vec3 sun_dir, float cloud_time, int blue_noise_texture_index) {
		float day_visibility = smoothstep(-0.12, 0.08, sun_dir.y);
		if (day_visibility <= 0.0001) return 1.0;

		float segment_near;
		float segment_length;
		if (!get_cloud_layer_segment(sample_point, sun_dir, PLANET_RADIUS + CLOUD_CUMULUS_BASE_HEIGHT, PLANET_RADIUS + CLOUD_ALTO_TOP_HEIGHT, -1.0, segment_near, segment_length)) return 1.0;

		const int CLOUD_SHADOW_STEPS = 4;
		float step_size = segment_length / float(CLOUD_SHADOW_STEPS);
		float optical_depth = 0.0;

		for (int i = 0; i < CLOUD_SHADOW_STEPS; i++) {
			float t = segment_near + (float(i) + 0.5) * step_size;
			vec3 cloud_sample = sample_point + sun_dir * t;
			optical_depth += get_cloud_medium_density(cloud_sample, cloud_time, blue_noise_texture_index) * step_size;
		}

		return mix(1.0, exp(-optical_depth * CLOUD_EXTINCTION), day_visibility);
	}

	float get_cloud_medium_density(vec3 sample_point, float cloud_time, int blue_noise_texture_index) {
		if (length(sample_point) <= PLANET_RADIUS) return 0.0;
		CloudsParameters params = get_clouds_parameters(vec3(0.0, 1.0, 0.0));
		float cumulus = clouds_cumulus_density(sample_point, cloud_time, blue_noise_texture_index, params);
		float alto = clouds_altocumulus_density(sample_point, cloud_time, blue_noise_texture_index, params);
		return cumulus + 0.55 * alto;
	}

	CloudsResult draw_cumulus_clouds(vec3 camera_origin, vec3 dir, vec3 sky_color, vec3 sun_dir, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float segment_near;
		float segment_length;
		if (!get_cloud_layer_segment(camera_origin, dir, PLANET_RADIUS + CLOUD_CUMULUS_BASE_HEIGHT, PLANET_RADIUS + CLOUD_CUMULUS_TOP_HEIGHT, -1.0, segment_near, segment_length)) {
			return CloudsResult(vec3(0.0), 1.0, 1e6);
		}

		const int CLOUD_VIEW_STEPS = 20;
		float step_size = segment_length / float(CLOUD_VIEW_STEPS);
		float transmittance = 1.0;
		vec2 scattering = vec2(0.0);
		float distance_sum = 0.0;
		float distance_weight_sum = 0.0;
		vec3 light_dir = sun_dir;
		float cos_theta = dot(dir, light_dir);
		float bounced_light = 0.08 * max(light_dir.y, 0.0);

		for (int i = 0; i < CLOUD_VIEW_STEPS; i++) {
			if (transmittance < 0.06) break;
			float t = segment_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = camera_origin + dir * t;
			float density = clouds_cumulus_density(sample_point, cloud_time, blue_noise_texture_index, params);
			if (density <= 1e-5) continue;

			float step_optical_depth = density * params.cumulus_extinction * step_size;
			float step_transmittance = exp(-step_optical_depth);
			float light_optical_depth = sample_cloud_optical_depth(sample_point, light_dir, cloud_time, blue_noise_texture_index, 4);
			float sky_optical_depth = sample_cloud_optical_depth(sample_point, vec3(0.0, 1.0, 0.0), cloud_time, blue_noise_texture_index, 3);
			float ground_optical_depth = density * get_cloud_altitude_fraction(sample_point, CLOUD_CUMULUS_BASE_HEIGHT, CLOUD_CUMULUS_TOP_HEIGHT) * (CLOUD_CUMULUS_TOP_HEIGHT - CLOUD_CUMULUS_BASE_HEIGHT);
			float scatter_integral_times_density = (1.0 - step_transmittance) / max(params.cumulus_extinction, 1e-5);
			float powder = clouds_powder_effect(density, cos_theta);
			float phase = clouds_phase_single(cos_theta);
			vec3 phase_g = pow(vec3(0.6, 0.9, 0.3), vec3(1.0 + light_optical_depth));
			float scatter_amount = params.cumulus_scattering;
			float extinct_amount = params.cumulus_extinction;
			vec2 step_scattering = vec2(0.0);

			for (int j = 0; j < 6; j++) {
				step_scattering.x += scatter_amount * exp(-extinct_amount * light_optical_depth) * phase;
				step_scattering.x += scatter_amount * exp(-extinct_amount * ground_optical_depth) * (1.0 / (4.0 * PI)) * bounced_light;
				step_scattering.y += scatter_amount * exp(-extinct_amount * sky_optical_depth) * (1.0 / (4.0 * PI));
				scatter_amount *= 0.55 * powder;
				extinct_amount *= 0.4;
				phase_g *= 0.8;
				powder = mix(powder, sqrt(powder), 0.5);
				phase = clouds_phase_multi(cos_theta, phase_g);
			}

			scattering += step_scattering * scatter_integral_times_density * transmittance;
			transmittance *= step_transmittance;
			distance_sum += t * density;
			distance_weight_sum += density;
		}

		vec3 light_color = mix(vec3(1.0, 0.72, 0.60), vec3(1.0, 0.98, 0.94), smoothstep(-0.05, 0.25, sun_dir.y)) * ATMOSPHERE_SUN_INTENSITY;
		vec3 cloud_scattering = scattering.x * light_color + scattering.y * get_ambient_color(sun_dir);
		float apparent_distance = distance_weight_sum > 0.0 ? distance_sum / distance_weight_sum : 1e6;
		return CloudsResult(cloud_scattering, transmittance, apparent_distance);
	}

	CloudsResult draw_altocumulus_clouds(vec3 camera_origin, vec3 dir, vec3 sun_dir, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float segment_near;
		float segment_length;
		if (!get_cloud_layer_segment(camera_origin, dir, PLANET_RADIUS + CLOUD_ALTO_BASE_HEIGHT, PLANET_RADIUS + CLOUD_ALTO_TOP_HEIGHT, -1.0, segment_near, segment_length)) {
			return CloudsResult(vec3(0.0), 1.0, 1e6);
		}

		const int CLOUD_VIEW_STEPS = 14;
		float step_size = segment_length / float(CLOUD_VIEW_STEPS);
		float transmittance = 1.0;
		vec2 scattering = vec2(0.0);
		float distance_sum = 0.0;
		float distance_weight_sum = 0.0;
		float cos_theta = dot(dir, sun_dir);

		for (int i = 0; i < CLOUD_VIEW_STEPS; i++) {
			if (transmittance < 0.06) break;
			float t = segment_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = camera_origin + dir * t;
			float density = clouds_altocumulus_density(sample_point, cloud_time, blue_noise_texture_index, params);
			if (density <= 1e-5) continue;

			float step_optical_depth = density * params.alto_extinction * step_size;
			float step_transmittance = exp(-step_optical_depth);
			float light_optical_depth = sample_cloud_optical_depth(sample_point, sun_dir, cloud_time, blue_noise_texture_index, 3);
			float sky_optical_depth = sample_cloud_optical_depth(sample_point, vec3(0.0, 1.0, 0.0), cloud_time, blue_noise_texture_index, 2);
			float scatter_integral_times_density = (1.0 - step_transmittance) / max(params.alto_extinction, 1e-5);
			float powder = clouds_powder_effect(density * 1.5, cos_theta);
			float phase = clouds_phase_single(cos_theta);
			vec3 phase_g = vec3(0.6, 0.9, 0.3);
			float scatter_amount = params.alto_scattering;
			float extinct_amount = params.alto_extinction;
			vec2 step_scattering = vec2(0.0);

			for (int j = 0; j < 5; j++) {
				step_scattering.x += scatter_amount * exp(-extinct_amount * light_optical_depth) * phase;
				step_scattering.y += scatter_amount * exp(-extinct_amount * sky_optical_depth) * (1.0 / (4.0 * PI));
				scatter_amount *= 0.5 * powder;
				extinct_amount *= 0.45;
				phase_g *= 0.7;
				powder = mix(powder, sqrt(powder), 0.5);
				phase = clouds_phase_multi(cos_theta, phase_g);
			}

			scattering += step_scattering * scatter_integral_times_density * transmittance;
			transmittance *= step_transmittance;
			distance_sum += t * density;
			distance_weight_sum += density;
		}

		vec3 light_color = mix(vec3(1.0, 0.74, 0.62), vec3(1.0, 0.96, 0.95), smoothstep(-0.05, 0.25, sun_dir.y)) * ATMOSPHERE_SUN_INTENSITY;
		vec3 cloud_scattering = scattering.x * light_color + scattering.y * get_ambient_color(sun_dir) * 0.9;
		float apparent_distance = distance_weight_sum > 0.0 ? distance_sum / distance_weight_sum : 1e6;
		return CloudsResult(cloud_scattering, transmittance, apparent_distance);
	}

	CloudsResult draw_cirrus_clouds(vec3 camera_origin, vec3 dir, vec3 sun_dir, float cloud_time, int blue_noise_texture_index, CloudsParameters params) {
		float segment_near;
		float segment_length;
		float inner_radius = PLANET_RADIUS + CLOUD_CIRRUS_HEIGHT - 0.5 * CLOUD_CIRRUS_THICKNESS;
		float outer_radius = PLANET_RADIUS + CLOUD_CIRRUS_HEIGHT + 0.5 * CLOUD_CIRRUS_THICKNESS;
		if (!get_cloud_layer_segment(camera_origin, dir, inner_radius, outer_radius, -1.0, segment_near, segment_length)) {
			return CloudsResult(vec3(0.0), 1.0, 1e6);
		}

		const int CLOUD_VIEW_STEPS = 8;
		float step_size = segment_length / float(CLOUD_VIEW_STEPS);
		float transmittance = 1.0;
		vec2 scattering = vec2(0.0);
		float distance_sum = 0.0;
		float distance_weight_sum = 0.0;
		float cos_theta = dot(dir, sun_dir);

		for (int i = 0; i < CLOUD_VIEW_STEPS; i++) {
			float t = segment_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = camera_origin + dir * t;
			float density = clouds_cirrus_density(sample_point, cloud_time, blue_noise_texture_index, params);
			if (density <= 1e-5) continue;

			float step_optical_depth = density * 0.15 * step_size;
			float step_transmittance = exp(-step_optical_depth);
			float light_optical_depth = sample_cloud_optical_depth(sample_point, sun_dir, cloud_time, blue_noise_texture_index, 2);
			float scatter_integral = (1.0 - step_transmittance) / 0.15;
			float powder = mix(8.0 * (1.0 - exp(-40.0 * density)), 1.0, pow(clamp(cos_theta * 0.5 + 0.5, 0.0, 1.0), 1.5));
			float phase = clouds_phase_single(cos_theta);
			vec2 step_scattering = vec2(0.0);
			step_scattering.x += 0.15 * exp(-0.15 * light_optical_depth) * phase * powder * scatter_integral;
			step_scattering.y += 0.15 * exp(-0.05 * density) * (1.0 / (4.0 * PI)) * scatter_integral;
			scattering += step_scattering * transmittance;
			transmittance *= step_transmittance;
			distance_sum += t * density;
			distance_weight_sum += density;
		}

		vec3 light_color = mix(vec3(1.0, 0.76, 0.70), vec3(1.0, 0.98, 0.98), smoothstep(-0.05, 0.25, sun_dir.y)) * ATMOSPHERE_SUN_INTENSITY;
		vec3 cloud_scattering = scattering.x * light_color + scattering.y * get_ambient_color(sun_dir);
		float apparent_distance = distance_weight_sum > 0.0 ? distance_sum / distance_weight_sum : 1e6;
		return CloudsResult(cloud_scattering, transmittance, apparent_distance);
	}

	CloudsResult draw_clouds(vec3 camera_origin, vec3 dir, vec3 sky_color, vec3 sun_dir, float cloud_time, int blue_noise_texture_index) {
		CloudsParameters params = get_clouds_parameters(sun_dir);
		CloudsResult result = draw_cumulus_clouds(camera_origin, dir, sky_color, sun_dir, cloud_time, blue_noise_texture_index, params);
		CloudsResult alto = draw_altocumulus_clouds(camera_origin, dir, sun_dir, cloud_time, blue_noise_texture_index, params);
		result = blend_cloud_layers(result, alto);
		CloudsResult cirrus = draw_cirrus_clouds(camera_origin, dir, sun_dir, cloud_time, blue_noise_texture_index, params);
		result = blend_cloud_layers(result, cirrus);
		return result;
	}

	vec3 apply_2d_clouds(vec3 sky_color, vec3 camera_origin, vec3 dir, vec3 sun_dir, vec3 up, float cloud_time, int blue_noise_texture_index) {
		float day_visibility = smoothstep(-0.12, 0.08, sun_dir.y);
		if (day_visibility <= 0.0001) return sky_color;
		float horizon_fade = smoothstep(-0.08, 0.14, dot(dir, up));
		CloudsResult result = draw_clouds(camera_origin, dir, sky_color, sun_dir, cloud_time, blue_noise_texture_index);
		float cloud_alpha = (1.0 - result.transmittance) * horizon_fade * day_visibility;
		if (cloud_alpha <= 1e-4) return sky_color;
		vec3 attenuated_sky = sky_color * mix(1.0, result.transmittance, horizon_fade);
		vec3 cloud_color = result.scattering * horizon_fade;
		return attenuated_sky + cloud_color;
	}
]]

local function build_atmosphere_shader_prelude(extra, prefix)
	return (prefix or "") .. atmosphere_shared_glsl .. "\n" .. extra
end

local function build_sky_view_glsl(cam_pos, sun_dir)
	local camera = get_shader_camera_position(cam_pos)
	local sun = get_normalized_sun_direction(sun_dir)
	local sun_intensity = atmosphere.sun_intensity or DEFAULT_SUN_INTENSITY
	return build_atmosphere_shader_prelude(
		[[
		const int SKY_VIEW_STEPS = ]] .. SKY_VIEW_STEPS .. [[;
		const int TRANSMITTANCE_TEXTURE_INDEX = 0;
		const vec3 SKY_VIEW_CAMERA_POSITION = ]] .. format_vec3_glsl(camera) .. [[;
		const vec3 SKY_VIEW_SUN_DIRECTION = ]] .. format_vec3_glsl(sun) .. [[;

		vec3 sample_transmittance_lut(vec3 sample_point, vec3 light_dir) {
			vec2 uv = get_transmittance_lut_uv(sample_point, light_dir);
			return texture(TEXTURE(TRANSMITTANCE_TEXTURE_INDEX), uv).rgb;
		}

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
			vec2 atmosphere_hit = ray_sphere_intersect(ray_origin, ray_dir, ATMOSPHERE_RADIUS);
			vec2 ground_hit = ray_sphere_intersect(ray_origin, ray_dir, PLANET_RADIUS);

			if (atmosphere_hit.y <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

			float atmosphere_near = max(atmosphere_hit.x, 0.0);
			float atmosphere_far = atmosphere_hit.y;

			if (ground_hit.x > atmosphere_near) {
				atmosphere_far = min(atmosphere_far, ground_hit.x);
			}

			float segment_length = atmosphere_far - atmosphere_near;
			if (segment_length <= 1e-5) return vec4(0.0, 0.0, 0.0, 1.0);

			float step_size = segment_length / float(SKY_VIEW_STEPS);
			float view_rayleigh_od = 0.0;
			float view_mie_od = 0.0;
			float view_ozone_od = 0.0;
			vec3 total_rayleigh = vec3(0.0);
			vec3 total_mie = vec3(0.0);
			float mu = dot(ray_dir, SKY_VIEW_SUN_DIRECTION);
			float phase_r = rayleigh_phase(mu);
			float phase_m = mie_phase(mu);

			for (int i = 0; i < SKY_VIEW_STEPS; i++) {
				float t = atmosphere_near + (float(i) + 0.5) * step_size;
				vec3 sample_point = ray_origin + ray_dir * t;
				float density_r = rayleigh_density(sample_point);
				float density_m = mie_density(sample_point);
				float density_o = ozone_density(sample_point);

				view_rayleigh_od += density_r * step_size;
				view_mie_od += density_m * step_size;
				view_ozone_od += density_o * step_size;

				vec3 sun_transmittance = sample_transmittance_lut(sample_point, SKY_VIEW_SUN_DIRECTION);
				vec3 view_transmittance = exp(-compute_view_tau(view_rayleigh_od, view_mie_od, view_ozone_od));
				vec3 transmittance = sun_transmittance * view_transmittance;
				total_rayleigh += density_r * transmittance * step_size;
				total_mie += density_m * transmittance * step_size;
			}

			vec3 scattered_light = ATMOSPHERE_SUN_INTENSITY * (
				phase_r * RAYLEIGH_BETA * total_rayleigh +
				phase_m * MIE_BETA * total_mie
			);

			return vec4(scattered_light, 1.0);
		}
	]],
		"#define ATMOSPHERE_SUN_INTENSITY " .. string.format("%.17g", sun_intensity) .. "\n"
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

	vec3 get_atmosphere(vec3 dir, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index);

	vec3 get_atmosphere_camera_origin(vec3 cam_pos) {
		vec3 world_camera_offset = cam_pos * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
		return vec3(
			world_camera_offset.x,
			PLANET_RADIUS + SEA_LEVEL_EYE_HEIGHT + world_camera_offset.y,
			world_camera_offset.z
		);
	}

	bool ray_hits_planet(vec3 dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, normalize(dir), PLANET_RADIUS);
		return ground_hit.x > 0.0;
	}

	vec3 get_probe_ground_occlusion_color(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		vec3 up = normalize(get_atmosphere_camera_origin(cam_pos));
		float view_down = clamp(-dot(normalize(dir), up), 0.0, 1.0);
		float horizon_weight = smoothstep(0.0, 1.0, 1.0 - view_down);
		float ground_light = smoothstep(-0.08, 0.03, sun_dir.y);
		vec3 ambient = get_ambient_color(sun_dir);
		vec3 deep_ground = ambient * 0.08 * ground_light;
		vec3 horizon_ground = ambient * 0.35 * ground_light;
		return mix(deep_ground, horizon_ground, horizon_weight);
	}

	vec3 sample_transmittance_lut(int transmittance_texture_index, vec3 sample_point, vec3 light_dir) {
		if (transmittance_texture_index == -1) return vec3(1.0);
		vec2 uv = get_transmittance_lut_uv(sample_point, light_dir);
		return texture(TEXTURE(transmittance_texture_index), uv).rgb;
	}

	vec2 get_sky_view_lut_uv(vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
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

	vec3 sample_sky_view_lut(int sky_view_texture_index, vec3 dir, vec3 sun_dir, vec3 cam_pos) {
		if (sky_view_texture_index == -1) {
			return get_atmosphere(dir, sun_dir, cam_pos, -1);
		}

		vec2 uv = get_sky_view_lut_uv(normalize(dir), normalize(sun_dir), cam_pos);
		return texture(TEXTURE(sky_view_texture_index), uv).rgb;
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
		vec3 scenery_fog = get_scenery_fog_color(ray_dir, sun_dir, sun_visibility) * (1.0 - fog_transmittance);
		return scene_color * fog_transmittance + scenery_fog;
	}

	vec3 apply_atmospheric_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index, float sun_visibility) {
		vec3 ray_origin;
		vec3 ray_dir;
		float atmosphere_near;
		float segment_length;

		if (!get_aerial_perspective_segment(world_pos, cam_pos, ray_origin, ray_dir, atmosphere_near, segment_length)) {
			return scene_color;
		}

		float step_size = segment_length / float(AERIAL_PERSPECTIVE_STEPS);
		float view_rayleigh_od = 0.0;
		float view_mie_od = 0.0;
		float view_ozone_od = 0.0;
		vec3 total_rayleigh = vec3(0.0);
		vec3 total_mie = vec3(0.0);
		float mu = dot(ray_dir, sun_dir);
		float phase_r = rayleigh_phase(mu);
		float phase_m = mie_phase(mu);

		for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
			float t = atmosphere_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + ray_dir * t;
			float density_r = rayleigh_density(sample_point);
			float density_m = mie_density(sample_point);
			float density_o = ozone_density(sample_point);

			view_rayleigh_od += density_r * step_size;
			view_mie_od += density_m * step_size;
			view_ozone_od += density_o * step_size;

			vec3 sun_transmittance = sample_transmittance_lut(transmittance_texture_index, sample_point, sun_dir);
			vec3 view_transmittance = exp(-compute_view_tau(view_rayleigh_od, view_mie_od, view_ozone_od));
			vec3 transmittance = sun_transmittance * view_transmittance;

			total_rayleigh += density_r * transmittance * step_size;
			total_mie += density_m * transmittance * step_size;
		}

		float rayleigh_visibility = mix(0.45, 1.0, clamp(sun_visibility, 0.0, 1.0));
		float mie_visibility = mix(0.12, 1.0, clamp(sun_visibility, 0.0, 1.0));
		vec3 scattered_light = ATMOSPHERE_SUN_INTENSITY * (
			phase_r * RAYLEIGH_BETA * total_rayleigh * rayleigh_visibility +
			phase_m * MIE_BETA * total_mie * mie_visibility
		);
		vec3 view_transmittance = exp(-compute_view_tau(view_rayleigh_od, view_mie_od, view_ozone_od));
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

	vec3 apply_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index, float sun_visibility) {
		scene_color = apply_atmospheric_aerial_perspective(scene_color, world_pos, sun_dir, cam_pos, transmittance_texture_index, sun_visibility);
		return apply_scenery_fog(scene_color, world_pos, sun_dir, cam_pos, sun_visibility);
	}

	vec3 get_atmosphere(vec3 dir, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 atmosphere_hit = ray_sphere_intersect(ray_origin, dir, ATMOSPHERE_RADIUS);

		if (atmosphere_hit.y <= 0.0) return vec3(0.0);

		vec2 ground_hit = ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS);
		float atmosphere_near = max(atmosphere_hit.x, 0.0);
		float atmosphere_far = atmosphere_hit.y;

		if (ground_hit.x > atmosphere_near) {
			atmosphere_far = min(atmosphere_far, ground_hit.x);
		}

		float segment_length = atmosphere_far - atmosphere_near;
		if (segment_length <= 1e-5) return vec3(0.0);

		float step_size = segment_length / float(PRIMARY_STEPS);
		float view_rayleigh_od = 0.0;
		float view_mie_od = 0.0;
		float view_ozone_od = 0.0;
		vec3 total_rayleigh = vec3(0.0);
		vec3 total_mie = vec3(0.0);
		float mu = dot(dir, sun_dir);
		float phase_r = rayleigh_phase(mu);
		float phase_m = mie_phase(mu);

		for (int i = 0; i < PRIMARY_STEPS; i++) {
			float t = atmosphere_near + (float(i) + 0.5) * step_size;
			vec3 sample_point = ray_origin + dir * t;
			float density_r = rayleigh_density(sample_point);
			float density_m = mie_density(sample_point);
			float density_o = ozone_density(sample_point);

			view_rayleigh_od += density_r * step_size;
			view_mie_od += density_m * step_size;
			view_ozone_od += density_o * step_size;

			vec3 sun_transmittance = sample_transmittance_lut(transmittance_texture_index, sample_point, sun_dir);
			vec3 view_transmittance = exp(-compute_view_tau(view_rayleigh_od, view_mie_od, view_ozone_od));
			vec3 transmittance = sun_transmittance * view_transmittance;

			total_rayleigh += density_r * transmittance * step_size;
			total_mie += density_m * transmittance * step_size;
		}

		vec3 scattered_light = ATMOSPHERE_SUN_INTENSITY * (
			phase_r * RAYLEIGH_BETA * total_rayleigh +
			phase_m * MIE_BETA * total_mie
		);

		return scattered_light;
	}

	vec3 get_sun_disc(vec3 dir, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index) {
		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);
		vec2 ground_hit = ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS);
		if (ground_hit.x > 0.0) return vec3(0.0);

		float sun_angular_radius = SUN_RADIUS / SUN_DISTANCE;
		float theta = acos(clamp(dot(normalize(dir), normalize(sun_dir)), -1.0, 1.0));
		float disk = smoothstep(sun_angular_radius * 1.04, sun_angular_radius * 0.96, theta);
		float corona_inner = exp(-theta / max(sun_angular_radius * 5.5, 1e-5));
		float corona_outer = exp(-theta / max(sun_angular_radius * 8.0, 1e-5));
		vec3 radiance = vec3(16.0 * disk) + vec3(1.0, 0.95, 0.86) * (2.0 * corona_inner) + vec3(1.0, 0.98, 0.95) * corona_outer;
		vec3 transmittance = sample_transmittance_lut(transmittance_texture_index, ray_origin, sun_dir);
		float horizon_fade = smoothstep(-0.12, 0.04, sun_dir.y);
		return radiance * ATMOSPHERE_SUN_INTENSITY * transmittance  * horizon_fade;
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

local function create_transmittance_texture()
	local tex = Texture.New{
		width = 256,
		height = 64,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	tex:Shade(transmittance_glsl)
	return tex
end

local function destroy_sky_view_texture(key)
	local tex = atmosphere.sky_view_textures[key]

	if tex and tex.Remove then tex:Remove() end

	atmosphere.sky_view_textures[key] = nil
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
	local transmittance_texture = atmosphere.GetTransmittanceTexture()
	local tex = Texture.New{
		width = SKY_VIEW_LUT_WIDTH,
		height = SKY_VIEW_LUT_HEIGHT,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	tex:Shade(
		build_sky_view_glsl(cam_pos, sun_dir),
		{
			custom_declarations = [[
				#define TEXTURE(idx) textures[nonuniformEXT(idx)]
			]],
			textures = {transmittance_texture},
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

function atmosphere.GetSkyViewTexture(cam_pos, sun_dir)
	local key = get_sky_view_texture_key(cam_pos, sun_dir)
	local tex = atmosphere.sky_view_textures[key]

	if tex and tex:IsValid() then return tex end

	destroy_sky_view_texture(key)
	tex = create_sky_view_texture(cam_pos, sun_dir)
	atmosphere.sky_view_textures[key] = tex
	table.insert(atmosphere.sky_view_texture_order, key)

	while #atmosphere.sky_view_texture_order > SKY_VIEW_TEXTURE_CACHE_LIMIT do
		local oldest = table.remove(atmosphere.sky_view_texture_order, 1)

		if oldest ~= key then destroy_sky_view_texture(oldest) end
	end

	return tex
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

		vec3 apply_surface_aerial_perspective(vec3 scene_color, vec3 world_pos, vec3 sun_dir, vec3 cam_pos, int transmittance_texture_index) {
			return apply_atmospheric_aerial_perspective(scene_color, world_pos, sun_dir, cam_pos, transmittance_texture_index, 1.0);
		}
	]]
end

function atmosphere.GetGLSLMainCode(
	dir_var,
	sun_dir_var,
	cam_pos_var,
	stars_texture_index_var,
	sky_view_texture_index_var,
	transmittance_texture_index_var,
	time_var,
	planet_occlusion_mode,
	blue_noise_texture_index_var,
	include_clouds_var
)
	sky_view_texture_index_var = sky_view_texture_index_var or "-1"
	transmittance_texture_index_var = transmittance_texture_index_var or "-1"
	time_var = time_var or "0.0"
	blue_noise_texture_index_var = blue_noise_texture_index_var or "-1"
	include_clouds_var = include_clouds_var or "true"
	local occlusion_color_expr = "get_probe_ground_occlusion_color(atmos_dir, atmos_sun_dir, " .. cam_pos_var .. ")"
	return [[
		{
			vec3 atmos_dir = normalize(]] .. dir_var .. [[);
			vec3 atmos_sun_dir = normalize(]] .. sun_dir_var .. [[);
			vec3 camera_origin = get_atmosphere_camera_origin(]] .. cam_pos_var .. [[);
			vec3 up = normalize(camera_origin);
			bool planet_occluded = ray_hits_planet(atmos_dir, ]] .. cam_pos_var .. [[);
			vec3 atmosphere_color = sample_sky_view_lut(]] .. sky_view_texture_index_var .. [[, atmos_dir, atmos_sun_dir, ]] .. cam_pos_var .. [[);
			atmosphere_color += get_sun_disc(atmos_dir, atmos_sun_dir, ]] .. cam_pos_var .. [[, ]] .. transmittance_texture_index_var .. [[);
			if (]] .. include_clouds_var .. [[) {
				atmosphere_color = apply_2d_clouds(atmosphere_color, camera_origin, atmos_dir, atmos_sun_dir, up, ]] .. time_var .. [[, ]] .. blue_noise_texture_index_var .. [[);
			}
			float sun_elevation = atmos_sun_dir.y;
			float day_factor = smoothstep(-0.16, 0.06, sun_elevation);
			float sky_luminance = dot(atmosphere_color, vec3(0.2126, 0.7152, 0.0722));
			float sky_brightness = clamp(sky_luminance * 0.5, 0.0, 1.0);
			float blend_factor = max(day_factor, sky_brightness);
			vec3 space_color = vec3(0.0);
			float lower_hemisphere_blend = smoothstep(-0.4, 0.12, dot(atmos_dir, up));

			if (]] .. stars_texture_index_var .. [[ != -1) {
				float u = atan(atmos_dir.z, atmos_dir.x) / (2.0 * PI) + 0.5;
				float v = asin(clamp(atmos_dir.y, -1.0, 1.0)) / PI + 0.5;
				space_color = texture(TEXTURE(]] .. stars_texture_index_var .. [[), vec2(u, -v)).rgb;
				space_color = pow(space_color, vec3(10.0));
				space_color *= 0.5;
			} else {
				space_color = get_stars(atmos_dir, atmos_sun_dir);
			}

			if (planet_occluded) {
				sky_color_output = mix(]] .. occlusion_color_expr .. [[, atmosphere_color + ]] .. occlusion_color_expr .. [[, lower_hemisphere_blend);
			} else {
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

function atmosphere.GetAmbientColor(sunDir)
	local sunHeight = sunDir.y
	local dayAmbient = Vec3(0.4, 0.6, 0.9) * 0.3
	local sunsetAmbient = Vec3(0.8, 0.4, 0.2) * 0.15
	local nightAmbient = Vec3(0.05, 0.08, 0.15) * 0.05

	if sunHeight > 0.0 then
		return sunsetAmbient:GetLerped(sunHeight ^ 0.5, dayAmbient)
	end

	local t = math.min(math.max(sunHeight + 0.2, 0.0), 1.0) / 0.2
	return nightAmbient:GetLerped(t, sunsetAmbient)
end

if HOTRELOAD then
	destroy_transmittance_texture()
	destroy_all_sky_view_textures()
end

return atmosphere
