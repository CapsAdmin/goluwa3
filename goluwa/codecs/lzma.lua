local ffi = require("ffi")
local bit = require("bit")
local Buffer = import("goluwa/structs/buffer.lua")
local lzma = library()
local band, rshift, lshift = bit.band, bit.rshift, bit.lshift
local floor = math.floor
local XZ_MAGIC = "\xFD7zXZ\0"
local SOURCE_MAGIC = "LZMA"
local IS_MATCH = 0
local IS_REP = 192
local IS_REP_G0 = 204
local IS_REP_G1 = 216
local IS_REP_G2 = 228
local IS_REP0_LONG = 240
local POS_SLOT = 432
local POS_SPECIAL = 688
local ALIGN = 803
local LEN_CODER = 819
local REP_LEN_CODER = 1333
local LEN_CHOICE2 = 1
local LEN_LOW = 2
local LEN_MID = 130
local LEN_HIGH = 258
local LITERAL = 1847
local prob_array_t = ffi.typeof("uint16_t[?]")
local byte_array_t = ffi.typeof("uint8_t[?]")
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local rc_range, rc_code, rc_src, rc_pos, rc_end, probs

local function normalize()
	if rc_range < 0x1000000 then
		rc_range = rc_range * 256
		rc_code = rc_code * 256

		if rc_pos < rc_end then
			rc_code = rc_code + rc_src[rc_pos]
			rc_pos = rc_pos + 1
		end
	end
end

local function decode_bit(index)
	local prob = probs[index]
	local bound = rshift(rc_range, 11) * prob
	local bit_value

	if rc_code < bound then
		rc_range = bound
		probs[index] = prob + rshift(2048 - prob, 5)
		bit_value = 0
	else
		rc_range = rc_range - bound
		rc_code = rc_code - bound
		probs[index] = prob - rshift(prob, 5)
		bit_value = 1
	end

	normalize()
	return bit_value
end

local function decode_bit_tree(base, num_bits)
	local m = 1

	for _ = 1, num_bits do
		m = m * 2 + decode_bit(base + m)
	end

	return m - lshift(1, num_bits)
end

local function decode_bit_tree_reverse(base, num_bits)
	local m = 1
	local symbol = 0

	for i = 0, num_bits - 1 do
		local bit_value = decode_bit(base + m)
		m = m * 2 + bit_value
		symbol = symbol + bit_value * lshift(1, i)
	end

	return symbol
end

local function decode_direct_bits(num_bits)
	local result = 0

	for _ = 1, num_bits do
		rc_range = floor(rc_range / 2)
		local code = rc_code - rc_range
		local bit_value = 0

		if code >= 0 then
			rc_code = code
			bit_value = 1
		end

		normalize()
		result = result * 2 + bit_value
	end

	return result
end

local function decode_length(base, pos_state)
	if decode_bit(base) == 0 then
		return decode_bit_tree(base + LEN_LOW + pos_state * 8, 3)
	end

	if decode_bit(base + LEN_CHOICE2) == 0 then
		return 8 + decode_bit_tree(base + LEN_MID + pos_state * 8, 3)
	end

	return 16 + decode_bit_tree(base + LEN_HIGH, 8)
end

function lzma.DecodeRaw(src, src_len, props, out_size)
	if props >= 9 * 5 * 5 then error("invalid lzma properties byte", 2) end

	local lc = props % 9
	local lp = floor(props / 9) % 5
	local pb = floor(props / 45)
	local lp_mask = lshift(1, lp) - 1
	local pb_mask = lshift(1, pb) - 1
	local literal_probs = 0x300 * lshift(1, lc + lp)
	local prob_count = LITERAL + literal_probs
	probs = prob_array_t(prob_count)

	for i = 0, prob_count - 1 do
		probs[i] = 1024
	end

	rc_src = ffi.cast(uint8_ptr_t, src)
	rc_end = src_len

	if src_len < 5 or rc_src[0] ~= 0 then error("invalid lzma stream start", 2) end

	rc_range = 0xFFFFFFFF
	rc_code = rc_src[1] * 16777216 + rc_src[2] * 65536 + rc_src[3] * 256 + rc_src[4]
	rc_pos = 5
	local out = byte_array_t(out_size)
	local pos = 0
	local state = 0
	local rep0, rep1, rep2, rep3 = 0, 0, 0, 0

	while pos < out_size do
		local pos_state = band(pos, pb_mask)

		if decode_bit(IS_MATCH + state * 16 + pos_state) == 0 then
			local prev_byte = pos > 0 and out[pos - 1] or 0
			local base = LITERAL + 0x300 * (lshift(band(pos, lp_mask), lc) + rshift(prev_byte, 8 - lc))
			local symbol = 1

			if state >= 7 then
				local match_byte = out[pos - rep0 - 1]

				while symbol < 0x100 do
					local match_bit = band(rshift(match_byte, 7), 1)
					match_byte = lshift(match_byte, 1)
					local bit_value = decode_bit(base + (1 + match_bit) * 256 + symbol)
					symbol = symbol * 2 + bit_value

					if match_bit ~= bit_value then break end
				end
			end

			while symbol < 0x100 do
				symbol = symbol * 2 + decode_bit(base + symbol)
			end

			out[pos] = symbol - 0x100
			pos = pos + 1
			state = state < 4 and 0 or (state < 10 and state - 3 or state - 6)
		else
			local len

			if decode_bit(IS_REP + state) == 1 then
				if pos == 0 then error("corrupt lzma stream", 2) end

				local short_rep = false

				if decode_bit(IS_REP_G0 + state) == 0 then
					if decode_bit(IS_REP0_LONG + state * 16 + pos_state) == 0 then
						short_rep = true
					end
				else
					local dist

					if decode_bit(IS_REP_G1 + state) == 0 then
						dist = rep1
					else
						if decode_bit(IS_REP_G2 + state) == 0 then
							dist = rep2
						else
							dist = rep3
							rep3 = rep2
						end

						rep2 = rep1
					end

					rep1 = rep0
					rep0 = dist
				end

				if short_rep then
					state = state < 7 and 9 or 11
					len = 1
				else
					len = decode_length(REP_LEN_CODER, pos_state) + 2
					state = state < 7 and 8 or 11
				end
			else
				rep3 = rep2
				rep2 = rep1
				rep1 = rep0
				local length_symbol = decode_length(LEN_CODER, pos_state)
				len = length_symbol + 2
				state = state < 7 and 7 or 10
				local len_state = length_symbol < 4 and length_symbol or 3
				local slot = decode_bit_tree(POS_SLOT + len_state * 64, 6)

				if slot < 4 then
					rep0 = slot
				else
					local num_direct_bits = rshift(slot, 1) - 1
					local dist = (2 + band(slot, 1)) * lshift(1, num_direct_bits)

					if slot < 14 then
						dist = dist + decode_bit_tree_reverse(POS_SPECIAL + dist - slot, num_direct_bits)
					else
						dist = dist + decode_direct_bits(num_direct_bits - 4) * 16
						dist = dist + decode_bit_tree_reverse(ALIGN, 4)
					end

					rep0 = dist
				end

				if rep0 == 0xFFFFFFFF then break end
			end

			if rep0 >= pos then error("corrupt lzma stream (distance out of range)", 2) end

			if pos + len > out_size then
				error("corrupt lzma stream (match past the end of the output)", 2)
			end

			local from = pos - rep0 - 1

			for i = 0, len - 1 do
				out[pos + i] = out[from + i]
			end

			pos = pos + len
		end
	end

	probs = nil
	rc_src = nil
	return out
end

local function read_u32(str, offset)
	local a, b, c, d = str:byte(offset, offset + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

function lzma.DecodeToArray(str)
	if str:sub(1, 6) == XZ_MAGIC then
		error("the xz container is not supported, only lzma alone and Source lumps", 2)
	end

	if str:sub(1, 4) == SOURCE_MAGIC then
		local actual_size = read_u32(str, 5)
		local props = str:byte(13)
		local stream_start = 18
		return lzma.DecodeRaw(
			ffi.cast(uint8_ptr_t, str) + stream_start - 1,
			#str - stream_start + 1,
			props,
			actual_size
		),
		actual_size
	end

	local props = str:byte(1)
	local size_low = read_u32(str, 6)
	local size_high = read_u32(str, 10)

	if size_low == 0xFFFFFFFF and size_high == 0xFFFFFFFF then
		error("lzma streams with an unknown size are not supported", 2)
	end

	if size_high ~= 0 then error("lzma stream is too large", 2) end

	return lzma.DecodeRaw(ffi.cast(uint8_ptr_t, str) + 13, #str - 13, props, size_low),
	size_low
end

function lzma.DecodeBuffer(input_buffer)
	local str = input_buffer:GetString()
	local out, size = lzma.DecodeToArray(str)
	return Buffer.New(out, size)
end

function lzma.Decode(str)
	local out, size = lzma.DecodeToArray(str)
	return ffi.string(out, size)
end

lzma.thread_job = [[
	local input = ...
	local lzma = import("goluwa/codecs/lzma.lua")
	local out, size = lzma.DecodeToArray(input)
	return {size = size}, out
]]

function lzma.DecodeJob(str)
	return import("goluwa/thread_pool.lua").Run(lzma.thread_job, str)
end

return lzma
