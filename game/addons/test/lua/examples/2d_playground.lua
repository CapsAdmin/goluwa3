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
		size = 30,
		shadow = {
			dir = -2,
			color = Color.FromHex("#022d58"):SetAlpha(0.75),
			blur_radius = 0.25,
			blur_passes = 1,
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
			color = Color(1, 1, 1, 1),
			blur_radius = 1,
			blur_passes = 2,
			alpha_pow = 1,
		},
		padding = 2,
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
	font_shadow:DrawText("Gameplay", 20, 150)
	--local tex = font_shadow.texture_atlas:GetTextures()[1]
	--render2d.SetTexture(tex)
	--render2d.DrawRect(50, 50, 512, 512)
	font_simple:DrawText("Normal Text", 20, 200)
	font_glow:DrawText("Glow Text", 20, 250)
end)
