local DEBUG = false
local debug_counter = 0
local M = {_TYPE = "module", _NAME = "compress.deflatelua", _VERSION = "0.3.20111128"}
local Buffer = require("helpers.buffer")
local ffi = require("ffi")
local assert = assert
local error = error
local ipairs = ipairs
local print = print
local require = require
local tostring = tostring
local type = type
local io = io
local math = math
local math_max = math.max
local string_char = string.char
local band = bit.band
local lshift = bit.lshift
local rshift = bit.rshift

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

local function make_outstate(outbuf)
	local outstate = {}
	outstate.outbuf = outbuf
	outstate.window = {}
	outstate.window_pos = 1
	return outstate
end

local function output(outstate, byte)
	local window_pos = outstate.window_pos
	outstate.outbuf:WriteByte(byte)
	outstate.window[window_pos] = byte
	outstate.window_pos = window_pos % 32768 + 1 -- 32K
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

local function msb(bits, nbits)
	local res = 0

	for i = 1, nbits do
		res = lshift(res, 1) + band(bits, 1)
		bits = rshift(bits, 1)
	end

	return res
end

local function huffman_table_read(look, minbits, buf)
	local code = 1 -- leading 1 marker
	local nbits = 0

	while 1 do
		if nbits == 0 then -- small optimization (optional)
			local bits = noeof(buf:ReadBits(minbits))
			code = 2 ^ minbits + msb(bits, minbits)
			nbits = nbits + minbits
		else
			local b = noeof(buf:ReadBits(1))
			nbits = nbits + 1
			code = code * 2 + b -- MSB first
		end

		--debug('code?', code, bits_tostring(code))
		local val = look[code]

		if val then --debug('FOUND', val)
		return val end
	end
end

local function HuffmanTable(init, ncodes)
	local t = {}

	if ncodes then
		-- Find max nbits to iterate over
		local maxnbits = 0

		for val = 0, ncodes - 1 do
			local nbits = init[val]

			if nbits and nbits > maxnbits then maxnbits = nbits end
		end

		-- Build table sorted by nbits first, then val (avoiding table.sort)
		for nbits = 0, maxnbits do
			for val = 0, ncodes - 1 do
				if init[val] == nbits and nbits ~= 0 then
					t[#t + 1] = {val = val, nbits = nbits}
				--debug('*',val,nbits)
				end
			end
		end
	else
		for i = 1, #init - 2, 2 do
			local firstval, nbits, nextval = init[i], init[i + 1], init[i + 2]

			--debug(val, nextval, nbits)
			if nbits ~= 0 then
				for val = firstval, nextval - 1 do
					t[#t + 1] = {val = val, nbits = nbits}
				end
			end
		end
	end

	-- assign codes
	local code = 1 -- leading 1 marker
	local nbits = 0

	for i, s in ipairs(t) do
		if s.nbits ~= nbits then
			code = code * 2 ^ (s.nbits - nbits)
			nbits = s.nbits
		end

		s.code = code
		--debug('huffman code:', i, s.nbits, s.val, code, bits_tostring(code))
		code = code + 1
	end

	local minbits = math.huge
	local look = {}

	for i, s in ipairs(t) do
		minbits = math.min(minbits, s.nbits)
		look[s.code] = s.val
	end

	-- Ensure minbits is valid
	if minbits == math.huge or minbits > 32 then minbits = 1 end

	--for _,o in ipairs(t) do
	-- debug(':', o.nbits, o.val)
	--end
	-- function t:lookup(bits) return look[bits] end
	-- Store look and minbits in the table itself for use by huffman_table_read
	t.look = look
	t.minbits = minbits
	return t
end

local function parse_zstring(buf)
	repeat
		local by = buf:ReadBits(8)

		if not by then runtime_error("invalid header") end	
	until by == 0
end

local function parse_gzip_header(buf)
	-- local FLG_FTEXT = 2^0
	local FLG_FHCRC = 2 ^ 1
	local FLG_FEXTRA = 2 ^ 2
	local FLG_FNAME = 2 ^ 3
	local FLG_FCOMMENT = 2 ^ 4
	local id1 = buf:ReadBits(8)
	local id2 = buf:ReadBits(8)

	if id1 ~= 31 or id2 ~= 139 then runtime_error("not in gzip format") end

	local cm = buf:ReadBits(8) -- compression method
	local flg = buf:ReadBits(8) -- FLaGs
	local mtime = buf:ReadBits(32) -- Modification TIME
	local xfl = buf:ReadBits(8) -- eXtra FLags
	local os = buf:ReadBits(8) -- Operating System
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
		local xlen = buf:ReadBits(16)
		local extra = 0

		for i = 1, xlen do
			extra = buf:ReadBits(8)
		end

		if not extra then runtime_error("invalid header") end
	end

	if hasbit(flg, FLG_FNAME) then parse_zstring(buf) end

	if hasbit(flg, FLG_FCOMMENT) then parse_zstring(buf) end

	if hasbit(flg, FLG_FHCRC) then
		local crc16 = buf:ReadBits(16)

		if not crc16 then runtime_error("invalid header") end

		-- IMPROVE: check CRC. where is an example .gz file that
		-- has this set?
		if DEBUG then debug("CRC16=", crc16) end
	end
end

local function parse_zlib_header(buf)
	local cm = buf:ReadBits(4) -- Compression Method
	local cinfo = buf:ReadBits(4) -- Compression info
	local fcheck = buf:ReadBits(5) -- FLaGs: FCHECK (check bits for CMF and FLG)
	local fdict = buf:ReadBits(1) -- FLaGs: FDICT (present dictionary)
	local flevel = buf:ReadBits(2) -- FLaGs: FLEVEL (compression level)
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
		local dictid_ = buf:ReadBits(32)
	end

	return window_size
end

local function decode_huffman_codes(buf, codelentable, ncodes)
	local init = {}
	local nbits
	local val = 0

	while val < ncodes do
		local codelen = huffman_table_read(codelentable.look, codelentable.minbits, buf)
		--FIX:check nil?
		local nrepeat

		if codelen <= 15 then
			nrepeat = 1
			nbits = codelen
		--debug('w', nbits)
		elseif codelen == 16 then
			nrepeat = 3 + noeof(buf:ReadBits(2))
		-- nbits unchanged
		elseif codelen == 17 then
			nrepeat = 3 + noeof(buf:ReadBits(3))
			nbits = 0
		elseif codelen == 18 then
			nrepeat = 11 + noeof(buf:ReadBits(7))
			nbits = 0
		else
			error("ASSERT")
		end

		for i = 1, nrepeat do
			init[val] = nbits
			val = val + 1
		end
	end

	return HuffmanTable(init, ncodes)
end

local function parse_huffmantables(buf)
	local hlit = buf:ReadBits(5) -- # of literal/length codes - 257
	local hdist = buf:ReadBits(5) -- # of distance codes - 1
	local hclen = noeof(buf:ReadBits(4)) -- # of code length codes - 4
	local ncodelen_codes = hclen + 4
	local codelen_init = {}
	local codelen_vals = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

	for i = 1, ncodelen_codes do
		local nbits = buf:ReadBits(3)
		local val = codelen_vals[i]
		codelen_init[val] = nbits
	end

	local codelentable = HuffmanTable(codelen_init, 19) -- max value in codelen_vals is 18
	local nlit_codes = hlit + 257
	local ndist_codes = hdist + 1
	local littable = decode_huffman_codes(buf, codelentable, nlit_codes)
	local disttable = decode_huffman_codes(buf, codelentable, ndist_codes)
	return littable, disttable
end

local tdecode_len_base
local tdecode_len_nextrabits
local tdecode_dist_base
local tdecode_dist_nextrabits

local function parse_compressed_item(buf, outstate, littable, disttable)
	local val = huffman_table_read(littable.look, littable.minbits, buf)

	--debug("parse_compressed_item: val=", val, val < 256 and string_char(val) or "")
	if val < 256 then -- literal
		output(outstate, val)
	elseif val == 256 then -- end of block
		return true
	else
		if not tdecode_len_base then
			local t = {[257] = 3}
			local skip = 1

			for i = 258, 285, 4 do
				for j = i, i + 3 do
					t[j] = t[j - 1] + skip
				end

				if i ~= 258 then skip = skip * 2 end
			end

			t[285] = 258
			tdecode_len_base = t
		--for i=257,285 do debug('T1',i,t[i]) end
		end

		if not tdecode_len_nextrabits then
			local t = {}

			for i = 257, 285 do
				local j = math_max(i - 261, 0)
				t[i] = rshift(j, 2)
			end

			t[285] = 0
			tdecode_len_nextrabits = t
		--for i=257,285 do debug('T2',i,t[i]) end
		end

		local len_base = tdecode_len_base[val]
		local nextrabits = tdecode_len_nextrabits[val]
		--debug("Reading", nextrabits, "extra bits for length")
		local extrabits = noeof(buf:ReadBits(nextrabits))
		local len = len_base + extrabits

		--debug("Length:", len, "base:", len_base, "extra:", extrabits)
		if not tdecode_dist_base then
			local t = {[0] = 1}
			local skip = 1

			for i = 1, 29, 2 do
				for j = i, i + 1 do
					t[j] = t[j - 1] + skip
				end

				if i ~= 1 then skip = skip * 2 end
			end

			tdecode_dist_base = t
		--for i=0,29 do debug('T3',i,t[i]) end
		end

		if not tdecode_dist_nextrabits then
			local t = {}

			for i = 0, 29 do
				local j = math_max(i - 2, 0)
				t[i] = rshift(j, 1)
			end

			tdecode_dist_nextrabits = t
		--for i=0,29 do debug('T4',i,t[i]) end
		end

		local dist_val = huffman_table_read(disttable.look, disttable.minbits, buf)
		local dist_base = tdecode_dist_base[dist_val]
		local dist_nextrabits = tdecode_dist_nextrabits[dist_val]
		local dist_extrabits = noeof(buf:ReadBits(dist_nextrabits))
		local dist = dist_base + dist_extrabits

		--debug("Distance:", dist, "window_pos:", outstate.window_pos, "len:", len)
		for i = 1, len do
			local pos = (outstate.window_pos - 1 - dist) % 32768 + 1 -- 32K
			--debug("Accessing window[" .. pos .. "]")
			output(outstate, assert(outstate.window[pos], "invalid distance at pos " .. pos))
		end
	end

	return false
end

local function parse_block(buf, outstate)
	local bfinal = buf:ReadBits(1)
	local btype = buf:ReadBits(2)
	local BTYPE_NO_COMPRESSION = 0
	local BTYPE_FIXED_HUFFMAN = 1
	local BTYPE_DYNAMIC_HUFFMAN = 2
	local BTYPE_RESERVED_ = 3

	if DEBUG then
		debug("bfinal=", bfinal)
		debug("btype=", btype)
	end

	if btype == BTYPE_NO_COMPRESSION then
		buf:ReadBits(buf:BitsLeftInByte())
		local len = buf:ReadBits(16)
		local nlen_ = noeof(buf:ReadBits(16))

		for i = 1, len do
			local by = noeof(buf:ReadBits(8))
			output(outstate, by)
		end
	elseif btype == BTYPE_FIXED_HUFFMAN or btype == BTYPE_DYNAMIC_HUFFMAN then
		local littable, disttable

		if btype == BTYPE_DYNAMIC_HUFFMAN then
			littable, disttable = parse_huffmantables(buf)
		else
			littable = HuffmanTable({0, 8, 144, 9, 256, 7, 280, 8, 288, nil})
			disttable = HuffmanTable({0, 5, 32, nil})
		end

		repeat
			local is_done = parse_compressed_item(buf, outstate, littable, disttable)		
		until is_done
	else
		runtime_error("unrecognized compression type")
	end

	return bfinal ~= 0
end

function M.inflate(t)
	local inbuf = get_input_buffer(t.input)
	local outbuf = get_output_buffer(t.output)
	local outstate = make_outstate(outbuf)

	repeat
		local is_final = parse_block(inbuf, outstate)

		if DEBUG then
			debug(
				"Block complete, output size:",
				outbuf:GetPosition(),
				"input pos:",
				inbuf:GetPosition()
			)
		end	
	until is_final

	if DEBUG then
		debug("Inflation complete, output size:", outbuf:GetPosition())
	end

	return outbuf
end

local inflate = M.inflate

function M.gunzip(t)
	local inbuf = get_input_buffer(t.input)
	local outbuf = get_output_buffer(t.output)
	local disable_crc = t.disable_crc

	if disable_crc == nil then disable_crc = false end

	parse_gzip_header(inbuf)
	local data_crc32 = 0

	if disable_crc then
		inflate({input = inbuf, output = outbuf})
	else
		-- For CRC calculation, we need to intercept bytes
		local crc_outbuf = get_output_buffer(nil)
		inflate({input = inbuf, output = crc_outbuf})
		-- Calculate CRC and copy to output
		crc_outbuf:SetPosition(0)

		while not crc_outbuf:TheEnd() do
			local byte = crc_outbuf:ReadByte()
			data_crc32 = crc32(byte, data_crc32)
			outbuf:WriteByte(byte)
		end
	end

	inbuf:ReadBits(inbuf:BitsLeftInByte())
	local expected_crc32 = inbuf:ReadBits(32)
	local isize = inbuf:ReadBits(32) -- ignored
	if DEBUG then
		debug("crc32=", expected_crc32)
		debug("isize=", isize)
	end

	if not disable_crc and data_crc32 then
		if data_crc32 ~= expected_crc32 then
			runtime_error("invalid compressed data--crc error")
		end
	end

	if not inbuf:TheEnd() then warn("trailing garbage ignored") end

	return outbuf
end

function M.adler32(byte, crc)
	local s1 = crc % 65536
	local s2 = (crc - s1) / 65536
	s1 = (s1 + byte) % 65521
	s2 = (s2 + s1) % 65521
	-- 65521 is the largest prime smaller than 2^16
	return s2 * 65536 + s1
end

function M.inflate_zlib(t)
	local inbuf = get_input_buffer(t.input)
	local outbuf = get_output_buffer(t.output)
	local disable_crc = t.disable_crc

	if disable_crc == nil then disable_crc = false end

	local window_size_ = parse_zlib_header(inbuf)
	local data_adler32 = 1

	if disable_crc then
		inflate({input = inbuf, output = outbuf})
	else
		-- For adler32 calculation, we need to intercept bytes
		local crc_outbuf = get_output_buffer(nil)
		inflate({input = inbuf, output = crc_outbuf})
		-- Calculate adler32 and copy to output
		crc_outbuf:SetPosition(0)

		while not crc_outbuf:TheEnd() do
			local byte = crc_outbuf:ReadByte()
			data_adler32 = M.adler32(byte, data_adler32)
			outbuf:WriteByte(byte)
		end
	end

	inbuf:ReadBits(inbuf:BitsLeftInByte())
	local b3 = inbuf:ReadBits(8)
	local b2 = inbuf:ReadBits(8)
	local b1 = inbuf:ReadBits(8)
	local b0 = inbuf:ReadBits(8)
	local expected_adler32 = ((b3 * 256 + b2) * 256 + b1) * 256 + b0

	if DEBUG then debug("alder32=", expected_adler32) end

	if not disable_crc then
		if data_adler32 ~= expected_adler32 then
			runtime_error("invalid compressed data--crc error")
		end
	end

	if not inbuf:TheEnd() then warn("trailing garbage ignored") end

	return outbuf
end

return M
