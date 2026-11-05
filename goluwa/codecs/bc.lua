local ffi = require("ffi")
local bc = {}
local uint8_array = ffi.typeof("uint8_t[?]")
local palette = ffi.new("uint8_t[16]")
local alphas = ffi.new("uint8_t[8]")

local function unpack565(c, offset)
	local r, g, b = bit.rshift(c, 11), bit.band(bit.rshift(c, 5), 63), bit.band(c, 31)
	palette[offset] = bit.rshift(r * 527 + 23, 6)
	palette[offset + 1] = bit.rshift(g * 259 + 33, 6)
	palette[offset + 2] = bit.rshift(b * 527 + 23, 6)
end

local function decode_color_block(src, dst, x0, y0, width, height, four_color_only)
	local c0 = src[0] + src[1] * 256
	local c1 = src[2] + src[3] * 256
	unpack565(c0, 0)
	unpack565(c1, 4)
	local transparent_index = -1

	if c0 > c1 or four_color_only then
		for i = 0, 2 do
			palette[8 + i] = math.floor((2 * palette[i] + palette[4 + i]) / 3)
			palette[12 + i] = math.floor((palette[i] + 2 * palette[4 + i]) / 3)
		end
	else
		for i = 0, 2 do
			palette[8 + i] = math.floor((palette[i] + palette[4 + i]) / 2)
			palette[12 + i] = 0
		end

		transparent_index = 3
	end

	local bits = src[4] + src[5] * 256 + src[6] * 65536 + src[7] * 16777216

	for py = 0, 3 do
		for px = 0, 3 do
			local index = bit.band(bit.rshift(bits, (py * 4 + px) * 2), 3)
			local x, y = x0 + px, y0 + py

			if x < width and y < height then
				local o = (y * width + x) * 4
				dst[o] = palette[index * 4]
				dst[o + 1] = palette[index * 4 + 1]
				dst[o + 2] = palette[index * 4 + 2]

				if not four_color_only then
					dst[o + 3] = index == transparent_index and 0 or 255
				end
			end
		end
	end
end

local function decode_alpha_block(src, dst, x0, y0, width, height)
	local a0, a1 = src[0], src[1]
	alphas[0], alphas[1] = a0, a1

	if a0 > a1 then
		for i = 1, 6 do
			alphas[i + 1] = math.floor(((7 - i) * a0 + i * a1) / 7)
		end
	else
		for i = 1, 4 do
			alphas[i + 1] = math.floor(((5 - i) * a0 + i * a1) / 5)
		end

		alphas[6], alphas[7] = 0, 255
	end

	local lo = src[2] + src[3] * 256 + src[4] * 65536
	local hi = src[5] + src[6] * 256 + src[7] * 65536

	for i = 0, 15 do
		local index

		if i < 8 then
			index = bit.band(bit.rshift(lo, i * 3), 7)
		else
			index = bit.band(bit.rshift(hi, (i - 8) * 3), 7)
		end

		local x, y = x0 + i % 4, y0 + math.floor(i / 4)

		if x < width and y < height then dst[(y * width + x) * 4 + 3] = alphas[index] end
	end
end

local function decode_explicit_alpha_block(src, dst, x0, y0, width, height)
	for i = 0, 15 do
		local nibble = bit.band(bit.rshift(src[math.floor(i / 2)], (i % 2) * 4), 15)
		local x, y = x0 + i % 4, y0 + math.floor(i / 4)

		if x < width and y < height then dst[(y * width + x) * 4 + 3] = nibble * 17 end
	end
end

local bc7_weights = {[0] = 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64}

local function get_bits(src, position, count)
	local value = 0

	for i = 0, count - 1 do
		local bit_position = position + i
		local byte = src[math.floor(bit_position / 8)]
		value = value + bit.band(bit.rshift(byte, bit_position % 8), 1) * 2 ^ i
	end

	return value
end

-- decodes the red channel of an 8 byte block (the same block as bc3's alpha) for every texel
local function decode_single_channel(src, dst, x0, y0, width, height, channel)
	local a0, a1 = src[0], src[1]
	alphas[0], alphas[1] = a0, a1

	if a0 > a1 then
		for i = 1, 6 do
			alphas[i + 1] = math.floor(((7 - i) * a0 + i * a1) / 7)
		end
	else
		for i = 1, 4 do
			alphas[i + 1] = math.floor(((5 - i) * a0 + i * a1) / 5)
		end

		alphas[6], alphas[7] = 0, 255
	end

	local lo = src[2] + src[3] * 256 + src[4] * 65536
	local hi = src[5] + src[6] * 256 + src[7] * 65536

	for i = 0, 15 do
		local index = i < 8 and
			bit.band(bit.rshift(lo, i * 3), 7) or
			bit.band(bit.rshift(hi, (i - 8) * 3), 7)
		local x, y = x0 + i % 4, y0 + math.floor(i / 4)

		if x < width and y < height then
			dst[(y * width + x) * 4 + channel] = alphas[index]
		end
	end
end

-- only mode 6 (one subset, 7 bit rgba endpoints with a p bit each, 4 bit indices) is decoded
local function decode_bc7_block(src, dst, x0, y0, width, height)
	assert(bit.band(src[0], 0x7F) == 0x40, "only bc7 mode 6 is decoded")
	local endpoints = {}
	local position = 7

	for channel = 0, 3 do
		endpoints[channel] = {get_bits(src, position, 7), get_bits(src, position + 7, 7)}
		position = position + 14
	end

	local p0, p1 = get_bits(src, position, 1), get_bits(src, position + 1, 1)
	position = position + 2

	for channel = 0, 3 do
		endpoints[channel][1] = endpoints[channel][1] * 2 + p0
		endpoints[channel][2] = endpoints[channel][2] * 2 + p1
	end

	for i = 0, 15 do
		local index = get_bits(src, position, i == 0 and 3 or 4)
		position = position + (i == 0 and 3 or 4)
		local weight = bc7_weights[index]
		local x, y = x0 + i % 4, y0 + math.floor(i / 4)

		if x < width and y < height then
			local o = (y * width + x) * 4

			for channel = 0, 3 do
				dst[o + channel] = math.floor(((64 - weight) * endpoints[channel][1] + weight * endpoints[channel][2] + 32) / 64)
			end
		end
	end
end

bc.BlockSize = {bc1 = 8, bc2 = 16, bc3 = 16, bc4 = 8, bc5 = 16, bc7 = 16}

-- format is "bc1" to "bc5" or "bc7" (mode 6 only); src points at the blocks of one mip; returns tightly packed
-- r8g8b8a8 (bc4 fills red, bc5 red and green, the other channels are left zero)
function bc.Decode(format, src, width, height)
	local block_size = assert(bc.BlockSize[format], format)
	local dst = uint8_array(width * height * 4)
	local blocks_x = math.max(1, math.floor((width + 3) / 4))
	local blocks_y = math.max(1, math.floor((height + 3) / 4))
	src = ffi.cast("uint8_t *", src)

	for by = 0, blocks_y - 1 do
		for bx = 0, blocks_x - 1 do
			local block = src + (by * blocks_x + bx) * block_size

			if format == "bc4" then
				decode_single_channel(block, dst, bx * 4, by * 4, width, height, 0)
			elseif format == "bc5" then
				decode_single_channel(block, dst, bx * 4, by * 4, width, height, 0)
				decode_single_channel(block + 8, dst, bx * 4, by * 4, width, height, 1)
			elseif format == "bc7" then
				decode_bc7_block(block, dst, bx * 4, by * 4, width, height)
			elseif format == "bc1" then
				decode_color_block(block, dst, bx * 4, by * 4, width, height, false)
			else
				decode_color_block(block + 8, dst, bx * 4, by * 4, width, height, true)

				if format == "bc2" then
					decode_explicit_alpha_block(block, dst, bx * 4, by * 4, width, height)
				else
					decode_alpha_block(block, dst, bx * 4, by * 4, width, height)
				end
			end
		end
	end

	return dst
end

return bc
