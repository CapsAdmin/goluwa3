local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Color = import("goluwa/structs/color.lua")
local rainbow = render2d.CreateGradient{
	mode = "linear",
	angle = 90, -- Horizontal
	repeat_texture = true,
	stops = {
		{pos = 0.0, color = Color(1, 0, 0, 1)},
		{pos = 0.2, color = Color(1, 1, 0, 1)},
		{pos = 0.4, color = Color(0, 1, 0, 1)},
		{pos = 0.6, color = Color(0, 1, 1, 1)},
		{pos = 0.8, color = Color(0, 0, 1, 1)},
		{pos = 1.0, color = Color(1, 0, 1, 1)},
	},
}
local radial = render2d.CreateGradient{
	mode = "radial",
	stops = {
		{pos = 0.0, color = Color(1, 1, 1, 1)},
		{pos = 1.0, color = Color(0, 0, 0, 0)},
	},
}

event.AddListener("Draw2D", "render2d_gradient_demo", function()
	render2d.SetTexture(nil)
	local x, y = 100, 100
	local w, h = 400, 100
	-- 1. Rainbow Linear Gradient Rect
	render2d.PushTexture(rainbow)
	render2d.PushBorderRadius(10)
	render2d.PushColorUV()
	render2d.DrawRect(x, y, w, h)
	-- 2. Rainbow TEXT - default
	y = y + 150
	render2d.DrawText{text = "FOO", x = x, y = y, size = 64}
	-- 2b. Tiled texture (2x2)
	y = y + 80
	render2d.SetColorUV(math.sin(os.clock() * 2) * 2, 0, 5, 1, math.pi / 2)
	render2d.DrawText{text = "BAR", x = x, y = y, size = 64}
	-- 2c. Rotated texture
	y = y + 80
	render2d.SetTexture(radial)
	render2d.SetColor(0.5, 1, 0.5, 1)
	render2d.SetColorUV(-0.5, 0, 2, 1, math.pi)
	render2d.DrawText{text = "BAZ", x = x, y = y, size = 64}
	render2d.PopTexture()
	-- 3. Radial Glow Rect
	x = 100
	y = y + 150
	render2d.PushTexture(radial)
	render2d.PushColor(0.2, 0.6, 1.0, 1.0) -- Tint the gradient
	render2d.SetColorUV(0, 0, 1, 1, math.sin(os.clock()) * 4)
	render2d.DrawRect(x, y, 200, 200)
	render2d.PopColor()
	render2d.PopTexture()
	render2d.PopBorderRadius()
	render2d.PopColorUV()
end)
