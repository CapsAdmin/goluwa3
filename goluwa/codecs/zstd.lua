local ffi = require("ffi")
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local zstd = {}
local bytes_t = ffi.typeof("uint8_t[?]")
local u32_ptr_t = ffi.typeof("const uint32_t *")
local i16_array_t = ffi.typeof("int16_t[?]")
local u8_array_t = ffi.typeof("uint8_t[?]")
local u16_array_t = ffi.typeof("uint16_t[?]")
local u32_array_t = ffi.typeof("uint32_t[?]")
local FRAME_MAGIC = 0xFD2FB528
local PAD = 8
local MAX_BLOCK = 128 * 1024

local function read_u32(p, byte)
	return ffi.cast(u32_ptr_t, p + byte)[0]
end

-- bits [pos, pos + n) of a little endian bit stream, n <= 24
local function peek(p, pos, n)
	return band(
		rshift(ffi.cast(u32_ptr_t, p + rshift(pos, 3))[0], band(pos, 7)),
		lshift(1, n) - 1
	)
end

local function highbit(v)
	local n = 0

	while v > 1 do
		v = rshift(v, 1)
		n = n + 1
	end

	return n
end

local function new_fse_table(log)
	local size = lshift(1, log)
	return {
		log = log,
		symbol = u8_array_t(size),
		bits = u8_array_t(size),
		base = u16_array_t(size),
	}
end

local function build_fse_table(t, norm, max_symbol, log)
	local size = lshift(1, log)
	local high = size - 1
	local next_state = u16_array_t(max_symbol + 1)
	t.log = log

	for s = 0, max_symbol do
		if norm[s] == -1 then
			t.symbol[high] = s
			high = high - 1
			next_state[s] = 1
		else
			next_state[s] = norm[s]
		end
	end

	local step = rshift(size, 1) + rshift(size, 3) + 3
	local mask = size - 1
	local pos = 0

	for s = 0, max_symbol do
		for _ = 1, norm[s] do
			t.symbol[pos] = s
			pos = band(pos + step, mask)

			while pos > high do
				pos = band(pos + step, mask)
			end
		end
	end

	if pos ~= 0 then error("zstd: corrupt fse distribution", 2) end

	for u = 0, size - 1 do
		local s = t.symbol[u]
		local n = next_state[s]
		next_state[s] = n + 1
		local nb = log - highbit(n)
		t.bits[u] = nb
		t.base[u] = lshift(n, nb) - size
	end

	return t
end

local function build_rle_table(t, symbol)
	t.log = 0
	t.symbol[0] = symbol
	t.bits[0] = 0
	t.base[0] = 0
	return t
end

local function read_fse_description(p, start, limit, t, max_symbol, max_log)
	local norm = i16_array_t(256)
	local pos = start * 8
	local log = peek(p, pos, 4) + 5
	pos = pos + 4

	if log > max_log then error("zstd: fse accuracy log too large", 2) end

	local remaining = lshift(1, log) + 1
	local threshold = lshift(1, log)
	local nb = log + 1
	local symbol = 0

	while remaining > 1 and symbol <= max_symbol do
		local max = 2 * threshold - 1 - remaining
		local count
		local low = band(peek(p, pos, nb), threshold - 1)

		if low < max then
			count = low
			pos = pos + nb - 1
		else
			count = peek(p, pos, nb)

			if count >= threshold then count = count - max end

			pos = pos + nb
		end

		count = count - 1
		remaining = remaining - (count < 0 and -count or count)
		norm[symbol] = count
		symbol = symbol + 1

		if count == 0 then
			while true do
				local repeat_count = peek(p, pos, 2)
				pos = pos + 2

				for _ = 1, repeat_count do
					norm[symbol] = 0
					symbol = symbol + 1
				end

				if repeat_count ~= 3 then break end
			end
		end

		while remaining < threshold do
			nb = nb - 1
			threshold = rshift(threshold, 1)
		end
	end

	if remaining ~= 1 or symbol > max_symbol + 1 then
		error("zstd: corrupt fse table description", 2)
	end

	local used = rshift(pos + 7, 3) - start

	if start + used > limit then error("zstd: fse description out of bounds", 2) end

	build_fse_table(t, norm, symbol - 1, log)
	return used
end

local function predefined(values, log)
	local norm = i16_array_t(#values)

	for i, v in ipairs(values) do
		norm[i - 1] = v
	end

	return build_fse_table(new_fse_table(log), norm, #values - 1, log)
end

local LL_DEFAULT = predefined(
	{
		4,
		3,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		1,
		1,
		1,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		2,
		3,
		2,
		1,
		1,
		1,
		1,
		1,
		-1,
		-1,
		-1,
		-1,
	},
	6
)
local ML_DEFAULT = predefined(
	{
		1,
		4,
		3,
		2,
		2,
		2,
		2,
		2,
		2,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		-1,
		-1,
		-1,
		-1,
		-1,
		-1,
		-1,
	},
	6
)
local OF_DEFAULT = predefined(
	{
		1,
		1,
		1,
		1,
		1,
		1,
		2,
		2,
		2,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		-1,
		-1,
		-1,
		-1,
		-1,
	},
	5
)
local LL_BASE = u32_array_t(36)
local LL_BITS = u8_array_t(36)
local ML_BASE = u32_array_t(53)
local ML_BITS = u8_array_t(53)
local OF_BASE = ffi.new("double[32]")

for i = 0, 31 do
	OF_BASE[i] = 2 ^ i
end

do
	local ll = {
		{16, 1},
		{18, 1},
		{20, 1},
		{22, 1},
		{24, 2},
		{28, 2},
		{32, 3},
		{40, 3},
		{48, 4},
		{64, 6},
		{128, 7},
		{256, 8},
		{512, 9},
		{1024, 10},
		{2048, 11},
		{4096, 12},
		{8192, 13},
		{16384, 14},
		{32768, 15},
		{65536, 16},
	}

	for i = 0, 15 do
		LL_BASE[i] = i
	end

	for i, v in ipairs(ll) do
		LL_BASE[15 + i], LL_BITS[15 + i] = v[1], v[2]
	end

	local ml = {
		{35, 1},
		{37, 1},
		{39, 1},
		{41, 1},
		{43, 2},
		{47, 2},
		{51, 3},
		{59, 3},
		{67, 4},
		{83, 4},
		{99, 5},
		{131, 7},
		{259, 8},
		{515, 9},
		{1027, 10},
		{2051, 11},
		{4099, 12},
		{8195, 13},
		{16387, 14},
		{32771, 15},
		{65539, 16},
	}

	for i = 0, 31 do
		ML_BASE[i] = i + 3
	end

	for i, v in ipairs(ml) do
		ML_BASE[31 + i], ML_BITS[31 + i] = v[1], v[2]
	end
end

local function new_context()
	return {
		huf_symbol = u8_array_t(2048),
		huf_bits = u8_array_t(2048),
		huf_log = 0,
		huf_ready = false,
		ll = new_fse_table(9),
		ml = new_fse_table(9),
		of = new_fse_table(8),
		ll_table = nil,
		ml_table = nil,
		of_table = nil,
		literals = bytes_t(MAX_BLOCK + 64),
		weights = u8_array_t(256),
		weight_fse = new_fse_table(6),
		rep = ffi.new("uint32_t[3]"),
	}
end

-- reads a backward bit stream's start: the position past the highest set bit of its last byte
local function backward_start(p, start, size)
	local last = p[start + size - 1]

	if last == 0 then error("zstd: bit stream has no end marker", 3) end

	return start * 8 + (size - 1) * 8 + highbit(last)
end

local function read_huffman_table(ctx, p, start, limit)
	local header = p[start]
	local weights = ctx.weights
	local count
	local used

	if header < 128 then
		local size = header
		used = 1 + size

		if start + used > limit then error("zstd: huffman weights out of bounds", 2) end

		local t = ctx.weight_fse
		local desc = read_fse_description(p, start + 1, start + 1 + size, t, 255, 6)
		local stream_start = start + 1 + desc
		local stream_size = size - desc
		local pos = backward_start(p, stream_start, stream_size)
		local floor_pos = stream_start * 8
		local log = t.log
		pos = pos - log
		local s1 = peek(p, pos, log)
		pos = pos - log
		local s2 = peek(p, pos, log)
		count = 0

		while true do
			weights[count] = t.symbol[s1]
			count = count + 1
			local nb = t.bits[s1]
			pos = pos - nb
			s1 = t.base[s1] + peek(p, pos, nb)

			if pos < floor_pos then
				weights[count] = t.symbol[s2]
				count = count + 1

				break
			end

			weights[count] = t.symbol[s2]
			count = count + 1
			nb = t.bits[s2]
			pos = pos - nb
			s2 = t.base[s2] + peek(p, pos, nb)

			if pos < floor_pos then
				weights[count] = t.symbol[s1]
				count = count + 1

				break
			end

			if count > 253 then error("zstd: too many huffman weights", 2) end
		end
	else
		count = header - 127
		used = 1 + rshift(count + 1, 1)

		if start + used > limit then error("zstd: huffman weights out of bounds", 2) end

		for i = 0, count - 1 do
			local b = p[start + 1 + rshift(i, 1)]
			weights[i] = band(i, 1) == 0 and rshift(b, 4) or band(b, 15)
		end
	end

	local total = 0

	for i = 0, count - 1 do
		local w = weights[i]

		if w > 11 then error("zstd: huffman weight too large", 2) end

		if w > 0 then total = total + lshift(1, w - 1) end
	end

	if total == 0 then error("zstd: empty huffman table", 2) end

	local log = highbit(total) + 1
	local rest = lshift(1, log) - total

	if band(rest, rest - 1) ~= 0 then
		error("zstd: huffman weights do not sum to a power of two", 2)
	end

	weights[count] = highbit(rest) + 1
	count = count + 1

	if log > 11 then error("zstd: huffman table too deep", 2) end

	local rank_start = ffi.new("uint32_t[13]")

	for i = 0, count - 1 do
		local w = weights[i]

		if w > 0 then rank_start[w] = rank_start[w] + lshift(1, w - 1) end
	end

	local next_start = 0

	for w = 1, 12 do
		local c = rank_start[w]
		rank_start[w] = next_start
		next_start = next_start + c
	end

	local symbol, bits = ctx.huf_symbol, ctx.huf_bits

	for s = 0, count - 1 do
		local w = weights[s]

		if w > 0 then
			local length = lshift(1, w - 1)
			local at = rank_start[w]
			local nb = log + 1 - w

			for i = at, at + length - 1 do
				symbol[i] = s
				bits[i] = nb
			end

			rank_start[w] = at + length
		end
	end

	ctx.huf_log = log
	ctx.huf_ready = true
	return used
end

local function decode_huffman_stream(ctx, p, start, size, out, out_at, count)
	if size == 0 then
		if count == 0 then return end

		error("zstd: empty huffman stream", 3)
	end

	local pos = backward_start(p, start, size)
	local floor_pos = start * 8
	local log = ctx.huf_log
	local symbol, bits = ctx.huf_symbol, ctx.huf_bits
	local mask = lshift(1, log) - 1

	for i = out_at, out_at + count - 1 do
		local start_bit = pos - log
		local index = band(
			rshift(ffi.cast(u32_ptr_t, p + rshift(start_bit, 3))[0], band(start_bit, 7)),
			mask
		)
		out[i] = symbol[index]
		pos = pos - bits[index]
	end

	if pos ~= floor_pos then error("zstd: huffman stream not fully consumed", 3) end
end

local function read_literals(ctx, p, start, limit)
	local b0 = p[start]
	local kind = band(b0, 3)
	local size_format = band(rshift(b0, 2), 3)
	local out = ctx.literals

	if kind == 0 or kind == 1 then
		local regenerated, header

		if size_format == 0 or size_format == 2 then
			regenerated, header = rshift(b0, 3), 1
		elseif size_format == 1 then
			regenerated, header = rshift(b0, 4) + lshift(p[start + 1], 4), 2
		else
			regenerated, header = rshift(b0, 4) + lshift(p[start + 1], 4) + lshift(p[start + 2], 12), 3
		end

		if regenerated > MAX_BLOCK then error("zstd: literals too large", 2) end

		if kind == 0 then
			if start + header + regenerated > limit then
				error("zstd: raw literals out of bounds", 2)
			end

			ffi.copy(out, p + start + header, regenerated)
			return regenerated, header + regenerated
		end

		ffi.fill(out, regenerated, p[start + header])
		return regenerated, header + 1
	end

	local regenerated, compressed, header
	local streams = size_format == 0 and 1 or 4

	if size_format == 0 or size_format == 1 then
		local v = rshift(b0, 4) + lshift(p[start + 1], 4) + lshift(p[start + 2], 12)
		regenerated, compressed, header = band(v, 0x3FF), rshift(v, 10), 3
	elseif size_format == 2 then
		local v = rshift(b0, 4) + lshift(p[start + 1], 4) + lshift(p[start + 2], 12) + p[start + 3] * 0x100000
		regenerated, compressed, header = v % 0x4000, math.floor(v / 0x4000), 4
	else
		local v = rshift(b0, 4) + lshift(p[start + 1], 4) + lshift(p[start + 2], 12) + p[start + 3] * 0x100000 + p[start + 4] * 0x10000000
		regenerated, compressed, header = v % 0x40000, math.floor(v / 0x40000), 5
	end

	if regenerated > MAX_BLOCK then error("zstd: literals too large", 2) end

	local at = start + header
	local stop = at + compressed

	if stop > limit then error("zstd: compressed literals out of bounds", 2) end

	if kind == 2 then
		at = at + read_huffman_table(ctx, p, at, stop)
	elseif not ctx.huf_ready then
		error("zstd: treeless literals without a previous huffman table", 2)
	end

	if streams == 1 then
		decode_huffman_stream(ctx, p, at, stop - at, out, 0, regenerated)
	else
		local s1 = p[at] + lshift(p[at + 1], 8)
		local s2 = p[at + 2] + lshift(p[at + 3], 8)
		local s3 = p[at + 4] + lshift(p[at + 5], 8)
		local data = at + 6
		local s4 = stop - data - s1 - s2 - s3

		if s4 < 0 then error("zstd: corrupt literal jump table", 2) end

		local quarter = rshift(regenerated + 3, 2)
		local last = regenerated - 3 * quarter

		if last < 0 then error("zstd: corrupt literal stream sizes", 2) end

		decode_huffman_stream(ctx, p, data, s1, out, 0, quarter)
		decode_huffman_stream(ctx, p, data + s1, s2, out, quarter, quarter)
		decode_huffman_stream(ctx, p, data + s1 + s2, s3, out, quarter * 2, quarter)
		decode_huffman_stream(ctx, p, data + s1 + s2 + s3, s4, out, quarter * 3, last)
	end

	return regenerated, stop - start
end

local function select_table(ctx, mode, p, at, limit, own, default, max_symbol, max_log, name)
	if mode == 0 then
		ctx[name] = default
		return 0
	elseif mode == 1 then
		ctx[name] = build_rle_table(own, p[at])
		return 1
	elseif mode == 2 then
		local used = read_fse_description(p, at, limit, own, max_symbol, max_log)
		ctx[name] = own
		return used
	end

	if not ctx[name] then error("zstd: repeat mode without a previous table", 3) end

	return 0
end

-- n <= 31 extra bits read from a backward stream ending at pos
local function read_extra(p, pos, n)
	if n <= 24 then return pos - n, peek(p, pos - n, n) end

	local low_n = n - 24
	local high = peek(p, pos - 24, 24)
	pos = pos - n
	return pos, high * lshift(1, low_n) + peek(p, pos, low_n)
end

local function decode_block(ctx, p, start, size, dst, dst_at, dst_end)
	local limit = start + size
	local literal_count, used = read_literals(ctx, p, start, limit)
	local at = start + used
	local literals = ctx.literals
	local b0 = p[at]
	local sequences

	if b0 == 0 then
		sequences, at = 0, at + 1
	elseif b0 < 128 then
		sequences, at = b0, at + 1
	elseif b0 < 255 then
		sequences, at = lshift(b0 - 128, 8) + p[at + 1], at + 2
	else
		sequences, at = p[at + 1] + lshift(p[at + 2], 8) + 0x7F00, at + 3
	end

	if sequences == 0 then
		if dst_at + literal_count > dst_end then error("zstd: output overflow", 2) end

		ffi.copy(dst + dst_at, literals, literal_count)
		return dst_at + literal_count
	end

	local modes = p[at]
	at = at + 1
	at = at + select_table(ctx, rshift(modes, 6), p, at, limit, ctx.ll, LL_DEFAULT, 35, 9, "ll_table")
	at = at + select_table(
			ctx,
			band(rshift(modes, 4), 3),
			p,
			at,
			limit,
			ctx.of,
			OF_DEFAULT,
			31,
			8,
			"of_table"
		)
	at = at + select_table(
			ctx,
			band(rshift(modes, 2), 3),
			p,
			at,
			limit,
			ctx.ml,
			ML_DEFAULT,
			52,
			9,
			"ml_table"
		)

	if at >= limit then error("zstd: sequence bit stream missing", 2) end

	local ll, of, ml = ctx.ll_table, ctx.of_table, ctx.ml_table
	local ll_symbol, ll_bits, ll_base = ll.symbol, ll.bits, ll.base
	local of_symbol, of_bits, of_base = of.symbol, of.bits, of.base
	local ml_symbol, ml_bits, ml_base = ml.symbol, ml.bits, ml.base
	local pos = backward_start(p, at, limit - at)
	local floor_pos = at * 8
	pos = pos - ll.log
	local ll_state = peek(p, pos, ll.log)
	pos = pos - of.log
	local of_state = peek(p, pos, of.log)
	pos = pos - ml.log
	local ml_state = peek(p, pos, ml.log)
	local rep = ctx.rep
	local r1, r2, r3 = rep[0], rep[1], rep[2]
	local lit_at = 0
	local out = dst_at

	for s = 1, sequences do
		local of_code = of_symbol[of_state]
		local ml_code = ml_symbol[ml_state]
		local ll_code = ll_symbol[ll_state]
		local offset_value
		pos, offset_value = read_extra(p, pos, of_code)
		offset_value = offset_value + OF_BASE[of_code]
		local match_length = ML_BASE[ml_code]
		local nb = ML_BITS[ml_code]

		if nb > 0 then
			pos = pos - nb
			match_length = match_length + peek(p, pos, nb)
		end

		local literal_length = LL_BASE[ll_code]
		nb = LL_BITS[ll_code]

		if nb > 0 then
			pos = pos - nb
			literal_length = literal_length + peek(p, pos, nb)
		end

		local offset

		if offset_value > 3 then
			offset = offset_value - 3
			r3, r2, r1 = r2, r1, offset
		else
			local index = offset_value - 1

			if literal_length == 0 then index = index + 1 end

			if index == 0 then
				offset = r1
			else
				if index == 3 then
					offset = r1 - 1
				elseif index == 1 then
					offset = r2
				else
					offset = r3
				end

				if index > 1 then r3 = r2 end

				r2, r1 = r1, offset
			end
		end

		if s < sequences then
			nb = ll_bits[ll_state]
			pos = pos - nb
			ll_state = ll_base[ll_state] + peek(p, pos, nb)
			nb = ml_bits[ml_state]
			pos = pos - nb
			ml_state = ml_base[ml_state] + peek(p, pos, nb)
			nb = of_bits[of_state]
			pos = pos - nb
			of_state = of_base[of_state] + peek(p, pos, nb)
		end

		if
			lit_at + literal_length > literal_count or
			out + literal_length + match_length > dst_end
		then
			error("zstd: sequence out of bounds", 2)
		end

		if literal_length > 0 then
			ffi.copy(dst + out, literals + lit_at, literal_length)
			out = out + literal_length
			lit_at = lit_at + literal_length
		end

		if offset == 0 or offset > out then
			error("zstd: match offset out of bounds", 2)
		end

		local from = out - offset

		if offset >= match_length then
			ffi.copy(dst + out, dst + from, match_length)
			out = out + match_length
		else
			for i = 0, match_length - 1 do
				dst[out + i] = dst[from + i]
			end

			out = out + match_length
		end
	end

	if pos ~= floor_pos then
		error("zstd: sequence bit stream not fully consumed", 2)
	end

	rep[0], rep[1], rep[2] = r1, r2, r3
	local rest = literal_count - lit_at

	if out + rest > dst_end then error("zstd: output overflow", 2) end

	ffi.copy(dst + out, literals + lit_at, rest)
	return out + rest
end

-- returns the frame's content size or nil when the header does not say
function zstd.GetContentSize(src, src_size)
	src = ffi.cast("const uint8_t *", src)

	if src_size < 6 or read_u32(src, 0) ~= FRAME_MAGIC then return nil end

	local descriptor = src[4]
	local fcs_flag = rshift(descriptor, 6)
	local single = band(descriptor, 0x20) ~= 0
	local dict_size = ({0, 1, 2, 4})[band(descriptor, 3) + 1]
	local at = 5 + (single and 0 or 1) + dict_size

	if fcs_flag == 0 then
		if single then return src[at] end

		return nil
	elseif fcs_flag == 1 then
		return src[at] + src[at + 1] * 256 + 256
	elseif fcs_flag == 2 then
		return read_u32(src, at)
	end

	return read_u32(src, at) + read_u32(src, at + 4) * 4294967296
end

function zstd.Decompress(src, src_size, dst, dst_capacity)
	local padded = bytes_t(src_size + PAD * 2)
	ffi.copy(padded + PAD, src, src_size)
	local p = padded
	local at = PAD
	local stop = PAD + src_size
	local out = 0
	dst = ffi.cast("uint8_t *", dst)
	local ctx = new_context()

	while at < stop do
		if stop - at < 4 then error("zstd: truncated frame") end

		local magic = read_u32(p, at)

		if band(magic, 0xFFFFFFF0) == band(0x184D2A50, 0xFFFFFFF0) then
			at = at + 8 + read_u32(p, at + 4)
		elseif magic == FRAME_MAGIC then
			local descriptor = p[at + 4]
			local fcs_flag = rshift(descriptor, 6)
			local single = band(descriptor, 0x20) ~= 0
			local checksum = band(descriptor, 4) ~= 0
			local dict_flag = band(descriptor, 3)

			if band(descriptor, 8) ~= 0 then error("zstd: reserved frame header bit set") end

			local header = 5 + (single and 0 or 1) + ({0, 1, 2, 4})[dict_flag + 1]

			if dict_flag ~= 0 then
				local id = 0

				for i = dict_flag == 3 and 3 or dict_flag - 1, 0, -1 do
					id = id * 256 + p[at + 5 + (single and 0 or 1) + i]
				end

				if id ~= 0 then error("zstd: dictionaries are not supported") end
			end

			if fcs_flag == 0 then
				header = header + (single and 1 or 0)
			else
				header = header + ({2, 4, 8})[fcs_flag]
			end

			at = at + header
			ctx.huf_ready = false
			ctx.ll_table, ctx.ml_table, ctx.of_table = nil, nil, nil
			ctx.rep[0], ctx.rep[1], ctx.rep[2] = 1, 4, 8

			while true do
				if at + 3 > stop then error("zstd: truncated block header") end

				local h = p[at] + lshift(p[at + 1], 8) + lshift(p[at + 2], 16)
				at = at + 3
				local last = band(h, 1) ~= 0
				local kind = band(rshift(h, 1), 3)
				local size = rshift(h, 3)

				if kind == 0 then
					if at + size > stop or out + size > dst_capacity then
						error("zstd: raw block out of bounds")
					end

					ffi.copy(dst + out, p + at, size)
					at = at + size
					out = out + size
				elseif kind == 1 then
					if out + size > dst_capacity then error("zstd: rle block out of bounds") end

					ffi.fill(dst + out, size, p[at])
					at = at + 1
					out = out + size
				elseif kind == 2 then
					if at + size > stop or size > MAX_BLOCK then
						error("zstd: compressed block out of bounds")
					end

					out = decode_block(ctx, p, at, size, dst, out, dst_capacity)
					at = at + size
				else
					error("zstd: reserved block type")
				end

				if last then break end
			end

			if checksum then at = at + 4 end
		else
			error(string.format("zstd: bad frame magic 0x%08x", magic))
		end
	end

	return out
end

function zstd.DecompressString(str, size)
	size = size or zstd.GetContentSize(str, #str)

	if not size then
		error("zstd: frame has no content size, pass the decompressed size")
	end

	local dst = bytes_t(math.max(size, 1))
	local written = zstd.Decompress(str, #str, dst, size)
	return ffi.string(dst, written)
end

return zstd
