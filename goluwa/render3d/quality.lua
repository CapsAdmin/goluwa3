local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local quality = {}
quality.PRESETS = {
	low = {
		disabled_passes = {
			volumetric_fog = true,
			clouds = true,
			reflections = true,
			ambient_occlusion = true,
			motion_blur = true,
			dof = true,
		},
		froxel_tile = 12,
		cloud_step_scale = 0.5,
		shadow_size_scale = 0.25,
		screen_shadow_step_scale = 0,
	},
	medium = {
		disabled_passes = {motion_blur = true, dof = true},
		froxel_tile = 12,
		cloud_step_scale = 0.5,
		shadow_size_scale = 0.5,
		screen_shadow_step_scale = 0.5,
	},
	high = {
		disabled_passes = {},
		froxel_tile = 6,
		cloud_step_scale = 1,
		shadow_size_scale = 1,
		screen_shadow_step_scale = 1,
	},
}
local preset

local function resolve(value)
	if value == "auto" then
		value = render.GetDevice().ray_tracing_supported and "high" or "medium"
	end

	return quality.PRESETS[value]
end

pvars.StartGroup("Rendering", "Quality")
pvars.Setup2{
	key = "r_quality",
	default = "auto",
	enums = {"auto", "low", "medium", "high"},
	help = "high runs every pass at full detail. medium turns off motion blur and depth of field and halves the fog grid, cloud steps, screen space shadow steps and shadow map sizes. low also turns off volumetric fog, clouds, reflections, ambient occlusion and screen space shadows and quarters the shadow maps. auto is high with ray tracing hardware and medium without",
	callback = function(value, init)
		if init then return end

		preset = resolve(value)
		event.Call("RenderQualityChanged", preset)
	end,
}
pvars.EndGroup()

function quality.Get()
	if not preset then preset = resolve(pvars.Get("r_quality")) end

	return preset
end

return quality
