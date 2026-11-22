local ffi = require("ffi")
local bit = require("bit")
local Buffer = import("goluwa/structs/buffer.lua")
local band, bor, bxor, lshift, rshift, arshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.arshift
local webp = {}
webp.file_extensions = {"webp"}
local Int32Array = ffi.typeof("int32_t[?]")
local UInt16Array = ffi.typeof("uint16_t[?]")
local UInt8Array = ffi.typeof("uint8_t[?]")
local MAX_CODE_LENGTH = 15
local ROOT_BITS = 8
local LENGTHS_ROOT_BITS = 7
local NUM_LENGTH_CODES = 24
local NUM_DISTANCE_CODES = 40
local CODE_LENGTH_ORDER = {17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
local CODE_TO_PLANE = {
	0x18,
	0x07,
	0x17,
	0x19,
	0x28,
	0x06,
	0x27,
	0x29,
	0x16,
	0x1a,
	0x26,
	0x2a,
	0x38,
	0x05,
	0x37,
	0x39,
	0x15,
	0x1b,
	0x36,
	0x3a,
	0x25,
	0x2b,
	0x48,
	0x04,
	0x47,
	0x49,
	0x14,
	0x1c,
	0x35,
	0x3b,
	0x46,
	0x4a,
	0x24,
	0x2c,
	0x58,
	0x45,
	0x4b,
	0x34,
	0x3c,
	0x03,
	0x57,
	0x59,
	0x13,
	0x1d,
	0x56,
	0x5a,
	0x23,
	0x2d,
	0x44,
	0x4c,
	0x55,
	0x5b,
	0x33,
	0x3d,
	0x68,
	0x02,
	0x67,
	0x69,
	0x12,
	0x1e,
	0x66,
	0x6a,
	0x22,
	0x2e,
	0x54,
	0x5c,
	0x43,
	0x4d,
	0x65,
	0x6b,
	0x32,
	0x3e,
	0x78,
	0x01,
	0x77,
	0x79,
	0x53,
	0x5d,
	0x11,
	0x1f,
	0x64,
	0x6c,
	0x42,
	0x4e,
	0x76,
	0x7a,
	0x21,
	0x2f,
	0x75,
	0x7b,
	0x31,
	0x3f,
	0x63,
	0x6d,
	0x52,
	0x5e,
	0x00,
	0x74,
	0x7c,
	0x41,
	0x4f,
	0x10,
	0x20,
	0x62,
	0x6e,
	0x30,
	0x73,
	0x7d,
	0x51,
	0x5f,
	0x40,
	0x72,
	0x7e,
	0x61,
	0x6f,
	0x50,
	0x71,
	0x7f,
	0x60,
	0x70,
}

local function new_reader(data, length)
	return {data = data, length = length, pos = 0, value = 0, count = 0}
end

local function fill(br)
	local data, length = br.data, br.length

	while br.count <= 23 do
		local byte = br.pos < length and data[br.pos] or 0
		br.value = bor(br.value, lshift(byte, br.count))
		br.pos = br.pos + 1
		br.count = br.count + 8
	end
end

local function read_bits(br, n)
	if n == 0 then return 0 end

	if br.count < n then fill(br) end

	local v = band(br.value, lshift(1, n) - 1)
	br.value = rshift(br.value, n)
	br.count = br.count - n
	return v
end

-- a huffman table is two arrays (bits, value) of a root table of root_bits and the second level tables after it
local function next_key(key, len)
	local step = lshift(1, len - 1)

	while band(key, step) ~= 0 do
		step = rshift(step, 1)
	end

	return step ~= 0 and band(key, step - 1) + step or key
end

local function build_table(code_lengths, size, root_bits)
	local count = {}
	local offset = {}

	for len = 0, MAX_CODE_LENGTH do
		count[len] = 0
	end

	for symbol = 0, size - 1 do
		local len = code_lengths[symbol]
		count[len] = count[len] + 1
	end

	if count[0] == size then error("webp: empty huffman code") end

	offset[1] = 0

	for len = 1, MAX_CODE_LENGTH - 1 do
		offset[len + 1] = offset[len] + count[len]
	end

	local sorted = {}

	for symbol = 0, size - 1 do
		local len = code_lengths[symbol]

		if len > 0 then
			sorted[offset[len]] = symbol
			offset[len] = offset[len] + 1
		end
	end

	local root_size = lshift(1, root_bits)

	if offset[MAX_CODE_LENGTH] == 1 then
		local bits, values = UInt8Array(root_size), UInt16Array(root_size)

		for i = 0, root_size - 1 do
			values[i] = sorted[0]
		end

		return {bits = bits, values = values, root_bits = root_bits}
	end

	-- the total size of the second level tables is not known up front, grow plain lua tables and copy
	local bits, values = {}, {}
	local table_bits = root_bits
	local table_size = root_size
	local total_size = root_size
	local num_nodes = 1
	local num_open = 1
	local key = 0
	local symbol = 0
	local step = 2

	for i = 0, root_size - 1 do
		bits[i], values[i] = 0, 0
	end

	for len = 1, root_bits do
		num_open = num_open * 2
		num_nodes = num_nodes + num_open
		num_open = num_open - count[len]

		if num_open < 0 then error("webp: bad huffman code") end

		for _ = 1, count[len] do
			local value = sorted[symbol]
			symbol = symbol + 1

			for i = key, table_size - 1, step do
				bits[i], values[i] = len, value
			end

			key = next_key(key, len)
		end

		step = step * 2
	end

	local mask = total_size - 1
	local low = -1
	local table_start = 0
	step = 2

	for len = root_bits + 1, MAX_CODE_LENGTH do
		num_open = num_open * 2
		num_nodes = num_nodes + num_open
		num_open = num_open - count[len]

		if num_open < 0 then error("webp: bad huffman code") end

		for c = count[len], 1, -1 do
			if band(key, mask) ~= low then
				table_start = table_start + table_size
				-- the second level table holds every code left that shares these root bits
				local l = len
				local left = lshift(1, len - root_bits) - c

				while left > 0 and l < MAX_CODE_LENGTH do
					l = l + 1
					left = left * 2 - count[l]
				end

				table_bits = l - root_bits
				table_size = lshift(1, table_bits)

				for i = table_start, table_start + table_size - 1 do
					bits[i], values[i] = 0, 0
				end

				total_size = total_size + table_size
				low = band(key, mask)
				bits[low] = table_bits + root_bits
				values[low] = table_start - low
			end

			local value = sorted[symbol]
			symbol = symbol + 1

			for i = table_start + rshift(key, root_bits), table_start + table_size - 1, step do
				bits[i], values[i] = len - root_bits, value
			end

			key = next_key(key, len)
		end

		step = step * 2
	end

	if num_nodes ~= 2 * offset[MAX_CODE_LENGTH] - 1 then
		error("webp: incomplete huffman code")
	end

	local out_bits, out_values = UInt8Array(total_size), UInt16Array(total_size)

	for i = 0, total_size - 1 do
		out_bits[i], out_values[i] = bits[i], values[i]
	end

	return {bits = out_bits, values = out_values, root_bits = root_bits}
end

local function read_symbol(br, huffman)
	if br.count < 15 then fill(br) end

	local value = br.value
	local root_bits = huffman.root_bits
	local index = band(value, lshift(1, root_bits) - 1)
	local bits = huffman.bits[index]

	if bits > root_bits then
		local extra = bits - root_bits
		index = index + huffman.values[index] + band(rshift(value, root_bits), lshift(1, extra) - 1)
		bits = root_bits + huffman.bits[index]
	end

	br.value = rshift(value, bits)
	br.count = br.count - bits
	return huffman.values[index]
end

local function read_code_lengths(br, code_length_code_lengths, num_symbols, code_lengths)
	local lengths_table = build_table(code_length_code_lengths, 19, LENGTHS_ROOT_BITS)
	local max_symbol = num_symbols

	if read_bits(br, 1) == 1 then
		local length_bits = 2 + 2 * read_bits(br, 3)
		max_symbol = 2 + read_bits(br, length_bits)

		if max_symbol > num_symbols then error("webp: bad code lengths") end
	end

	local symbol = 0
	local previous = 8

	while symbol < num_symbols do
		if max_symbol == 0 then break end

		max_symbol = max_symbol - 1
		local code = read_symbol(br, lengths_table)

		if code < 16 then
			code_lengths[symbol] = code
			symbol = symbol + 1

			if code ~= 0 then previous = code end
		else
			local slot = code - 16
			local extra = slot == 0 and 2 or (slot == 1 and 3 or 7)
			local repeat_count = read_bits(br, extra) + (slot == 2 and 11 or 3)

			if symbol + repeat_count > num_symbols then error("webp: bad code lengths") end

			local length = slot == 0 and previous or 0

			for _ = 1, repeat_count do
				code_lengths[symbol] = length
				symbol = symbol + 1
			end
		end
	end
end

local function read_huffman_code(br, alphabet_size)
	local code_lengths = UInt8Array(alphabet_size)

	if read_bits(br, 1) == 1 then
		local num_symbols = read_bits(br, 1) + 1
		local first_bits = read_bits(br, 1) == 0 and 1 or 8
		code_lengths[read_bits(br, first_bits)] = 1

		if num_symbols == 2 then code_lengths[read_bits(br, 8)] = 1 end
	else
		local code_length_code_lengths = UInt8Array(19)
		local num_codes = read_bits(br, 4) + 4

		for i = 1, num_codes do
			code_length_code_lengths[CODE_LENGTH_ORDER[i]] = read_bits(br, 3)
		end

		read_code_lengths(br, code_length_code_lengths, alphabet_size, code_lengths)
	end

	return build_table(code_lengths, alphabet_size, ROOT_BITS)
end

local function div_round_up(n, bits)
	return rshift(n + lshift(1, bits) - 1, bits)
end

local function get_copy_distance(br, symbol)
	if symbol < 4 then return symbol + 1 end

	local extra = rshift(symbol - 2, 1)
	return lshift(2 + band(symbol, 1), extra) + read_bits(br, extra) + 1
end

local decode_image_stream

-- the top bits of argb * 0x1e35a7bd mod 2^32, multiplied in halves so the doubles stay exact
local function color_hash(argb, shift)
	local high = bit.tobit(rshift(argb, 16) * 0x1e35a7bd)
	return rshift(bit.tobit(band(argb, 0xffff) * 0x1e35a7bd + high * 65536), shift)
end

local function decode_pixels(br, width, height, cache_bits, groups, meta)
	local total = width * height
	local data = Int32Array(total)
	local cache_size = cache_bits > 0 and lshift(1, cache_bits) or 0
	local cache = cache_size > 0 and Int32Array(cache_size) or nil
	local cache_shift = 32 - cache_bits
	local last_cached = 0
	local group = groups[1]
	local meta_bits = meta and meta.bits or 0
	local meta_mask = meta and lshift(1, meta_bits) - 1 or -1
	local meta_width = meta and meta.width or 0
	local meta_index = meta and meta.index or nil
	local pos = 0
	local x, y = 0, 0

	while pos < total do
		if meta_index and band(x, meta_mask) == 0 then
			group = groups[meta_index[rshift(y, meta_bits) * meta_width + rshift(x, meta_bits)] + 1]
		end

		local code = read_symbol(br, group[1])

		if code < 256 then
			local red = read_symbol(br, group[2])
			local blue = read_symbol(br, group[3])
			local alpha = read_symbol(br, group[4])
			data[pos] = bor(lshift(alpha, 24), lshift(red, 16), lshift(code, 8), blue)
			pos = pos + 1
			x = x + 1

			if x >= width then
				x = 0
				y = y + 1
			end
		elseif code < 256 + NUM_LENGTH_CODES then
			local length = get_copy_distance(br, code - 256)
			local distance_code = get_copy_distance(br, read_symbol(br, group[5]))
			local distance

			if distance_code > 120 then
				distance = distance_code - 120
			else
				local plane = CODE_TO_PLANE[distance_code]
				distance = rshift(plane, 4) * width + 8 - band(plane, 0xf)

				if distance < 1 then distance = 1 end
			end

			if distance > pos or pos + length > total then
				error("webp: bad backward reference")
			end

			for i = pos, pos + length - 1 do
				data[i] = data[i - distance]
			end

			pos = pos + length
			x = x + length

			while x >= width do
				x = x - width
				y = y + 1
			end

			if meta_index and pos < total then
				group = groups[meta_index[rshift(y, meta_bits) * meta_width + rshift(x, meta_bits)] + 1]
			end
		else
			local key = code - 256 - NUM_LENGTH_CODES

			if not cache or key >= cache_size then error("webp: bad color cache index") end

			while last_cached < pos do
				local argb = data[last_cached]
				cache[color_hash(argb, cache_shift)] = argb
				last_cached = last_cached + 1
			end

			data[pos] = cache[key]
			pos = pos + 1
			x = x + 1

			if x >= width then
				x = 0
				y = y + 1
			end
		end

		if cache then
			while last_cached < pos do
				local argb = data[last_cached]
				cache[color_hash(argb, cache_shift)] = argb
				last_cached = last_cached + 1
			end
		end
	end

	return data
end

local function read_groups(br, width, height, cache_bits, allow_meta)
	local meta

	if allow_meta and read_bits(br, 1) == 1 then
		local bits = read_bits(br, 3) + 2
		local meta_width, meta_height = div_round_up(width, bits), div_round_up(height, bits)
		local image = decode_image_stream(br, meta_width, meta_height, false)
		local index = Int32Array(meta_width * meta_height)
		local count = 0

		for i = 0, meta_width * meta_height - 1 do
			index[i] = band(rshift(image[i], 8), 0xffff)

			if index[i] + 1 > count then count = index[i] + 1 end
		end

		meta = {bits = bits, width = meta_width, index = index, count = count}
	end

	local cache_size = cache_bits > 0 and lshift(1, cache_bits) or 0
	local groups = {}

	for i = 1, meta and meta.count or 1 do
		groups[i] = {
			read_huffman_code(br, 256 + NUM_LENGTH_CODES + cache_size),
			read_huffman_code(br, 256),
			read_huffman_code(br, 256),
			read_huffman_code(br, 256),
			read_huffman_code(br, NUM_DISTANCE_CODES),
		}
	end

	return groups, meta
end

local function read_cache_bits(br)
	if read_bits(br, 1) == 0 then return 0 end

	local bits = read_bits(br, 4)

	if bits < 1 or bits > 11 then error("webp: bad color cache size") end

	return bits
end

local function add_pixels(a, b)
	local alpha_green = band(band(a, 0xff00ff00) + band(b, 0xff00ff00), 0xff00ff00)
	local red_blue = band(band(a, 0x00ff00ff) + band(b, 0x00ff00ff), 0x00ff00ff)
	return bor(alpha_green, red_blue)
end

local function average2(a, b)
	return band(rshift(band(bxor(a, b), 0xfefefefe), 1), 0x7f7f7f7f) + band(a, b)
end

local function clamp255(v)
	return v < 0 and 0 or (v > 255 and 255 or v)
end

local function clamp_add_subtract_full(a, b, c)
	local out = 0

	for shift = 0, 24, 8 do
		local v = band(rshift(a, shift), 0xff) + band(rshift(b, shift), 0xff) - band(rshift(c, shift), 0xff)
		out = bor(out, lshift(clamp255(v), shift))
	end

	return out
end

local function clamp_add_subtract_half(a, b)
	local out = 0

	for shift = 0, 24, 8 do
		local ca, cb = band(rshift(a, shift), 0xff), band(rshift(b, shift), 0xff)
		local d = ca - cb
		d = d >= 0 and math.floor(d / 2) or -math.floor(-d / 2)
		out = bor(out, lshift(clamp255(ca + d), shift))
	end

	return out
end

local function select_pixel(top, left, top_left)
	local sum = 0

	for shift = 0, 24, 8 do
		local t, l, tl = band(rshift(top, shift), 0xff),
		band(rshift(left, shift), 0xff),
		band(rshift(top_left, shift), 0xff)
		sum = sum + math.abs(l - tl) - math.abs(t - tl)
	end

	return sum <= 0 and top or left
end

local function predict(mode, data, pos, width)
	local left = data[pos - 1]
	local top = data[pos - width]

	if mode == 0 then
		return -16777216
	elseif mode == 1 then
		return left
	elseif mode == 2 then
		return top
	elseif mode == 3 then
		return data[pos - width + 1]
	elseif mode == 4 then
		return data[pos - width - 1]
	elseif mode == 5 then
		return average2(average2(left, data[pos - width + 1]), top)
	elseif mode == 6 then
		return average2(left, data[pos - width - 1])
	elseif mode == 7 then
		return average2(left, top)
	elseif mode == 8 then
		return average2(data[pos - width - 1], top)
	elseif mode == 9 then
		return average2(top, data[pos - width + 1])
	elseif mode == 10 then
		return average2(average2(left, data[pos - width - 1]), average2(top, data[pos - width + 1]))
	elseif mode == 11 then
		return select_pixel(top, left, data[pos - width - 1])
	elseif mode == 12 then
		return clamp_add_subtract_full(left, top, data[pos - width - 1])
	elseif mode == 13 then
		return clamp_add_subtract_half(average2(left, top), data[pos - width - 1])
	end

	return -16777216
end

local function inverse_predictor(transform, data, width, height)
	local bits = transform.bits
	local block_width = div_round_up(width, bits)
	local modes = transform.data
	data[0] = add_pixels(data[0], -16777216)

	for x = 1, width - 1 do
		data[x] = add_pixels(data[x], data[x - 1])
	end

	for y = 1, height - 1 do
		local row = y * width
		data[row] = add_pixels(data[row], data[row - width])
		local mode_row = rshift(y, bits) * block_width

		for x = 1, width - 1 do
			local mode = band(rshift(modes[mode_row + rshift(x, bits)], 8), 0xf)
			local pos = row + x
			data[pos] = add_pixels(data[pos], predict(mode, data, pos, width))
		end
	end
end

local function color_delta(t, c)
	return arshift(t * c, 5)
end

local function to_int8(v)
	return v >= 128 and v - 256 or v
end

local function inverse_cross_color(transform, data, width, height)
	local bits = transform.bits
	local block_width = div_round_up(width, bits)
	local codes = transform.data

	for y = 0, height - 1 do
		local code_row = rshift(y, bits) * block_width

		for x = 0, width - 1 do
			local code = codes[code_row + rshift(x, bits)]
			local green_to_red = to_int8(band(code, 0xff))
			local green_to_blue = to_int8(band(rshift(code, 8), 0xff))
			local red_to_blue = to_int8(band(rshift(code, 16), 0xff))
			local pos = y * width + x
			local argb = data[pos]
			local green = to_int8(band(rshift(argb, 8), 0xff))
			local red = band(band(rshift(argb, 16), 0xff) + color_delta(green_to_red, green), 0xff)
			local blue = band(argb, 0xff) + color_delta(green_to_blue, green)
			blue = band(blue + color_delta(red_to_blue, to_int8(red)), 0xff)
			data[pos] = bor(band(argb, 0xff00ff00), lshift(red, 16), blue)
		end
	end
end

local function inverse_subtract_green(data, count)
	for i = 0, count - 1 do
		local argb = data[i]
		local green = band(rshift(argb, 8), 0xff)
		local red_blue = band(band(argb, 0x00ff00ff) + bor(lshift(green, 16), green), 0x00ff00ff)
		data[i] = bor(band(argb, 0xff00ff00), red_blue)
	end
end

local function inverse_color_indexing(transform, data, width, height)
	local bits = transform.bits
	local palette = transform.data
	local palette_size = transform.size
	local out = Int32Array(width * height)
	local packed_width = div_round_up(width, bits)
	local pixel_bits = rshift(8, bits)
	local index_mask = lshift(1, pixel_bits) - 1
	local per_pixel_mask = lshift(1, bits) - 1

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local packed = band(rshift(data[y * packed_width + rshift(x, bits)], 8), 0xff)
			local index = band(rshift(packed, band(x, per_pixel_mask) * pixel_bits), index_mask)
			out[y * width + x] = index < palette_size and palette[index] or 0
		end
	end

	return out
end

function decode_image_stream(br, width, height, is_main)
	local transforms = {}
	local coded_width = width

	if is_main then
		while read_bits(br, 1) == 1 do
			local kind = read_bits(br, 2)
			local transform = {kind = kind, width = coded_width}

			if kind == 0 or kind == 1 then
				transform.bits = read_bits(br, 3) + 2
				transform.data = decode_image_stream(
					br,
					div_round_up(coded_width, transform.bits),
					div_round_up(height, transform.bits),
					false
				)
			elseif kind == 3 then
				local size = read_bits(br, 8) + 1
				transform.bits = size > 16 and 0 or (size > 4 and 1 or (size > 2 and 2 or 3))
				transform.size = size
				local palette = decode_image_stream(br, size, 1, false)

				for i = 1, size - 1 do
					palette[i] = add_pixels(palette[i], palette[i - 1])
				end

				transform.data = palette
				coded_width = div_round_up(coded_width, transform.bits)
			end

			transforms[#transforms + 1] = transform
		end
	end

	local cache_bits = read_cache_bits(br)
	local groups, meta = read_groups(br, coded_width, height, cache_bits, is_main)
	local data = decode_pixels(br, coded_width, height, cache_bits, groups, meta)

	for i = #transforms, 1, -1 do
		local transform = transforms[i]

		if transform.kind == 0 then
			inverse_predictor(transform, data, transform.width, height)
		elseif transform.kind == 1 then
			inverse_cross_color(transform, data, transform.width, height)
		elseif transform.kind == 2 then
			inverse_subtract_green(data, transform.width * height)
		else
			data = inverse_color_indexing(transform, data, transform.width, height)
		end
	end

	return data
end

-- decodes a lossless webp from bytes, returns width, height and the pixels as argb int32s, rows top down
function webp.DecodeARGB(data, length)
	data = ffi.cast("const uint8_t *", data)

	if length < 21 or ffi.string(data, 4) ~= "RIFF" or ffi.string(data + 8, 4) ~= "WEBP" then
		error("webp: not a webp file")
	end

	local offset = 12
	local chunk_length

	while true do
		if offset + 8 > length then error("webp: no VP8L chunk") end

		local fourcc = ffi.string(data + offset, 4)
		chunk_length = data[offset + 4] + data[offset + 5] * 256 + data[offset + 6] * 65536 + data[offset + 7] * 16777216

		if fourcc == "VP8L" then break end

		if fourcc == "VP8 " then error("webp: lossy webp is not supported") end

		offset = offset + 8 + chunk_length + chunk_length % 2
	end

	local br = new_reader(data + offset + 8, math.min(chunk_length, length - offset - 8))

	if read_bits(br, 8) ~= 0x2f then error("webp: bad VP8L signature") end

	local width = read_bits(br, 14) + 1
	local height = read_bits(br, 14) + 1
	read_bits(br, 1)

	if read_bits(br, 3) ~= 0 then error("webp: unknown VP8L version") end

	return width, height, decode_image_stream(br, width, height, true)
end

function webp.CanDecodeData(str)
	return #str >= 12 and str:sub(1, 4) == "RIFF" and str:sub(9, 12) == "WEBP"
end

function webp.DecodeBuffer(input_buffer)
	local size = input_buffer:GetSize()
	local width, height, argb = webp.DecodeARGB(input_buffer:GetBuffer(), size)
	local count = width * height
	local pixels = UInt8Array(count * 4)

	for i = 0, count - 1 do
		local p = argb[i]
		local o = i * 4
		pixels[o] = band(rshift(p, 16), 0xff)
		pixels[o + 1] = band(rshift(p, 8), 0xff)
		pixels[o + 2] = band(p, 0xff)
		pixels[o + 3] = band(rshift(p, 24), 0xff)
	end

	return {
		width = width,
		height = height,
		vulkan_format = "r8g8b8a8_unorm",
		buffer = Buffer.New(pixels, count * 4),
	}
end

return webp
