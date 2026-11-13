local medium_common = {}
medium_common.assumed_thickness = 0
medium_common.base_height = -1e9
medium_common.thickness_per_height = 0
medium_common.scatter_coefficient = 0.25
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

	vec3 medium_transmittance(vec3 extinction, float path, float porosity) {
		return mix(optical_transmittance(extinction, path), optical_transmittance(extinction, path * 0.35), porosity);
	}

	float medium_scatter_amount(float thickness) {
		return 1.0 - exp(-thickness);
	}

	vec3 medium_scatter_color(vec3 extinction, vec3 porous_color, float thickness, float porosity) {
		vec3 tint = exp(-min(thickness, MEDIUM_VIEW_DEPTH_CAP) * extinction * (1.0 - 0.6 * porosity));
		return mix(tint, porous_color, porosity * porosity);
	}
	#endif
]]
end

return medium_common
