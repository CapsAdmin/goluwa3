local T = import("test/environment.lua")
local ffi = require("ffi")
local lut = import("goluwa/codecs/lut.lua")
local png = import("goluwa/codecs/png.lua")

local function cube_rows(size, fn)
	local rows = {}

	for blue = 0, size - 1 do
		for green = 0, size - 1 do
			for red = 0, size - 1 do
				local a, b, c = fn(red / (size - 1), green / (size - 1), blue / (size - 1))
				rows[#rows + 1] = string.format("%.6f %.6f %.6f", a, b, c)
			end
		end
	end

	return table.concat(rows, "\n")
end

local function entry(result, red, green, blue)
	local i = (red + green * result.size + blue * result.size * result.size) * 3
	return result.data[i], result.data[i + 1], result.data[i + 2]
end

T.Test("lut cube reads a 3d table with red running fastest", function()
	local text = "# comment\nTITLE \"x\"\nLUT_3D_SIZE 3\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n\n" .. cube_rows(3, function(r, g, b)
			return r, g * 0.5, b * 0.25
		end)
	local result = lut.DecodeCube(text)
	T(result.size)["=="](3)
	T(result.shaper_size)["=="](nil)
	T(result.domain_min)["=="](0)
	T(result.domain_max)["=="](1)

	for blue = 0, 2 do
		for green = 0, 2 do
			for red = 0, 2 do
				local r, g, b = entry(result, red, green, blue)
				T(r)["~"](red / 2, 1e-6)
				T(g)["~"](green / 2 * 0.5, 1e-6)
				T(b)["~"](blue / 2 * 0.25, 1e-6)
			end
		end
	end
end)

T.Test("lut cube reads a 1d table, tabs and windows line endings", function()
	local text = "LUT_1D_SIZE\t4\r\nLUT_1D_INPUT_RANGE\t0.0 2.0\r\n0 0 0\r\n0.1 0.2 0.3\r\n0.5 0.6 0.7\r\n1 1 1\r\n"
	local result = lut.DecodeCube(text)
	T(result.size)["=="](nil)
	T(result.shaper_size)["=="](4)
	T(result.shaper_min)["=="](0)
	T(result.shaper_max)["=="](2)
	T(result.shaper[3])["~"](0.1, 1e-6)
	T(result.shaper[4])["~"](0.2, 1e-6)
	T(result.shaper[5])["~"](0.3, 1e-6)
	T(result.shaper[11])["~"](1, 1e-6)
end)

T.Test("lut cube reads a 1d shaper in front of a 3d table with its own input range", function()
	local text = "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0.0 15.0\nLUT_3D_SIZE 2\nLUT_3D_INPUT_RANGE 0.1 1.2\n0 0 0\n1 1 1\n" .. cube_rows(2, function(r, g, b)
			return 1 - r, 1 - g, 1 - b
		end)
	local result = lut.DecodeCube(text)
	T(result.shaper_size)["=="](2)
	T(result.shaper_max)["=="](15)
	T(result.size)["=="](2)
	T(result.domain_min)["=="](0.1)
	T(result.domain_max)["=="](1.2)
	local r, g, b = entry(result, 0, 0, 0)
	T(r)["=="](1)
	r, g, b = entry(result, 1, 1, 1)
	T(r)["=="](0)
end)

T.Test("lut cube refuses what it cannot read", function()
	T(pcall(lut.DecodeCube, "LUT_3D_SIZE 2\n0 0 0\n"))["=="](false)
	T(
		pcall(
			lut.DecodeCube,
			"LUT_3D_SIZE 2\n" .. cube_rows(2, function()
					return 0, 0, 0
				end) .. "\n0 0 0\n"
		)
	)["=="](false)
	T(
		pcall(
			lut.DecodeCube,
			"LUT_3D_SIZE 2\nNOT_A_KEY 1\n" .. cube_rows(2, function()
					return 0, 0, 0
				end)
		)
	)["=="](false)
	T(pcall(lut.DecodeCube, "0 0 0\n"))["=="](false)
	T(
		pcall(
			lut.DecodeCube,
			"LUT_3D_SIZE 2\nDOMAIN_MIN 0 0.1 0\n" .. cube_rows(2, function()
					return 0, 0, 0
				end)
		)
	)["=="](false)
	T(pcall(lut.DecodeCube, "LUT_3D_SIZE 2\n0 zero 0\n"))["=="](false)
end)

T.Test("lut dat reads a table with blue running fastest into red first order", function()
	local rows = {}

	for red = 0, 2 do
		for green = 0, 2 do
			for blue = 0, 2 do
				rows[#rows + 1] = string.format("%d %d %d", red, green, blue)
			end
		end
	end

	local result = lut.DecodeDat("\n3DLUTSIZE 3\n\n" .. table.concat(rows, "\n"))
	T(result.size)["=="](3)

	for blue = 0, 2 do
		for green = 0, 2 do
			for red = 0, 2 do
				local r, g, b = entry(result, red, green, blue)
				T(r)["=="](red)
				T(g)["=="](green)
				T(b)["=="](blue)
			end
		end
	end

	T(pcall(lut.DecodeDat, "0 0 0\n"))["=="](false)
end)

T.Test("lut png reads a strip with green running down the rows of the file", function()
	local size = 4
	local width = size * size
	local pixels = ffi.new("uint8_t[?]", width * size * 3)

	for blue = 0, size - 1 do
		for green = 0, size - 1 do
			for red = 0, size - 1 do
				local i = (green * width + blue * size + red) * 3
				pixels[i] = red * 10
				pixels[i + 1] = green * 20
				pixels[i + 2] = blue * 30
			end
		end
	end

	local file = png.Encode(width, size, "rgb")
	file:write(pixels)
	local result = lut.Decode("strip.png", file:getData())
	T(result.size)["=="](size)

	for blue = 0, size - 1 do
		for green = 0, size - 1 do
			for red = 0, size - 1 do
				local r, g, b = entry(result, red, green, blue)
				T(r)["~"](red * 10 / 255, 1e-6)
				T(g)["~"](green * 20 / 255, 1e-6)
				T(b)["~"](blue * 30 / 255, 1e-6)
			end
		end
	end

	local square = png.Encode(8, 8, "rgb")
	square:write(ffi.new("uint8_t[?]", 8 * 8 * 3))
	T(pcall(lut.Decode, "square.png", square:getData()))["=="](false)
end)

T.Test("lut refuses an unknown extension", function()
	T(pcall(lut.Decode, "x.3dl", ""))["=="](false)
end)
