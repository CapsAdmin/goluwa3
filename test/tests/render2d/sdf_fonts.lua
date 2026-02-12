local T = require("test.environment")
local ffi = require("ffi")
local render = require("render.render")
local render2d = require("render2d.render2d")
local Polygon2D = require("render2d.polygon_2d")
local fonts = require("render2d.fonts")
local fs = require("fs")
local width = 512
local height = 512

T.Test2D("test", function()
	local font_small = fonts.LoadFont(fonts.GetSystemDefaultFont(), 256)
	render2d.SetColor(0, 1, 0, 1)
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	font_small:DrawText("Hg", 10, 10)
	return function()
		T.Screenshot("fonts.png")
		-- this results in a black png with the alpha cut out where the text is supposed to be
		T.AssertScreenPixel({
			pos = {49, 78},
			color = {0, 1, 0, 1},
			tolerance = 0.5,
		})
	end
end)
