local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")

local function region_has_opaque_pixel(tex, min_x, min_y, max_x, max_y, min_alpha)
	for y = min_y, max_y do
		for x = min_x, max_x do
			local _, _, _, a = tex:GetPixel(x, y)

			if a / 255 >= min_alpha then return true end
		end
	end

	return false
end

T.Test2D("raster font draws opaque interior pixels", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 128,
		Padding = 2,
		Mode = "raster",
		Unique = true,
	}

	render2d.SetTexture(nil)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)

	return function()
		local tex = render.target:GetTexture()

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

		assert(region_has_opaque_pixel(tex, 12, 12, 90, 140, 0.7), "expected opaque pixels in the left glyph region")
		assert(region_has_opaque_pixel(tex, 70, 35, 170, 170, 0.7), "expected opaque pixels in the right glyph region")
	end
end)