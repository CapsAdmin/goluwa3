local medium_common = {}
medium_common.assumed_thickness = 0
medium_common.base_height = -1e9
medium_common.thickness_per_height = 0
medium_common.cover_slope = 0
medium_common.porosity_low = 0.1
medium_common.porosity_high = 1.0
medium_common.local_thickness = true

function medium_common.GetGLSL()
	return [[
	#ifndef MEDIUM_COMMON
	#define MEDIUM_COMMON
	#define MEDIUM_MAX_PATH 60.0
	#define MEDIUM_VIEW_DEPTH_CAP 20.0
	#define MEDIUM_EXPOSURE_RANGE 4.0
	#define MEDIUM_PANE_PATH 0.05
	#define MEDIUM_BOUNCE_SHARE 0.6
	#define MEDIUM_TRANSMIT_SHARE 1.0

	vec3 optical_transmittance(vec3 extinction, float path) {
		return exp(-extinction * path);
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

return medium_common
