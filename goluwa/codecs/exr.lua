local ffi = require("ffi")
local bit = require("bit")
local Buffer = import("goluwa/structs/buffer.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local exr = library()
exr.file_extensions = {"exr"}
exr.magic_headers = {"v/1\1"}
local band, bor, rshift, lshift, arshift = bit.band, bit.bor, bit.rshift, bit.lshift, bit.arshift
local COMPRESSION_NONE = 0
local COMPRESSION_RLE = 1
local COMPRESSION_ZIPS = 2
local COMPRESSION_ZIP = 3
local COMPRESSION_PIZ = 4
local PIXEL_UINT = 0
local PIXEL_HALF = 1
local PIXEL_FLOAT = 2
local half_to_float_table = ffi.new("float[65536]")

for i = 0, 65535 do
	half_to_float_table[i] = math.half2float(i)
end

local function read_null_terminated_string(buffer)
	local str = {}

	while true do
		local b = buffer:ReadByte()

		if b == 0 then break end

		table.insert(str, string.char(b))
	end

	return table.concat(str)
end

local function read_u32(p, offset)
	return p[offset] + p[offset + 1] * 256 + p[offset + 2] * 65536 + p[offset + 3] * 16777216
end

local function read_i32(p, offset)
	local v = read_u32(p, offset)

	if v >= 2147483648 then v = v - 4294967296 end

	return v
end

local function predictor(data, size)
	local ptr = ffi.cast("uint8_t*", data)

	for i = 1, size - 1 do
		ptr[i] = band(ptr[i] + ptr[i - 1] - 128, 0xFF)
	end
end

local reorder_tmp = nil
local reorder_tmp_size = 0

local function reorder(data, size)
	if not reorder_tmp or reorder_tmp_size < size then
		reorder_tmp = ffi.new("uint8_t[?]", size)
		reorder_tmp_size = size
	end

	local src = ffi.cast("uint8_t*", data)
	local t1 = 0
	local t2 = math.floor((size + 1) / 2)

	for i = 0, size - 1, 2 do
		reorder_tmp[i] = src[t1]
		t1 = t1 + 1

		if i + 1 < size then
			reorder_tmp[i + 1] = src[t2]
			t2 = t2 + 1
		end
	end

	ffi.copy(data, reorder_tmp, size)
end

local function rle_decompress(src, src_size, dst, dst_size)
	local i = 0
	local o = 0

	while i < src_size do
		local count = src[i]
		i = i + 1

		if count > 127 then
			count = 256 - count

			if o + count > dst_size or i + count > src_size then
				error("corrupt EXR RLE block")
			end

			ffi.copy(dst + o, src + i, count)
			i = i + count
			o = o + count
		else
			count = count + 1

			if o + count > dst_size then error("corrupt EXR RLE block") end

			ffi.fill(dst + o, count, src[i])
			i = i + 1
			o = o + count
		end
	end

	if o ~= dst_size then error("EXR RLE block has the wrong size") end
end

local HUF_ENCSIZE = 65537
local HUF_DECBITS = 14
local HUF_DECSIZE = 16384
local HUF_MAX_CODE_LENGTH = 33
local SHORT_ZEROCODE_RUN = 59
local LONG_ZEROCODE_RUN = 63
local SHORTEST_LONG_RUN = 2 + LONG_ZEROCODE_RUN - SHORT_ZEROCODE_RUN
local huf_length = ffi.new("uint8_t[?]", HUF_ENCSIZE)
local huf_code = ffi.new("uint32_t[?]", HUF_ENCSIZE)
local huf_dec_length = ffi.new("uint8_t[?]", HUF_DECSIZE)
local huf_dec_symbol = ffi.new("uint32_t[?]", HUF_DECSIZE)
local huf_scratch = nil
local huf_scratch_size = 0
local table_src, table_pos, table_size, table_c, table_lc

local function get_table_bits(n)
	while table_lc < n do
		if table_pos >= table_size then error("EXR Huffman table is truncated") end

		table_c = table_c * 256 + table_src[table_pos]
		table_pos = table_pos + 1
		table_lc = table_lc + 8
	end

	table_lc = table_lc - n
	local value = band(rshift(table_c, table_lc), lshift(1, n) - 1)
	table_c = band(table_c, lshift(1, table_lc) - 1)
	return value
end

local function huf_uncompress(src, src_size, out, out_count)
	if src_size < 20 then error("EXR Huffman block is too small") end

	local first = read_u32(src, 0)
	local last = read_u32(src, 4)
	local bit_count = read_u32(src, 12)

	if first >= HUF_ENCSIZE or last >= HUF_ENCSIZE then
		error("EXR Huffman table out of range")
	end

	ffi.fill(huf_length, HUF_ENCSIZE)
	table_src, table_pos, table_size, table_c, table_lc = src, 20, src_size, 0, 0
	local sym = first

	while sym <= last do
		local l = get_table_bits(6)
		local run

		if l == LONG_ZEROCODE_RUN then
			run = get_table_bits(8) + SHORTEST_LONG_RUN
		elseif l >= SHORT_ZEROCODE_RUN then
			run = l - SHORT_ZEROCODE_RUN + 2
		else
			huf_length[sym] = l
			sym = sym + 1
		end

		if run then
			if sym + run > last + 1 then error("EXR Huffman table run is too long") end

			sym = sym + run
		end
	end

	local table_pos = table_pos
	local counts = {}

	for i = 0, 58 do
		counts[i] = 0
	end

	for i = 0, HUF_ENCSIZE - 1 do
		local l = huf_length[i]
		counts[l] = counts[l] + 1
	end

	local code = 0

	for i = 58, 0, -1 do
		local next_code = rshift(code + counts[i], 1)
		counts[i] = code
		code = next_code
	end

	for i = 0, HUF_ENCSIZE - 1 do
		local l = huf_length[i]

		if l > 0 then
			huf_code[i] = counts[l]
			counts[l] = counts[l] + 1
		end
	end

	ffi.fill(huf_dec_length, HUF_DECSIZE)
	local long_lists = {}

	for i = first, last do
		local l = huf_length[i]

		if l > HUF_MAX_CODE_LENGTH then
			error("EXR Huffman code length " .. l .. " is not supported")
		end

		if l > HUF_DECBITS then
			local index = math.floor(huf_code[i] / 2 ^ (l - HUF_DECBITS))

			if huf_dec_length[index] ~= 0 then error("EXR Huffman table is invalid") end

			local list = long_lists[index]

			if not list then
				list = {}
				long_lists[index] = list
			end

			list[#list + 1] = i
		elseif l > 0 then
			local base = lshift(huf_code[i], HUF_DECBITS - l)

			for k = base, base + lshift(1, HUF_DECBITS - l) - 1 do
				if huf_dec_length[k] ~= 0 or long_lists[k] then
					error("EXR Huffman table is invalid")
				end

				huf_dec_length[k] = l
				huf_dec_symbol[k] = i
			end
		end
	end

	local data_size = src_size - table_pos
	local needed = data_size + 16

	if huf_scratch_size < needed then
		huf_scratch = ffi.new("uint8_t[?]", needed)
		huf_scratch_size = needed
	end

	local s = huf_scratch
	ffi.copy(s, src + table_pos, data_size)
	ffi.fill(s + data_size, 16)
	local bitpos = 0
	local o = 0

	while bitpos < bit_count do
		local bi = rshift(bitpos, 3)
		local sh = band(bitpos, 7)
		local v = s[bi] * 65536 + s[bi + 1] * 256 + s[bi + 2]
		local index = band(rshift(v, 10 - sh), 0x3fff)
		local l = huf_dec_length[index]
		local symbol

		if l ~= 0 then
			symbol = huf_dec_symbol[index]
			bitpos = bitpos + l
		else
			local list = long_lists[index]

			if not list then error("EXR Huffman code is invalid") end

			local wide = (((s[bi] * 256 + s[bi + 1]) * 256 + s[bi + 2]) * 256 + s[bi + 3]) * 256 + s[bi + 4]

			for j = 1, #list do
				local candidate = list[j]
				local cl = huf_length[candidate]

				if math.floor(wide / 2 ^ (40 - sh - cl)) % 2 ^ cl == huf_code[candidate] then
					symbol = candidate
					bitpos = bitpos + cl

					break
				end
			end

			if not symbol then error("EXR Huffman code is invalid") end
		end

		if symbol == last then
			bi = rshift(bitpos, 3)
			sh = band(bitpos, 7)
			v = s[bi] * 65536 + s[bi + 1] * 256 + s[bi + 2]
			local repeat_count = band(rshift(v, 16 - sh), 0xff)
			bitpos = bitpos + 8

			if o == 0 or o + repeat_count > out_count then
				error("EXR Huffman run is invalid")
			end

			local previous = out[o - 1]

			for k = o, o + repeat_count - 1 do
				out[k] = previous
			end

			o = o + repeat_count
		else
			if o >= out_count then error("EXR Huffman data is too long") end

			out[o] = symbol
			o = o + 1
		end
	end

	if o ~= out_count then error("EXR Huffman data is too short") end
end

local function wdec14(l, h)
	l = arshift(lshift(l, 16), 16)
	h = arshift(lshift(h, 16), 16)
	local a = l + band(h, 1) + arshift(h, 1)
	return band(a, 0xffff), band(a - h, 0xffff)
end

local function wdec16(l, h)
	local b = band(l - rshift(h, 1), 0xffff)
	return band(h + b - 32768, 0xffff), b
end

local function wav2_decode(d, base, nx, ox, ny, oy, max_value)
	local wdec = max_value < 16384 and wdec14 or wdec16
	local n = nx > ny and ny or nx
	local p = 1

	while p <= n do
		p = p * 2
	end

	p = rshift(p, 1)
	local p2 = p
	p = rshift(p, 1)

	while p >= 1 do
		local oy1 = oy * p
		local oy2 = oy * p2
		local ox1 = ox * p
		local ox2 = ox * p2
		local py = base
		local ey = base + oy * (ny - p2)

		while py <= ey do
			local px = py
			local ex = py + ox * (nx - p2)

			while px <= ex do
				local i01 = px + ox1
				local i10 = px + oy1
				local i11 = i10 + ox1
				local a00, a10 = wdec(d[px], d[i10])
				local a01, a11 = wdec(d[i01], d[i11])
				d[px], d[i01] = wdec(a00, a01)
				d[i10], d[i11] = wdec(a10, a11)
				px = px + ox2
			end

			if band(nx, p) ~= 0 then
				local i10 = px + oy1
				d[px], d[i10] = wdec(d[px], d[i10])
			end

			py = py + oy2
		end

		if band(ny, p) ~= 0 then
			local px = py
			local ex = py + ox * (nx - p2)

			while px <= ex do
				local i01 = px + ox1
				d[px], d[i01] = wdec(d[px], d[i01])
				px = px + ox2
			end
		end

		p2 = p
		p = rshift(p, 1)
	end
end

local piz_bitmap = ffi.new("uint8_t[?]", 8192)
local piz_lut = ffi.new("uint16_t[?]", 65536)
local piz_tmp = nil
local piz_tmp_size = 0

local function piz_decompress(src, src_size, width, num_lines, channels, dst)
	local total = 0
	local channel_offsets = {}

	for i, ch in ipairs(channels) do
		channel_offsets[i] = total
		total = total + width * num_lines * (ch.pixel_type == PIXEL_HALF and 1 or 2)
	end

	if piz_tmp_size < total then
		piz_tmp = ffi.new("uint16_t[?]", total)
		piz_tmp_size = total
	end

	local min_nonzero = src[0] + src[1] * 256
	local max_nonzero = src[2] + src[3] * 256
	local pos = 4
	ffi.fill(piz_bitmap, 8192)

	if min_nonzero <= max_nonzero then
		if max_nonzero >= 8192 then error("corrupt EXR PIZ bitmap") end

		local count = max_nonzero - min_nonzero + 1
		ffi.copy(piz_bitmap + min_nonzero, src + pos, count)
		pos = pos + count
	end

	local k = 0

	for i = 0, 65535 do
		if i == 0 or band(piz_bitmap[rshift(i, 3)], lshift(1, band(i, 7))) ~= 0 then
			piz_lut[k] = i
			k = k + 1
		end
	end

	local max_value = k - 1

	for i = k, 65535 do
		piz_lut[i] = 0
	end

	local huf_size = read_u32(src, pos)
	pos = pos + 4
	huf_uncompress(src + pos, huf_size, piz_tmp, total)

	for i, ch in ipairs(channels) do
		local size = ch.pixel_type == PIXEL_HALF and 1 or 2

		for j = 0, size - 1 do
			wav2_decode(piz_tmp, channel_offsets[i] + j, width, size, num_lines, width * size, max_value)
		end
	end

	for i = 0, total - 1 do
		piz_tmp[i] = piz_lut[piz_tmp[i]]
	end

	local out = 0
	local cursors = {}

	for i = 1, #channels do
		cursors[i] = channel_offsets[i]
	end

	for _ = 1, num_lines do
		for i, ch in ipairs(channels) do
			local count = width * (ch.pixel_type == PIXEL_HALF and 1 or 2)
			ffi.copy(dst + out, piz_tmp + cursors[i], count * 2)
			cursors[i] = cursors[i] + count
			out = out + count * 2
		end
	end
end

function exr.DecodeBuffer(input)
	if input:ReadU32LE() ~= 0x01312f76 then error("Not an EXR file") end

	local version_field = input:ReadU32LE()

	if band(version_field, 0xFF) ~= 2 then
		error("Unsupported EXR version: " .. band(version_field, 0xFF))
	end

	if band(version_field, 0x1A00) ~= 0 then
		error("tiled, deep and multipart EXR files are not supported")
	end

	local header = {}

	while true do
		local name = read_null_terminated_string(input)

		if name == "" then break end

		local type = read_null_terminated_string(input)
		local size = input:ReadU32LE()
		local start_pos = input:GetPosition()
		local value = true

		if type == "box2i" then
			value = {
				xMin = input:ReadI32LE(),
				yMin = input:ReadI32LE(),
				xMax = input:ReadI32LE(),
				yMax = input:ReadI32LE(),
			}
		elseif type == "chlist" then
			value = {}

			while true do
				local ch_name = read_null_terminated_string(input)

				if ch_name == "" then break end

				table.insert(
					value,
					{
						name = ch_name,
						pixel_type = input:ReadI32LE(),
						pLinear = input:ReadByte(),
						reserved = input:ReadBytes(3),
						xSampling = input:ReadI32LE(),
						ySampling = input:ReadI32LE(),
					}
				)
			end
		elseif type == "compression" or type == "lineOrder" then
			value = input:ReadByte()
		end

		header[name] = value
		input:SetPosition(start_pos + size)
	end

	if header.tiles then error("tiled EXR files are not supported") end

	local data_window = header.dataWindow
	local width = data_window.xMax - data_window.xMin + 1
	local height = data_window.yMax - data_window.yMin + 1
	local compression = header.compression or COMPRESSION_NONE
	local lines_per_block = 1

	if compression == COMPRESSION_ZIP or compression == 5 then
		lines_per_block = 16
	elseif compression == COMPRESSION_PIZ or compression == 6 or compression == 7 then
		lines_per_block = 32
	end

	if
		compression ~= COMPRESSION_NONE and
		compression ~= 1 and
		compression ~= COMPRESSION_ZIPS and
		compression ~= COMPRESSION_ZIP and
		compression ~= COMPRESSION_PIZ
	then
		error("Unsupported EXR compression: " .. tostring(compression))
	end

	local channels = header.channels
	local channel_targets = {}
	local bytes_per_pixel = 0

	for i, ch in ipairs(channels) do
		if ch.xSampling ~= 1 or ch.ySampling ~= 1 then
			error("subsampled EXR channels are not supported")
		end

		channel_targets[i] = ({R = 0, G = 1, B = 2, A = 3})[ch.name]
		bytes_per_pixel = bytes_per_pixel + (ch.pixel_type == PIXEL_HALF and 2 or 4)
	end

	local num_blocks = math.ceil(height / lines_per_block)
	local offsets = {}

	for i = 1, num_blocks do
		offsets[i] = tonumber(input:ReadU64LE())
	end

	local file = ffi.cast("uint8_t*", input:GetBuffer())
	local output = ffi.new("float[?]", width * height * 4)

	for i = 0, width * height - 1 do
		output[i * 4 + 3] = 1.0
	end

	local block_bytes = ffi.new("uint8_t[?]", width * lines_per_block * bytes_per_pixel)

	for block = 1, num_blocks do
		local offset = offsets[block]
		local block_y = read_i32(file, offset)
		local data_size = read_u32(file, offset + 4)
		local src = file + offset + 8
		local num_lines = math.min(lines_per_block, height - (block_y - data_window.yMin))
		local expected_size = width * num_lines * bytes_per_pixel
		local lines

		if data_size >= expected_size or compression == COMPRESSION_NONE then
			lines = src
		elseif compression == COMPRESSION_PIZ then
			piz_decompress(src, data_size, width, num_lines, channels, block_bytes)
			lines = block_bytes
		elseif compression == 1 then
			rle_decompress(src, data_size, block_bytes, expected_size)
			predictor(block_bytes, expected_size)
			reorder(block_bytes, expected_size)
			lines = block_bytes
		else
			local decompressed = deflate.inflate_zlib{
				input = ffi.string(src, data_size),
				output = Buffer.New(block_bytes, expected_size):MakeWritable(),
				disable_crc = true,
			}

			if decompressed:GetSize() ~= expected_size then
				error("EXR ZIP block has the wrong size")
			end

			predictor(block_bytes, expected_size)
			reorder(block_bytes, expected_size)
			lines = block_bytes
		end

		local pos = 0

		for ly = 0, num_lines - 1 do
			local out_row = (block_y - data_window.yMin + ly) * width * 4

			for i, ch in ipairs(channels) do
				local target = channel_targets[i]
				local pixel_type = ch.pixel_type

				if target then
					local out = output + out_row + target

					if pixel_type == PIXEL_HALF then
						local row = ffi.cast("uint16_t*", lines + pos)

						for x = 0, width - 1 do
							out[x * 4] = half_to_float_table[row[x]]
						end
					elseif pixel_type == PIXEL_FLOAT then
						local row = ffi.cast("float*", lines + pos)

						for x = 0, width - 1 do
							out[x * 4] = row[x]
						end
					else
						local row = ffi.cast("uint32_t*", lines + pos)

						for x = 0, width - 1 do
							out[x * 4] = row[x]
						end
					end
				end

				pos = pos + width * (pixel_type == PIXEL_HALF and 2 or 4)
			end
		end
	end

	return {
		width = width,
		height = height,
		vulkan_format = "r32g32b32a32_sfloat",
		data = output,
		buffer = Buffer.New(output, width * height * 16),
	}
end

return exr
