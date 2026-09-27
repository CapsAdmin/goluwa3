local DEBUG = false
local debug_counter = 0
local deflate = library()
local Buffer = import("goluwa/structs/buffer.lua")
local ffi = require("ffi")
local assert = assert
local error = error
local ipairs = ipairs
local pcall = pcall
local print = print
local require = require
local tostring = tostring
local type = type
local io = io
local math = math
local math_max = math.max
local math_floor = math.floor
local string_char = string.char
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local pow2 = {}

for i = 0, 32 do
	pow2[i] = 2 ^ i
end

local function warn(s)
	io.stderr:write(s, "\n")
end

local function debug(...)
	print("DEBUG", ...)
end

local function runtime_error(s, level)
	level = level or 1
	error(s, level + 1)
end

-- The output buffer only ever grows and preserves its prior contents on
-- realloc (Buffer:SetPosition/WriteByte both memcpy old data into any new
-- allocation), so it doubles as its own up-to-32768-byte sliding window -
-- LZ77 back-references can read straight out of it instead of maintaining
-- a separate window copy of every byte written.
local function make_outstate(outbuf)
	local outstate = {}
	outstate.outbuf = outbuf
	outstate.outptr = outbuf.Buffer
	outstate.outpos = 0
	return outstate
end

local function ensure_out_capacity(outstate, needed)
	local outbuf = outstate.outbuf

	if needed > outbuf.ByteSize then
		outbuf:SetPosition(needed)
		outstate.outptr = outbuf.Buffer
	end
end

local function output(outstate, byte)
	local outpos = outstate.outpos

	if outpos >= outstate.outbuf.ByteSize then
		ensure_out_capacity(outstate, outpos + 1)
	end

	outstate.outptr[outpos] = byte
	outstate.outpos = outpos + 1
end

local function noeof(val, context)
	if val == nil then
		runtime_error("unexpected end of file" .. (context and (" at " .. context) or ""))
	end

	return val
end

local function hasbit(bits, bit)
	return bits % (bit + bit) >= bit
end

-- DEBUG
-- prints LSB first
--[[
local function bits_tostring(bits, nbits)
local s = ''
local tmp = bits
local function f()
local b = tmp % 2 == 1 and 1 or 0
s = s .. b
tmp = (tmp - b) / 2
end
if nbits then
for i=1,nbits do f() end
else
while tmp ~= 0 do f() end
end

return s
end
--]]
-- Convert input to Buffer if needed
local function get_input_buffer(input)
	local input_type = type(input)

	if input_type == "string" then
		local size = #input
		local data = ffi.new("uint8_t[?]", size)
		ffi.copy(data, input, size)
		local buf = Buffer.New(data, size)
		buf:RestartReadBits()
		return buf
	elseif input_type == "table" and input.ReadBits then
		-- Already a Buffer - don't restart bits, it may be partially read
		return input
	elseif input_type == "cdata" then
		-- Might be a Buffer ctype, check if it has ReadBits
		if input.ReadBits then
			-- Already a Buffer - don't restart bits, it may be partially read
			return input
		end
	end

	runtime_error("input must be string or Buffer, got: " .. tostring(input_type))
end

-- Create or get output Buffer
local function get_output_buffer(output, initial_size)
	-- PNG files can be large, start with a bigger buffer
	initial_size = initial_size or 262144 -- 256KB instead of 32KB
	local output_type = type(output)

	if output == nil then
		-- Create new writable buffer
		local data = ffi.new("uint8_t[?]", initial_size)
		return Buffer.New(data, initial_size):MakeWritable()
	elseif output_type == "table" and output.WriteByte then
		-- Already a Buffer (table)
		return output
	elseif output_type == "cdata" then
		-- Might be a Buffer ctype, check if it has WriteByte
		if output.WriteByte then return output end
	end

	runtime_error("output must be Buffer or nil, got: " .. tostring(output_type))
end

local function get_input_state(input)
	if type(input) == "table" and input.ptr and input.size and input.pos then
		return input
	end

	local buf = get_input_buffer(input)
	local bit_pos = buf.BitPos and buf:BitPos() or buf.Position * 8
	local pos = math_floor(bit_pos / 8)
	local bit_offset = bit_pos % 8
	local state = {
		buffer = buf,
		ptr = buf.Buffer,
		size = buf.ByteSize,
		pos = pos,
		bitbuf = 0,
		bitcount = 0,
	}

	if bit_offset > 0 and pos < state.size then
		state.bitbuf = math_floor(state.ptr[pos] / pow2[bit_offset])
		state.bitcount = 8 - bit_offset
		state.pos = pos + 1
	end

	return state
end

-- bitbuf holds up to 32 bits as an int32 bit pattern, LSB first; only bit ops touch it
local function fill_bits(state, nbits)
	local bitbuf = state.bitbuf
	local bitcount = state.bitcount
	local pos = state.pos
	local ptr = state.ptr
	local size = state.size

	while bitcount < nbits do
		if pos >= size then
			state.bitbuf = bitbuf
			state.bitcount = bitcount
			state.pos = pos
			return false
		end

		bitbuf = bor(bitbuf, lshift(ptr[pos], bitcount))
		pos = pos + 1
		bitcount = bitcount + 8
	end

	state.bitbuf = bitbuf
	state.bitcount = bitcount
	state.pos = pos
	return true
end

local function read_bits(state, nbits)
	if nbits == 0 then return 0 end

	if nbits > 16 then
		local lo = read_bits(state, 16)
		local hi = read_bits(state, nbits - 16)

		if not lo or not hi then return nil end

		return lo + hi * 65536
	end

	if not fill_bits(state, nbits) then return nil end

	local out = band(state.bitbuf, lshift(1, nbits) - 1)
	state.bitbuf = rshift(state.bitbuf, nbits)
	state.bitcount = state.bitcount - nbits
	return out
end

local function align_to_byte(state)
	local discard = state.bitcount % 8
	state.bitbuf = rshift(state.bitbuf, discard)
	state.bitcount = state.bitcount - discard
end

local function input_the_end(state)
	return state.pos >= state.size and state.bitcount == 0
end

-- codes up to FASTBITS long decode with one lookup of the next FASTBITS bits,
-- the entry packs the symbol and its length as symbol * 32 + length (0 = longer code)
local FASTBITS = 10
local FAST_SIZE = 1024
local FAST_MASK = FAST_SIZE - 1
local uint16_array = ffi.typeof("uint16_t[?]")
local int32_array = ffi.typeof("int32_t[?]")

-- canonical huffman table from the code length of each symbol, lengths is 0 indexed
local function HuffmanTable(lengths, ncodes)
	local counts = int32_array(16)

	for sym = 0, ncodes - 1 do
		local len = lengths[sym] or 0
		counts[len] = counts[len] + 1
	end

	counts[0] = 0
	local offsets = int32_array(16)

	for len = 2, 15 do
		offsets[len] = offsets[len - 1] + counts[len - 1]
	end

	local symbols = int32_array(ncodes)

	for sym = 0, ncodes - 1 do
		local len = lengths[sym] or 0

		if len ~= 0 then
			symbols[offsets[len]] = sym
			offsets[len] = offsets[len] + 1
		end
	end

	local fast = uint16_array(FAST_SIZE)
	local code = 0
	local index = 0

	for len = 1, FASTBITS do
		for i = 0, counts[len] - 1 do
			-- codes are stored MSB first, the bit buffer is LSB first
			local reversed = 0
			local c = code

			for _ = 1, len do
				reversed = bor(lshift(reversed, 1), band(c, 1))
				c = rshift(c, 1)
			end

			local packed = symbols[index + i] * 32 + len

			for j = reversed, FAST_SIZE - 1, lshift(1, len) do
				fast[j] = packed
			end

			code = code + 1
		end

		index = index + counts[len]
		code = lshift(code, 1)
	end

	return {fast = fast, counts = counts, symbols = symbols}
end

-- one bit at a time through the code length counts, for codes longer than FASTBITS
local function decode_slow(state, t)
	local counts = t.counts
	local code = 0
	local first = 0
	local index = 0

	for len = 1, 15 do
		code = bor(code, noeof(read_bits(state, 1)))
		local count = counts[len]

		if code - first < count then return t.symbols[index + code - first] end

		index = index + count
		first = lshift(first + count, 1)
		code = lshift(code, 1)
	end

	runtime_error("invalid huffman code")
end

local function decode_symbol(state, t)
	fill_bits(state, FASTBITS)
	local packed = t.fast[band(state.bitbuf, FAST_MASK)]
	local nbits = band(packed, 31)

	if nbits ~= 0 and nbits <= state.bitcount then
		state.bitbuf = rshift(state.bitbuf, nbits)
		state.bitcount = state.bitcount - nbits
		return rshift(packed, 5)
	end

	return decode_slow(state, t)
end

local function parse_zstring(buf)
	repeat
		local by = read_bits(buf, 8)

		if not by then runtime_error("invalid header") end	
	until by == 0
end

local function parse_gzip_header(buf)
	-- local FLG_FTEXT = 2^0
	local FLG_FHCRC = 2 ^ 1
	local FLG_FEXTRA = 2 ^ 2
	local FLG_FNAME = 2 ^ 3
	local FLG_FCOMMENT = 2 ^ 4
	local id1 = read_bits(buf, 8)
	local id2 = read_bits(buf, 8)

	if id1 ~= 31 or id2 ~= 139 then runtime_error("not in gzip format") end

	local cm = read_bits(buf, 8) -- compression method
	local flg = read_bits(buf, 8) -- FLaGs
	local mtime = read_bits(buf, 32) -- Modification TIME
	local xfl = read_bits(buf, 8) -- eXtra FLags
	local os = read_bits(buf, 8) -- Operating System
	if DEBUG then
		debug("CM=", cm)
		debug("FLG=", flg)
		debug("MTIME=", mtime)
		-- debug("MTIME_str=",os.date("%Y-%m-%d %H:%M:%S",mtime)) -- non-portable
		debug("XFL=", xfl)
		debug("OS=", os)
	end

	if not os then runtime_error("invalid header") end

	if hasbit(flg, FLG_FEXTRA) then
		local xlen = read_bits(buf, 16)
		local extra = 0

		for i = 1, xlen do
			extra = read_bits(buf, 8)
		end

		if not extra then runtime_error("invalid header") end
	end

	if hasbit(flg, FLG_FNAME) then parse_zstring(buf) end

	if hasbit(flg, FLG_FCOMMENT) then parse_zstring(buf) end

	if hasbit(flg, FLG_FHCRC) then
		local crc16 = read_bits(buf, 16)

		if not crc16 then runtime_error("invalid header") end

		-- IMPROVE: check CRC. where is an example .gz file that
		-- has this set?
		if DEBUG then debug("CRC16=", crc16) end
	end
end

local function parse_zlib_header(buf)
	local cm = read_bits(buf, 4) -- Compression Method
	local cinfo = read_bits(buf, 4) -- Compression info
	local fcheck = read_bits(buf, 5) -- FLaGs: FCHECK (check bits for CMF and FLG)
	local fdict = read_bits(buf, 1) -- FLaGs: FDICT (present dictionary)
	local flevel = read_bits(buf, 2) -- FLaGs: FLEVEL (compression level)
	local cmf = cinfo * 16 + cm -- CMF (Compresion Method and flags)
	local flg = fcheck + fdict * 32 + flevel * 64 -- FLaGs
	if cm ~= 8 then -- not "deflate"
		runtime_error("unrecognized zlib compression method: " .. cm)
	end

	if cinfo > 7 then
		runtime_error("invalid zlib window size: cinfo=" .. cinfo)
	end

	local window_size = 2 ^ (cinfo + 8)

	if (cmf * 256 + flg) % 31 ~= 0 then
		runtime_error("invalid zlib header (bad fcheck sum)")
	end

	if fdict == 1 then
		runtime_error("FIX:TODO - FDICT not currently implemented")
		local dictid_ = read_bits(buf, 32)
	end

	return window_size
end

-- literal/length and distance code lengths form one sequence, and a repeat
-- code may run across the boundary between them (RFC 1951 3.2.7)
local function decode_huffman_codes(buf, codelentable, nlit_codes, ndist_codes)
	local init = {}
	local nbits
	local val = 0
	local ncodes = nlit_codes + ndist_codes

	while val < ncodes do
		local codelen = decode_symbol(buf, codelentable)
		local nrepeat

		if codelen <= 15 then
			nrepeat = 1
			nbits = codelen
		elseif codelen == 16 then
			nrepeat = 3 + noeof(read_bits(buf, 2))
		elseif codelen == 17 then
			nrepeat = 3 + noeof(read_bits(buf, 3))
			nbits = 0
		else
			nrepeat = 11 + noeof(read_bits(buf, 7))
			nbits = 0
		end

		for i = 1, nrepeat do
			init[val] = nbits
			val = val + 1
		end
	end

	local dist_init = {}

	for i = 0, ndist_codes - 1 do
		dist_init[i] = init[nlit_codes + i]
	end

	return HuffmanTable(init, nlit_codes), HuffmanTable(dist_init, ndist_codes)
end

local function parse_huffmantables(buf)
	local hlit = noeof(read_bits(buf, 5)) -- # of literal/length codes - 257
	local hdist = noeof(read_bits(buf, 5)) -- # of distance codes - 1
	local hclen = noeof(read_bits(buf, 4)) -- # of code length codes - 4
	local codelen_init = {}
	local codelen_vals = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

	for i = 1, hclen + 4 do
		codelen_init[codelen_vals[i]] = noeof(read_bits(buf, 3))
	end

	return decode_huffman_codes(buf, HuffmanTable(codelen_init, 19), hlit + 257, hdist + 1)
end

local LEN_BASE = ffi.new(
	"int32_t[29]",
	{
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		13,
		15,
		17,
		19,
		23,
		27,
		31,
		35,
		43,
		51,
		59,
		67,
		83,
		99,
		115,
		131,
		163,
		195,
		227,
		258,
	}
)
local LEN_EXTRA = ffi.new(
	"int32_t[29]",
	{
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		1,
		1,
		1,
		1,
		2,
		2,
		2,
		2,
		3,
		3,
		3,
		3,
		4,
		4,
		4,
		4,
		5,
		5,
		5,
		5,
		0,
	}
)
local DIST_BASE = ffi.new(
	"int32_t[30]",
	{
		1,
		2,
		3,
		4,
		5,
		7,
		9,
		13,
		17,
		25,
		33,
		49,
		65,
		97,
		129,
		193,
		257,
		385,
		513,
		769,
		1025,
		1537,
		2049,
		3073,
		4097,
		6145,
		8193,
		12289,
		16385,
		24577,
	}
)
local DIST_EXTRA = ffi.new(
	"int32_t[30]",
	{
		0,
		0,
		0,
		0,
		1,
		1,
		2,
		2,
		3,
		3,
		4,
		4,
		5,
		5,
		6,
		6,
		7,
		7,
		8,
		8,
		9,
		9,
		10,
		10,
		11,
		11,
		12,
		12,
		13,
		13,
	}
)
-- Below this length, ffi.copy's call overhead outweighs what it saves over a plain loop
local COPY_FFI_THRESHOLD = 32

-- the whole block runs on locals, the state tables are only synced around the rare slow paths
local function inflate_huffman_block(state, outstate, lit, dist)
	local ptr = state.ptr
	local size = state.size
	local pos = state.pos
	local bitbuf = state.bitbuf
	local bitcount = state.bitcount
	local outbuf = outstate.outbuf
	local outptr = outstate.outptr
	local outpos = outstate.outpos
	local outcap = outbuf.ByteSize
	local lit_fast = lit.fast
	local dist_fast = dist.fast

	while true do
		while bitcount <= 24 and pos < size do
			bitbuf = bor(bitbuf, lshift(ptr[pos], bitcount))
			pos = pos + 1
			bitcount = bitcount + 8
		end

		local packed = lit_fast[band(bitbuf, FAST_MASK)]
		local nbits = band(packed, 31)
		local sym

		if nbits ~= 0 and nbits <= bitcount then
			bitbuf = rshift(bitbuf, nbits)
			bitcount = bitcount - nbits
			sym = rshift(packed, 5)
		else
			state.pos = pos
			state.bitbuf = bitbuf
			state.bitcount = bitcount
			sym = decode_slow(state, lit)
			pos = state.pos
			bitbuf = state.bitbuf
			bitcount = state.bitcount
		end

		if sym < 256 then
			if outpos >= outcap then
				ensure_out_capacity(outstate, outpos + 1)
				outptr = outstate.outptr
				outcap = outbuf.ByteSize
			end

			outptr[outpos] = sym
			outpos = outpos + 1
		elseif sym == 256 then
			break
		else
			sym = sym - 257

			if sym >= 29 then runtime_error("invalid length code: " .. (sym + 257)) end

			while bitcount <= 24 and pos < size do
				bitbuf = bor(bitbuf, lshift(ptr[pos], bitcount))
				pos = pos + 1
				bitcount = bitcount + 8
			end

			local extra = LEN_EXTRA[sym]

			if bitcount < extra then runtime_error("unexpected end of file") end

			local len = LEN_BASE[sym] + band(bitbuf, lshift(1, extra) - 1)
			bitbuf = rshift(bitbuf, extra)
			bitcount = bitcount - extra

			while bitcount <= 24 and pos < size do
				bitbuf = bor(bitbuf, lshift(ptr[pos], bitcount))
				pos = pos + 1
				bitcount = bitcount + 8
			end

			packed = dist_fast[band(bitbuf, FAST_MASK)]
			nbits = band(packed, 31)

			if nbits ~= 0 and nbits <= bitcount then
				bitbuf = rshift(bitbuf, nbits)
				bitcount = bitcount - nbits
				sym = rshift(packed, 5)
			else
				state.pos = pos
				state.bitbuf = bitbuf
				state.bitcount = bitcount
				sym = decode_slow(state, dist)
				pos = state.pos
				bitbuf = state.bitbuf
				bitcount = state.bitcount
			end

			if sym >= 30 then runtime_error("invalid distance code: " .. sym) end

			while bitcount <= 24 and pos < size do
				bitbuf = bor(bitbuf, lshift(ptr[pos], bitcount))
				pos = pos + 1
				bitcount = bitcount + 8
			end

			extra = DIST_EXTRA[sym]

			if bitcount < extra then runtime_error("unexpected end of file") end

			local distance = DIST_BASE[sym] + band(bitbuf, lshift(1, extra) - 1)
			bitbuf = rshift(bitbuf, extra)
			bitcount = bitcount - extra

			if distance > outpos then runtime_error("invalid distance: " .. distance) end

			if outpos + len > outcap then
				ensure_out_capacity(outstate, outpos + len)
				outptr = outstate.outptr
				outcap = outbuf.ByteSize
			end

			local src = outpos - distance

			if distance >= len and len >= COPY_FFI_THRESHOLD then
				ffi.copy(outptr + outpos, outptr + src, len)
			else
				-- overlapping copies repeat bytes written earlier in this same copy
				for i = 0, len - 1 do
					outptr[outpos + i] = outptr[src + i]
				end
			end

			outpos = outpos + len
		end
	end

	state.pos = pos
	state.bitbuf = bitbuf
	state.bitcount = bitcount
	outstate.outpos = outpos
end

local fixed_littable
local fixed_disttable

do
	local lengths = {}

	for sym = 0, 287 do
		lengths[sym] = sym < 144 and 8 or sym < 256 and 9 or sym < 280 and 7 or 8
	end

	fixed_littable = HuffmanTable(lengths, 288)
	lengths = {}

	for sym = 0, 29 do
		lengths[sym] = 5
	end

	fixed_disttable = HuffmanTable(lengths, 30)
end

local function parse_block(buf, outstate)
	local bfinal = noeof(read_bits(buf, 1))
	local btype = noeof(read_bits(buf, 2))

	if btype == 0 then
		align_to_byte(buf)
		local len = noeof(read_bits(buf, 16))
		noeof(read_bits(buf, 16)) -- one's complement of len
		for i = 1, len do
			output(outstate, noeof(read_bits(buf, 8)))
		end
	elseif btype == 1 then
		inflate_huffman_block(buf, outstate, fixed_littable, fixed_disttable)
	elseif btype == 2 then
		inflate_huffman_block(buf, outstate, parse_huffmantables(buf))
	else
		runtime_error("unrecognized compression type")
	end

	return bfinal ~= 0
end

function deflate.inflate(t)
	local inbuf = get_input_state(t.input)
	local outbuf = get_output_buffer(t.output)
	local outstate = make_outstate(outbuf)

	repeat
		local is_final = parse_block(inbuf, outstate)

		if DEBUG then
			debug(
				"Block complete, output size:",
				outstate.outpos,
				"input pos:",
				inbuf.pos
			)
		end	
	until is_final

	if DEBUG then debug("Inflation complete, output size:", outstate.outpos) end

	outbuf.Position = outstate.outpos
	outbuf:SetPosition(0)
	return outbuf
end

local inflate = deflate.inflate

function deflate.gunzip(t)
	local inbuf = get_input_state(t.input)
	local outbuf = get_output_buffer(t.output)
	local disable_crc = t.disable_crc

	if disable_crc == nil then disable_crc = false end

	parse_gzip_header(inbuf)
	local data_crc32 = 0

	if disable_crc then
		inflate{input = inbuf, output = outbuf}
	else
		-- For CRC calculation, we need to intercept bytes
		local crc_outbuf = get_output_buffer(nil)
		inflate{input = inbuf, output = crc_outbuf}
		-- Calculate CRC and copy to output
		crc_outbuf:SetPosition(0)

		while not crc_outbuf:TheEnd() do
			local byte = crc_outbuf:ReadByte()
			data_crc32 = crc32(byte, data_crc32)
			outbuf:WriteByte(byte)
		end
	end

	align_to_byte(inbuf)
	local expected_crc32 = read_bits(inbuf, 32)
	local isize = read_bits(inbuf, 32) -- ignored
	if DEBUG then
		debug("crc32=", expected_crc32)
		debug("isize=", isize)
	end

	if not disable_crc and data_crc32 then
		if data_crc32 ~= expected_crc32 then
			runtime_error("invalid compressed data--crc error")
		end
	end

	if not input_the_end(inbuf) then warn("trailing garbage ignored") end

	outbuf:SetPosition(0)
	return outbuf
end

function deflate.adler32(byte, crc)
	local s1 = crc % 65536
	local s2 = (crc - s1) / 65536
	s1 = (s1 + byte) % 65521
	s2 = (s2 + s1) % 65521
	-- 65521 is the largest prime smaller than 2^16
	return s2 * 65536 + s1
end

function deflate.inflate_zlib(t)
	local inbuf = get_input_state(t.input)
	local outbuf = get_output_buffer(t.output)
	local disable_crc = t.disable_crc

	if disable_crc == nil then disable_crc = false end

	local window_size_ = parse_zlib_header(inbuf)
	local data_adler32 = 1

	if disable_crc then
		inflate{input = inbuf, output = outbuf}
	else
		-- For adler32 calculation, we need to intercept bytes
		local crc_outbuf = get_output_buffer(nil)
		inflate{input = inbuf, output = crc_outbuf}
		-- Calculate adler32 and copy to output
		crc_outbuf:SetPosition(0)

		while not crc_outbuf:TheEnd() do
			local byte = crc_outbuf:ReadByte()
			data_adler32 = deflate.adler32(byte, data_adler32)
			outbuf:WriteByte(byte)
		end
	end

	align_to_byte(inbuf)
	local b3 = read_bits(inbuf, 8)
	local b2 = read_bits(inbuf, 8)
	local b1 = read_bits(inbuf, 8)
	local b0 = read_bits(inbuf, 8)
	local expected_adler32 = ((b3 * 256 + b2) * 256 + b1) * 256 + b0

	if DEBUG then debug("alder32=", expected_adler32) end

	if not disable_crc then
		if data_adler32 ~= expected_adler32 then
			runtime_error("invalid compressed data--crc error")
		end
	end

	if not input_the_end(inbuf) then warn("trailing garbage ignored") end

	outbuf:SetPosition(0)
	return outbuf
end

local function looks_like_gzip(input)
	return #input >= 2 and input:byte(1) == 0x1f and input:byte(2) == 0x8b
end

local function looks_like_zlib(input)
	if #input < 2 then return false end

	local cmf = input:byte(1)
	local flg = input:byte(2)
	local cm = cmf % 16
	local cinfo = math.floor(cmf / 16)

	if cm ~= 8 then return false end

	if cinfo > 7 then return false end

	return (cmf * 256 + flg) % 31 == 0
end

function deflate.Decode(str, format, output)
	local opts = {
		input = Buffer.New(str),
		output = output or Buffer.New(),
		disable_crc = true,
	}

	if format == "gzip" then
		return deflate.gunzip(opts)
	elseif format == "zlib" then
		return deflate.inflate_zlib(opts)
	elseif format == "raw" then
		return deflate.inflate(opts)
	elseif format ~= nil and format ~= "auto" then
		runtime_error("unknown deflate container format: " .. tostring(format))
	end

	if looks_like_gzip(str) then return deflate.gunzip(opts) end

	if looks_like_zlib(str) then
		local ok, result = pcall(deflate.inflate_zlib, opts)

		if ok then return result end
	end

	return deflate.inflate(opts)
end

return deflate
