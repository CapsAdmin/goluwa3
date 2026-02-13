local event = require("event")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local gfx = require("render2d.gfx")
local fonts = require("render2d.fonts")
local path = fonts.GetDefaultSystemFontPath()
local font_simple = fonts.New({Path = path, Size = 50})
local font_shadow = fonts.New(
	{
		Path = path,
		Size = 30,
		Shadow = {
			Dir = Vec2() + -2,
			Color = Color.FromHex("#022d58"):SetAlpha(0.75),
			BlurRadius = 0.25,
			BlurPasses = 1,
		},
	}
)
local font_glow = fonts.New(
	{
		Path = path,
		Size = 50,
		Padding = 2,
		Shadow = {
			Dir = Vec2(),
			Color = Color(1, 1, 1, 1),
			BlurRadius = 1,
			BlurPasses = 2,
			AlphaPow = 1,
		},
	}
)

-- Force render2d pipeline to rebuild after font shading operations
local function bg()
	render2d.SetColor(0.5, 0.5, 0.5, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, 9999, 9999)
end

event.AddListener("Draw2D", "test_2d", function()
	local r, g, b, a = Color.FromHex("#08feff"):Unpack()
	render2d.SetColor(r, g, b, a)
	--font_shadow:DrawText("Gameplay", 20, 150)
	--font_glow:DrawText("Glow Text", 20, 250)
	font_simple:DrawText("Hg", 20, 200)
	render2d.SetColor(1, 0, 0, 0.2)
	render2d.SetTexture(nil)
	local w, h = font_simple:GetTextSize("Hg")
	render2d.DrawRect(20, 200, w, h)
end)
