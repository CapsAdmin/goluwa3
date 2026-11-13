local pvars = import("goluwa/cli/pvars.lua")
local medium_common = {}
medium_common.assumed_thickness = 0
medium_common.base_height = -1e9
medium_common.thickness_per_height = 0
medium_common.scatter_coefficient = 0.25
medium_common.cover_slope = 0
medium_common.presets = {
	ice = {
		extinction = {0.19, 0.058, 0.012},
		tint_ratio = {1.0, 0.7, 0.55},
		deep_color = {0.02, 0.21, 0.71},
		porous_color = {0.92, 0.96, 1.0},
	},
	water = {
		extinction = {0.19, 0.058, 0.012},
		tint_ratio = {1.0, 0.7, 0.55},
		deep_color = {0.02, 0.21, 0.71},
		porous_color = {0.78, 0.88, 0.92},
	},
}
pvars.StartGroup("Lighting", "Absorbing medium", {store = false})
medium_common.preset = pvars.Setup2{
	key = "medium_preset",
	default = "ice",
	help = "the absorbing medium every `MediumAbsorption` material is made of (a key of `medium_common.presets`: per channel extinction in 1/m, the deep colour of a thick body, the matte colour of porous cover). built into the shaders",
}
pvars.EndGroup()

do
	local function vec3(values)
		return string.format("vec3(%.5f, %.5f, %.5f)", values[1], values[2], values[3])
	end

	function medium_common.GetGLSL(preset_name)
		local preset = assert(medium_common.presets[preset_name or medium_common.preset:Get()], "unknown medium preset")
		return string.format(
		[[
	#ifndef MEDIUM_COMMON
	#define MEDIUM_COMMON
	#define MEDIUM_MAX_PATH 60.0
	#define MEDIUM_VIEW_DEPTH_CAP 20.0
	#define MEDIUM_EXPOSURE_RANGE 4.0
	#define MEDIUM_EXTINCTION %s
	#define MEDIUM_TINT_RATIO %s
	#define MEDIUM_DEEP_COLOR %s
	#define MEDIUM_POROUS_COLOR %s
	#endif
]],
		vec3(preset.extinction),
		vec3(preset.tint_ratio),
		vec3(preset.deep_color),
		vec3(preset.porous_color)
		)
	end
end

return medium_common
