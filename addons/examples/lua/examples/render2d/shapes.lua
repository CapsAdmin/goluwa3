local assets = import("goluwa/assets.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local gradient_tex = render2d.CreateGradient{
	width = 256,
	height = 1,
	mode = "linear",
	angle = 90,
	stops = {
		{pos = 0, color = Color(1, 0.2, 0.3, 1)},
		{pos = 0.3, color = Color(1, 0.6, 0.1, 1)},
		{pos = 0.6, color = Color(0.3, 1, 0.2, 1)},
		{pos = 1, color = Color(0.2, 0.4, 1, 1)},
	},
}

event.AddListener("Draw2D", "test", function()
	local light_angle = math.rad(45)
	render2d.SetLighting(true)
	render2d.SetBevelWidth(15)
	render2d.SetBevelHeight(0)
	render2d.SetLightAngle(light_angle)
	render2d.SetLightShininess(10)
	render2d.SetLightColor(1, 1, 1)
	render2d.SetAmbientColor(0.5, 0.5, 0.5)
	render2d.PushTexture(gradient_tex)
	render2d.PushClampBorderRadius(false)
	render2d.DrawShape{
		color = Color(0, 1, 1, 1),
		border_radius = 0,
		shadow_x = 8,
		shadow_y = 8,
		shadow_softness = 2,
		outline_width = 20,
		softness = 50,
		outline_color = Color(1, 0, 0, 1),
		skew_x = 0,
		x = 50,
		y = 50,
		w = 200,
		h = 200,
	}
	render2d.PopClampBorderRadius()
	render2d.PopTexture()
	render2d.SetLighting(false)
end)
