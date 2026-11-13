local glsl_common = import("goluwa/render3d/glsl_common.lua")
local medium_common = {}
medium_common.assumed_thickness = 0
medium_common.base_height = -1e9
medium_common.thickness_per_height = 0
medium_common.cover_slope = 0
medium_common.porosity_low = 0.1
medium_common.porosity_high = 1.0
medium_common.local_thickness = true

function medium_common.GetGLSL()
	return glsl_common.GetPhaseGLSL() .. [[
	#ifndef MEDIUM_COMMON
	#define MEDIUM_COMMON
	#define MEDIUM_MAX_PATH 60.0
	#define MEDIUM_VIEW_DEPTH_CAP 20.0
	#define MEDIUM_EXPOSURE_RANGE 4.0
	#define MEDIUM_PANE_PATH 0.05
	#define MEDIUM_BOUNCE_SHARE 0.6
	#define MEDIUM_TRANSMIT_SHARE 1.0
	#define MEDIUM_SCATTER_ORDERS 5
	#define MEDIUM_ORDER_EXTINCTION 0.3
	#define MEDIUM_ORDER_SCATTERING 0.55

	vec3 optical_transmittance(vec3 extinction, float path) {
		return exp(-extinction * path);
	}

	float medium_molecular_phase(float mu) {
		return (1.0 + 0.835 * mu * mu) / (4.0 * PI * (1.0 + 0.835 / 3.0));
	}

	vec3 medium_scatter_phase(vec3 molecular, vec3 particles, float g, float mu) {
		return molecular * medium_molecular_phase(mu) + particles * phase_henyey_greenstein(mu, g);
	}

	vec3 medium_multiple_scattering(vec3 optical_depth, float mu, float forward_g, float back_g, float back_share, float multiple) {
		vec3 sum = vec3(0.0);
		float a = 1.0;
		float b = 1.0;
		float c = 1.0;

		for (int order = 0; order < MEDIUM_SCATTER_ORDERS; order++) {
			float phase = mix(phase_henyey_greenstein(mu, forward_g * c), phase_henyey_greenstein(mu, back_g * c), back_share);
			sum += (order == 0 ? 1.0 : b * multiple) * phase * exp(-optical_depth * a);
			a *= MEDIUM_ORDER_EXTINCTION;
			b *= MEDIUM_ORDER_SCATTERING;
			c *= 0.5;
		}

		return sum;
	}

	float medium_refracted_cosine(float cos_incident, float ior) {
		return sqrt(max(1.0 - (1.0 - cos_incident * cos_incident) / (ior * ior), 1e-4));
	}

	vec3 medium_scattering_at(vec3 base, vec3 porous, float porosity) {
		return base + porous * porosity * porosity;
	}

	float medium_scatter_probability(vec3 scattering, float thickness) {
		return 1.0 - exp(-dot(scattering, vec3(1.0 / 3.0)) * thickness);
	}

	float medium_reduced_scattering(vec3 scattering, float g) {
		return dot(scattering, vec3(1.0 / 3.0)) * (1.0 - g);
	}

	vec3 medium_transmittance(vec3 absorption, vec3 scattering, float g, float path) {
		return optical_transmittance(absorption + scattering * (1.0 - g), path);
	}

	vec3 medium_body_reflectance(vec3 absorption, vec3 scattering, float g) {
		vec3 reduced = scattering * (1.0 - g);
		vec3 albedo = reduced / max(reduced + absorption, vec3(1e-6));
		vec3 s = sqrt(max(1.0 - albedo, vec3(0.0)));
		return (1.0 - s) * (1.0 - 0.139 * s) / (1.0 + 1.17 * s);
	}

	vec3 medium_scatter_color(vec3 absorption, vec3 scattering, float g, float thickness) {
		float depth = min(thickness, MEDIUM_VIEW_DEPTH_CAP);
		return mix(optical_transmittance(absorption, depth), medium_body_reflectance(absorption, scattering, g), medium_scatter_probability(scattering, depth));
	}

	vec3 exponential_layer_transmittance(float altitude, float sun_up, float extinction, float precipitation_extinction, float scale_height, float start, float top, vec3 tint) {
		if (altitude >= top) return vec3(1.0);

		altitude = max(altitude, 0.0);
		float below_start = max(start - altitude, 0.0);
		float above_start = max(altitude - start, 0.0);
		float fog_depth = extinction * (below_start + scale_height * (exp(-above_start / scale_height) - exp(-(top - start) / scale_height)));
		float precipitation_depth = precipitation_extinction * (top - altitude);
		return exp(-(fog_depth * tint + precipitation_depth) / max(sun_up, 0.05));
	}

	bool medium_box_intersect(mat4 to_local, vec3 box_min, vec3 box_max, vec3 ray_origin, vec3 ray_dir, out float t_entry, out float t_exit) {
		vec3 origin = (to_local * vec4(ray_origin, 1.0)).xyz;
		vec3 dir = (to_local * vec4(ray_dir, 0.0)).xyz;
		dir = mix(dir, vec3(1e-7), lessThan(abs(dir), vec3(1e-7)));
		vec3 inv = 1.0 / dir;
		vec3 ta = (box_min - origin) * inv;
		vec3 tb = (box_max - origin) * inv;
		t_entry = max(max(min(ta, tb).x, min(ta, tb).y), min(ta, tb).z);
		t_exit = min(min(max(ta, tb).x, max(ta, tb).y), max(ta, tb).z);
		return t_exit > max(t_entry, 0.0);
	}

	bool medium_volume_intersect(mat4 to_local, vec3 shape, float top_offset, vec3 ray_origin, vec3 ray_dir, out float t_entry, out float t_exit, out bool top) {
		vec3 local_dir = (to_local * vec4(ray_dir, 0.0)).xyz;
		bool hit = medium_box_intersect(to_local, vec3(-shape.x, -shape.y, -shape.z), vec3(shape.x, top_offset, shape.z), ray_origin, ray_dir, t_entry, t_exit);
		vec3 local_origin = (to_local * vec4(ray_origin, 1.0)).xyz;
		top = local_dir.y < 0.0 && abs(t_entry - (top_offset - local_origin.y) / local_dir.y) < 1e-4;
		return hit;
	}
	#endif
]]
end

function medium_common.GetShaftGLSL(options)
	return "vec3 " .. options.name .. "(" .. options.params .. [[, vec3 shaft_origin, vec3 shaft_dir, float shaft_length, int shaft_samples, float shaft_jitter, vec3 shaft_attenuation) {
		vec3 shaft_sum = vec3(0.0);

		for (int i = 0; i < shaft_samples; i++) {
			float f0 = float(i) / float(shaft_samples);
			float f1 = float(i + 1) / float(shaft_samples);
			float f = (float(i) + shaft_jitter) / float(shaft_samples);
			float s = shaft_length * f * f;
			vec3 p = shaft_origin + shaft_dir * s;
			shaft_sum += (]] .. options.sample .. [[) * exp(-shaft_attenuation * s) * (shaft_length * (f1 * f1 - f0 * f0));
		}

		return shaft_sum;
	}
	]]
end

return medium_common
