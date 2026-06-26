local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")

T.Test2D("sdf font draws opaque interior pixels", function()
	local font = fonts.New{
		Size = 128,
		Padding = 2,
		Mode = "sdf",
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	assert(font:IsReady())
	font:DrawText("Hg", 10, 10)
	return function()
		local tex = render.target:GetTexture()
		tex:Download():SaveAs("tmp/raster_sdf.png")
		T.AssertScreenPixel{
			pos = {26, 47},
			color = {1, 1, 1, 1},
			tolerance = 0.35,
		}
		T.AssertScreenPixel{
			pos = {6, 6},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)
