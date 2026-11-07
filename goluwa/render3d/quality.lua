local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local render = import("goluwa/render/render.lua")
local android = import("goluwa/bindings/android.lua")
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
		android_render_height = 360,
	},
	medium = {
		disabled_passes = {motion_blur = true, dof = true},
		froxel_tile = 12,
		cloud_step_scale = 0.5,
		shadow_size_scale = 0.5,
		screen_shadow_step_scale = 0.5,
		android_render_height = 540,
	},
	high = {
		disabled_passes = {},
		froxel_tile = 6,
		cloud_step_scale = 1,
		shadow_size_scale = 1,
		screen_shadow_step_scale = 1,
		android_render_height = 0,
	},
}
local preset

local function resolve(value)
	if value == "auto" then
		if android.active then
			value = "low"
		else
			value = render.GetDevice().ray_tracing_supported and "high" or "medium"
		end
	end

	return quality.PRESETS[value]
end

pvars.StartGroup("Rendering", "Quality")
pvars.Setup2{
	key = "r_quality",
	default = "auto",
	enums = {"auto", "low", "medium", "high"},
	help = "high runs every pass at full detail. medium turns off motion blur and depth of field and halves the fog grid, cloud steps, screen space shadow steps and shadow map sizes. low also turns off volumetric fog, clouds, reflections, ambient occlusion and screen space shadows and quarters the shadow maps. auto is low on android, otherwise high with ray tracing hardware and medium without. on android the preset also picks the height of the render buffers (low 360, medium 540, high native) when the app starts",
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
