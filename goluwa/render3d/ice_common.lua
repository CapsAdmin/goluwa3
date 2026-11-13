local ice_common = {}
ice_common.assumed_thickness = 0
ice_common.base_height = -1e9
ice_common.thickness_per_height = 0
ice_common.scatter_coefficient = 0.25
ice_common.snow_slope = 0
ice_common.GLSL = [[
	#ifndef ICE_COMMON
	#define ICE_COMMON
	#define ICE_MAX_PATH 60.0
	#define ICE_VIEW_DEPTH_CAP 20.0
	#define ICE_EXPOSURE_RANGE 4.0
	#define ICE_EXTINCTION vec3(0.19, 0.058, 0.012)
	#define ICE_TINT_RATIO vec3(1.0, 0.7, 0.55)
	#define ICE_DEEP_COLOR vec3(0.02, 0.21, 0.71)
	#define ICE_POROUS_COLOR vec3(0.92, 0.96, 1.0)
	#endif
]]
return ice_common
