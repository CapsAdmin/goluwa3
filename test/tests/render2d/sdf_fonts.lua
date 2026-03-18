local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local fs = import("goluwa/fs.lua")
local width = 512
local height = 512

T.Test2D("sdf font", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 256,
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		T.AssertScreenPixel{
			pos = {48, 99},
			color = {1, 1, 1, 1},
			tolerance = 0.5,
		}
	end
end)

T.Test2D("non sdf font", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 256,
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		T.AssertScreenPixel{
			pos = {48, 99},
			color = {1, 1, 1, 1},
			tolerance = 0.5,
		}
	end
end)
