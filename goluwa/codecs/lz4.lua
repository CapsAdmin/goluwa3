local ffi = require("ffi")
local bit = require("bit")
local lz4 = {}
local band, rshift = bit.band, bit.rshift
local byte_array_t = ffi.typeof("uint8_t[?]")

-- src is a uint8_t pointer, src_pos and src_end are 0 based and src_end is exclusive
function lz4.DecodeBlock(src, src_pos, src_end, dst_size)
	local dst = byte_array_t(dst_size)
	local dst_pos = 0

	while src_pos < src_end do
		local token = src[src_pos]
		src_pos = src_pos + 1
		local literal_len = rshift(token, 4)

		if literal_len == 15 then
			local b

			repeat
				b = src[src_pos]
				src_pos = src_pos + 1
				literal_len = literal_len + b			
			until b ~= 255
		end

		if dst_pos + literal_len > dst_size or src_pos + literal_len > src_end then
			error("lz4: literal run out of bounds", 2)
		end

		ffi.copy(dst + dst_pos, src + src_pos, literal_len)
		dst_pos = dst_pos + literal_len
		src_pos = src_pos + literal_len

		if src_pos >= src_end then break end

		local offset = src[src_pos] + src[src_pos + 1] * 256
		src_pos = src_pos + 2
		local match_len = band(token, 15)

		if match_len == 15 then
			local b

			repeat
				b = src[src_pos]
				src_pos = src_pos + 1
				match_len = match_len + b			
			until b ~= 255
		end

		match_len = match_len + 4

		if offset == 0 or offset > dst_pos or dst_pos + match_len > dst_size then
			error("lz4: match out of bounds", 2)
		end

		local from = dst_pos - offset

		if offset >= match_len then
			ffi.copy(dst + dst_pos, dst + from, match_len)
		else
			for i = 0, match_len - 1 do
				dst[dst_pos + i] = dst[from + i]
			end
		end

		dst_pos = dst_pos + match_len
	end

	if dst_pos ~= dst_size then
		error("lz4: expected " .. dst_size .. " bytes, got " .. dst_pos, 2)
	end

	return dst
end

-- byte exact port of LZ4_compress_default (lz4.c, acceleration 1, 64 bit, little endian)
do
	local uint32_ptr_t = ffi.typeof("const uint32_t *")
	local uint64_ptr_t = ffi.typeof("const uint64_t *")
	local hash_table_t = ffi.typeof("uint32_t[?]")
	local PRIME5 = 889523592379ULL
	local PRIME4 = 2654435761ULL
	local MASK32 = 0xFFFFFFFFULL
	local MFLIMIT = 12
	local LASTLITERALS = 5
	local MINMATCH = 4
	local DISTANCE_MAX = 65535
	local SMALL_LIMIT = 65536 + MFLIMIT - 1

	function lz4.EncodeBlock(src, size)
		local small = size < SMALL_LIMIT
		local table = hash_table_t(small and 8192 or 4096)
		local dst = byte_array_t(size + math.floor(size / 255) + 16)
		local op = 0
		local anchor = 0
		local mflimit_plus_one = size - MFLIMIT + 1
		local match_limit = size - LASTLITERALS

		local function hash(p)
			if small then
				return tonumber(bit.rshift(bit.band(ffi.cast(uint32_ptr_t, src + p)[0] * PRIME4, MASK32), 19))
			end

			return tonumber(bit.rshift(bit.lshift(ffi.cast(uint64_ptr_t, src + p)[0], 24) * PRIME5, 52))
		end

		local function read32(p)
			return ffi.cast(uint32_ptr_t, src + p)[0]
		end

		local function in_range(match, current)
			return small or match + DISTANCE_MAX >= current
		end

		local function write_length(length)
			while length >= 255 do
				dst[op] = 255
				op = op + 1
				length = length - 255
			end

			dst[op] = length
			op = op + 1
		end

		if size >= 13 then
			table[hash(0)] = 0
			local ip = 1
			local forward_hash = hash(ip)

			while true do
				local forward_ip = ip
				local step = 1
				local search_count = 64
				local match

				while true do
					local h = forward_hash
					local current = forward_ip
					match = table[h]
					ip = forward_ip
					forward_ip = forward_ip + step
					step = bit.rshift(search_count, 6)
					search_count = search_count + 1

					if forward_ip > mflimit_plus_one then goto last_literals end

					forward_hash = hash(forward_ip)
					table[h] = current

					if in_range(match, current) and read32(match) == read32(ip) then break end
				end

				while ip > anchor and match > 0 and src[ip - 1] == src[match - 1] do
					ip = ip - 1
					match = match - 1
				end

				local token = op
				op = op + 1
				local literal_length = ip - anchor

				if literal_length >= 15 then
					dst[token] = 0xF0
					write_length(literal_length - 15)
				else
					dst[token] = literal_length * 16
				end

				ffi.copy(dst + op, src + anchor, literal_length)
				op = op + literal_length

				while true do
					dst[op] = band(ip - match, 0xFF)
					dst[op + 1] = rshift(ip - match, 8)
					op = op + 2
					local match_code = 0
					local a, b = ip + MINMATCH, match + MINMATCH

					while a < match_limit and src[a] == src[b] do
						a = a + 1
						b = b + 1
						match_code = match_code + 1
					end

					ip = ip + match_code + MINMATCH

					if match_code >= 15 then
						dst[token] = dst[token] + 15
						write_length(match_code - 15)
					else
						dst[token] = dst[token] + match_code
					end

					anchor = ip

					if ip >= mflimit_plus_one then goto last_literals end

					table[hash(ip - 2)] = ip - 2
					local h = hash(ip)
					match = table[h]
					table[h] = ip

					if not (in_range(match, ip) and read32(match) == read32(ip)) then break end

					token = op
					dst[token] = 0
					op = op + 1
				end

				ip = ip + 1
				forward_hash = hash(ip)
			end
		end

		::last_literals::

		local last_run = size - anchor

		if last_run >= 15 then
			dst[op] = 0xF0
			op = op + 1
			write_length(last_run - 15)
		else
			dst[op] = last_run * 16
			op = op + 1
		end

		ffi.copy(dst + op, src + anchor, last_run)
		return dst, op + last_run
	end
end

return lz4
