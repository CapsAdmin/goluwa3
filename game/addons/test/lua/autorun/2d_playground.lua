local event = require("event")
local render2d = require("render2d.render2d")
local Color = require("structs.color")
local gfx = require("render2d.gfx")
local fonts = require("render2d.fonts")
local path = fonts.GetSystemDefaultFont()
local font_simple = fonts.LoadFont(path, 50)
local font_shadow = fonts.CreateFont(
	{
		path = path,
		size = 50,
		shadow = {
			dir = 0,
			color = Color(0, 0, 0, 1),
			blur_radius = 1,
			blur_passes = 5,
		},
	--color = {color = Color(0, 0, 1, 1)},
	}
)
local font_glow = fonts.CreateFont(
	{
		path = path,
		size = 50,
		shadow = {
			dir = 0,
			color = Color(1, 0.5, 0, 1),
			blur_radius = 5,
			blur_passes = 5,
			alpha_pow = 2,
		},
		padding = 20,
	}
)

-- Force render2d pipeline to rebuild after font shading operations
local function bg()
	render2d.SetColor(0.5, 0.5, 0.5, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(0, 0, 9999, 9999)
end

event.AddListener("Draw2D", "test_2d", function()
	render2d.SetColor(1, 1, 1, 1)
	font_shadow:DrawText("The quick brown fox jumps over the lazy dog!!!!!", 20, 80)
	--local tex = font_shadow.texture_atlas:GetTextures()[1]
	--render2d.SetTexture(tex)
	--render2d.DrawRect(50, 50, 512, 512)
	font_simple:DrawText("Normal Text", 20, 20)
	font_glow:DrawText("Glow Text", 20, 140)
end)
