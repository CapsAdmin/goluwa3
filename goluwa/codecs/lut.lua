local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local png = import("goluwa/codecs/png.lua")
local lut = {}
local float_array = ffi.typeof("float[?]")

local function parse_numbers(text, count, what)
	local out = {}

	for token in text:gmatch("%S+") do
		out[#out + 1] = tonumber(token) or error(what .. ": not a number: " .. token, 3)
	end

	assert(#out == count, what .. ": expected " .. count .. " numbers, got " .. #out)
	return out
end

local function to_scalar(numbers, what)
	assert(
		numbers[1] == numbers[2] and numbers[2] == numbers[3],
		what .. ": a different range per channel is not supported"
	)
	return numbers[1]
end

-- red varies fastest in `data`, one row of 3 floats per entry
local function new_result(size_1d, size_3d)
	return {
		shaper_size = size_1d,
		shaper = size_1d and float_array(size_1d * 3),
		size = size_3d,
		data = size_3d and float_array(size_3d * size_3d * size_3d * 3),
		shaper_min = 0,
		shaper_max = 1,
		domain_min = 0,
		domain_max = 1,
	}
end

function lut.DecodeCube(str)
	local size_1d, size_3d
	local domain_min, domain_max = 0, 1
	local shaper_min, shaper_max, input_min, input_max
	local result
	local count_1d, count_3d = 0, 0
	local row = 0

	for line in str:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")

		if line == "" or line:sub(1, 1) == "#" then goto continue end

		do
			local key, rest = line:match("^(%S+)%s*(.*)$")

			if key:find("^[%-%+%.%d]") then
				if not result then
					assert(size_1d or size_3d, "cube: data before LUT_1D_SIZE or LUT_3D_SIZE")
					result = new_result(size_1d, size_3d)
					count_1d = size_1d or 0
					count_3d = size_3d and size_3d * size_3d * size_3d or 0
				end

				local r, g, b = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
				r, g, b = tonumber(r), tonumber(g), tonumber(b)

				if not (r and g and b) then error("cube: bad data row: " .. line, 2) end

				if row < count_1d then
					local i = row * 3
					result.shaper[i], result.shaper[i + 1], result.shaper[i + 2] = r, g, b
				elseif row < count_1d + count_3d then
					local i = (row - count_1d) * 3
					result.data[i], result.data[i + 1], result.data[i + 2] = r, g, b
				else
					error("cube: more data rows than the declared sizes", 2)
				end

				row = row + 1
			elseif key == "TITLE" then
				goto continue
			elseif key == "LUT_1D_SIZE" then
				size_1d = tonumber(rest) or error("cube: bad LUT_1D_SIZE", 2)
			elseif key == "LUT_3D_SIZE" then
				size_3d = tonumber(rest) or error("cube: bad LUT_3D_SIZE", 2)
			elseif key == "LUT_1D_INPUT_RANGE" then
				local range = parse_numbers(rest, 2, "cube LUT_1D_INPUT_RANGE")
				shaper_min, shaper_max = range[1], range[2]
			elseif key == "LUT_3D_INPUT_RANGE" then
				local range = parse_numbers(rest, 2, "cube LUT_3D_INPUT_RANGE")
				input_min, input_max = range[1], range[2]
			elseif key == "DOMAIN_MIN" then
				domain_min = to_scalar(parse_numbers(rest, 3, "cube DOMAIN_MIN"), "cube DOMAIN_MIN")
			elseif key == "DOMAIN_MAX" then
				domain_max = to_scalar(parse_numbers(rest, 3, "cube DOMAIN_MAX"), "cube DOMAIN_MAX")
			else
				error("cube: unknown line: " .. line, 2)
			end
		end

		::continue::
	end

	assert(result, "cube: no data")
	assert(
		row == count_1d + count_3d,
		"cube: expected " .. (count_1d + count_3d) .. " data rows, got " .. row
	)

	if size_1d then
		assert(size_1d >= 2, "cube: LUT_1D_SIZE must be at least 2")
		result.shaper_min = shaper_min or domain_min
		result.shaper_max = shaper_max or domain_max
	end

	if size_3d then
		assert(size_3d >= 2, "cube: LUT_3D_SIZE must be at least 2")
		result.domain_min = input_min or domain_min
		result.domain_max = input_max or domain_max
	end

	return result
end

-- the 3DLUTSIZE files (Lustre, Arri) run blue fastest, red slowest
function lut.DecodeDat(str)
	local size
	local result
	local row = 0
	local count

	for line in str:gmatch("[^\r\n]+") do
		line = line:match("^%s*(.-)%s*$")

		if line == "" then goto continue end

		do
			local header = line:match("^3DLUTSIZE%s+(%d+)$")

			if header then
				size = tonumber(header)
				assert(size >= 2, "dat: 3DLUTSIZE must be at least 2")
				result = new_result(nil, size)
				count = size * size * size

				goto continue
			end

			assert(result, "dat: only files with a 3DLUTSIZE header are supported")
			local r, g, b = line:match("^(%S+)%s+(%S+)%s+(%S+)$")
			r, g, b = tonumber(r), tonumber(g), tonumber(b)

			if not (r and g and b) then error("dat: bad data row: " .. line, 2) end

			assert(row < count, "dat: more data rows than the declared size")
			local blue = row % size
			local green = math.floor(row / size) % size
			local red = math.floor(row / (size * size))
			local i = (red + green * size + blue * size * size) * 3
			result.data[i], result.data[i + 1], result.data[i + 2] = r, g, b
			row = row + 1
		end

		::continue::
	end

	assert(result, "dat: no data")
	assert(row == count, "dat: expected " .. count .. " data rows, got " .. row)
	return result
end

-- a strip of N slices side by side, each N by N: blue picks the slice, red runs along x and green down the rows of the file; png.DecodeBuffer returns the rows bottom up
function lut.DecodePng(str)
	local bytes = ffi.new("uint8_t[?]", #str)
	ffi.copy(bytes, str, #str)
	local image = png.DecodeBuffer(Buffer.New(bytes, #str))
	local size = image.height
	assert(
		image.width == size * size and size >= 2,
		"png lut: expected a strip of N slices (width N*N, height N), got " .. image.width .. "x" .. image.height
	)
	local result = new_result(nil, size)
	local is16 = image.depth == 16
	local pixels = ffi.cast(is16 and "uint16_t *" or "uint8_t *", image.data)
	local scale = is16 and 1 / 65535 or 1 / 255

	for blue = 0, size - 1 do
		for green = 0, size - 1 do
			for red = 0, size - 1 do
				local from = ((size - 1 - green) * image.width + blue * size + red) * 4
				local to = (red + green * size + blue * size * size) * 3
				result.data[to] = pixels[from] * scale
				result.data[to + 1] = pixels[from + 1] * scale
				result.data[to + 2] = pixels[from + 2] * scale
			end
		end
	end

	return result
end

function lut.Decode(path, str)
	local extension = path:lower():match("%.([^%./\\]+)$")

	if extension == "cube" then return lut.DecodeCube(str) end

	if extension == "dat" then return lut.DecodeDat(str) end

	if extension == "png" then return lut.DecodePng(str) end

	error("unsupported lut format: " .. path, 2)
end

return lut
