local ffi = require("ffi")
local bit = require("bit")
local fft = {}
local cos, sin, pi = math.cos, math.sin, math.pi

local function transform_lines(re, im, count, length, stride_line, stride_item, inverse)
	local bits = 0

	while 2 ^ bits < length do
		bits = bits + 1
	end

	assert(2 ^ bits == length, "fft length must be a power of two")
	local cos_table = ffi.new("double[?]", length / 2)
	local sin_table = ffi.new("double[?]", length / 2)
	local sign = inverse and 1 or -1

	for i = 0, length / 2 - 1 do
		cos_table[i] = cos(2 * pi * i / length)
		sin_table[i] = sign * sin(2 * pi * i / length)
	end

	local reversed = ffi.new("int32_t[?]", length)

	for i = 0, length - 1 do
		local r = 0

		for b = 0, bits - 1 do
			if bit.band(bit.rshift(i, b), 1) == 1 then
				r = bit.bor(r, bit.lshift(1, bits - 1 - b))
			end
		end

		reversed[i] = r
	end

	for line = 0, count - 1 do
		local base = line * stride_line

		for i = 0, length - 1 do
			local j = reversed[i]

			if j > i then
				local a, b = base + i * stride_item, base + j * stride_item
				re[a], re[b] = re[b], re[a]
				im[a], im[b] = im[b], im[a]
			end
		end

		local size = 2

		while size <= length do
			local half = size / 2
			local step = length / size

			for start = 0, length - 1, size do
				for k = 0, half - 1 do
					local wr, wi = cos_table[k * step], sin_table[k * step]
					local a = base + (start + k) * stride_item
					local b = base + (start + k + half) * stride_item
					local tr = re[b] * wr - im[b] * wi
					local ti = re[b] * wi + im[b] * wr
					re[b] = re[a] - tr
					im[b] = im[a] - ti
					re[a] = re[a] + tr
					im[a] = im[a] + ti
				end
			end

			size = size * 2
		end
	end
end

function fft.Transform2D(re, im, size, inverse)
	transform_lines(re, im, size, size, size, 1, inverse)
	transform_lines(re, im, size, size, 1, size, inverse)
end

return fft
