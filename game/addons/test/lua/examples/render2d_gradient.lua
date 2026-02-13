local event = require("event")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local fonts = require("render2d.fonts")
local fontPath = fonts.GetDefaultSystemFontPath()
local font = fonts.New({Path = fontPath, Size = 64})
local rainbow = render2d.CreateGradient(
	{
		mode = "linear",
		angle = 90, -- Horizontal
		stops = {
			{pos = 0.0, color = Color(1, 0, 0, 1)},
			{pos = 0.2, color = Color(1, 1, 0, 1)},
			{pos = 0.4, color = Color(0, 1, 0, 1)},
			{pos = 0.6, color = Color(0, 1, 1, 1)},
			{pos = 0.8, color = Color(0, 0, 1, 1)},
			{pos = 1.0, color = Color(1, 0, 1, 1)},
		},
	}
)
local radial = render2d.CreateGradient(
	{
		mode = "radial",
		stops = {
			{pos = 0.0, color = Color(1, 1, 1, 1)},
			{pos = 1.0, color = Color(0, 0, 0, 0)},
		},
	}
)

event.AddListener("Draw2D", "render2d_gradient_demo", function()
	render2d.SetTexture(nil)
	local x, y = 100, 100
	local w, h = 400, 100
	-- 1. Rainbow Linear Gradient Rect
	render2d.PushSDFGradientTexture(rainbow)
	render2d.PushBorderRadius(10)
	render2d.DrawRect(x, y, w, h)
	-- 2. Rainbow TEXT
	y = y + 150
	render2d.PushSDFMode(true)
	font:DrawText("RAINBOW SDF TEXT", x, y)
	render2d.PopSDFMode()
	render2d.PopSDFGradientTexture()
	-- 3. Radial Glow Rect
	x = 100
	y = y + 150
	render2d.PushSDFGradientTexture(radial)
	render2d.PushColor(0.2, 0.6, 1.0, 1.0) -- Tint the gradient
	render2d.DrawRect(x, y, 200, 200)
	render2d.PopColor()
	render2d.PopSDFGradientTexture()
	render2d.PopBorderRadius()
end)
