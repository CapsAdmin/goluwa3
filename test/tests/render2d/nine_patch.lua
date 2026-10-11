local T = import("test/environment.lua")
local ffi = require("ffi")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")

local function create_texture()
	local data = ffi.new("uint8_t[?]", 16 * 16 * 4)

	for y = 0, 15 do
		for x = 0, 15 do
			local edge_x = x < 4 or x >= 12
			local edge_y = y < 4 or y >= 12
			local r, g, b = 0, 0, 255

			if edge_x and edge_y then
				r, g, b = 255, 0, 0
			elseif edge_x or edge_y then
				r, g, b = 0, 255, 0
			end

			local i = (y * 16 + x) * 4
			data[i], data[i + 1], data[i + 2], data[i + 3] = r, g, b, 255
		end
	end

	return Texture.New{
		buffer = data,
		width = 16,
		height = 16,
		format = "r8g8b8a8_unorm",
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

T.Test2D("Graphics render2d DrawNinePatch keeps the corners and stretches the rest", function()
	local texture = create_texture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawNinePatch(texture, 0, 0, 16, 16, 4, 4, 4, 4, 20, 20, 64, 48)
	return function()
		T.AssertScreenPixel{pos = {22, 22}, color = {1, 0, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {82, 66}, color = {1, 0, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {50, 22}, color = {0, 1, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {22, 44}, color = {0, 1, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {52, 44}, color = {0, 0, 1, 1}, tolerance = 0.02}
	end
end)

T.Test2D("Graphics render2d DrawNinePatch scales the borders down for a small target", function()
	local texture = create_texture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawNinePatch(texture, 0, 0, 16, 16, 4, 4, 4, 4, 20, 20, 6, 6)
	return function()
		T.AssertScreenPixel{pos = {21, 21}, color = {1, 0, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {24, 24}, color = {1, 0, 0, 1}, tolerance = 0.02}
	end
end)

T.Test2D("Graphics render2d DrawNinePatch draws an atlas region", function()
	local texture = create_texture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawNinePatch(texture, 4, 4, 8, 8, 0, 0, 0, 0, 20, 20, 32, 32)
	return function()
		T.AssertScreenPixel{pos = {30, 30}, color = {0, 0, 1, 1}, tolerance = 0.02}
	end
end)

T.Test2D("Graphics render2d DrawNinePatch regions use image space with y pointing down", function()
	local data = ffi.new("uint8_t[?]", 16 * 16 * 4)

	for y = 0, 15 do
		for x = 0, 15 do
			local i = (y * 16 + x) * 4

			if y < 8 then
				data[i], data[i + 1], data[i + 2], data[i + 3] = 255, 0, 0, 255
			else
				data[i], data[i + 1], data[i + 2], data[i + 3] = 0, 0, 255, 255
			end
		end
	end

	local texture = Texture.New{
		buffer = data,
		width = 16,
		height = 16,
		format = "r8g8b8a8_unorm",
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawNinePatch(texture, 0, 0, 16, 8, 0, 0, 0, 0, 20, 20, 16, 8)
	render2d.DrawNinePatch(texture, 0, 8, 16, 8, 0, 0, 0, 0, 20, 40, 16, 8)
	return function()
		T.AssertScreenPixel{pos = {28, 24}, color = {0, 0, 1, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {28, 44}, color = {1, 0, 0, 1}, tolerance = 0.02}
	end
end)

T.Test2D("Graphics render2d DrawNinePatch draws at 1:1 without shifting the edge texels under a margin override", function()
	local data = ffi.new("uint8_t[?]", 16 * 16 * 4)

	for y = 0, 15 do
		for x = 0, 15 do
			local i = (y * 16 + x) * 4

			if x == 0 then
				data[i], data[i + 1], data[i + 2], data[i + 3] = 255, 0, 0, 255
			elseif x == 1 then
				data[i], data[i + 1], data[i + 2], data[i + 3] = 0, 255, 0, 255
			else
				data[i], data[i + 1], data[i + 2], data[i + 3] = 0, 0, 255, 255
			end
		end
	end

	local texture = Texture.New{
		buffer = data,
		width = 16,
		height = 16,
		format = "r8g8b8a8_unorm",
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushMargin(2)
	render2d.DrawNinePatch(texture, 0, 0, 16, 16, 0, 0, 0, 0, 20, 20, 16, 16)
	render2d.PopMargin()
	return function()
		T.AssertScreenPixel{pos = {20, 28}, color = {1, 0, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {21, 28}, color = {0, 1, 0, 1}, tolerance = 0.02}
		T.AssertScreenPixel{pos = {22, 28}, color = {0, 0, 1, 1}, tolerance = 0.02}
	end
end)
