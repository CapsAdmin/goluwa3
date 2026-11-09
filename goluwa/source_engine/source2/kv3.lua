local ffi = require("ffi")
local lz4 = import("goluwa/codecs/lz4.lua")
local kv3 = {}
local MAGIC_BASE = 0x4B563300
local NULL, BOOLEAN, INT64, UINT64, DOUBLE, STRING, BINARY_BLOB, ARRAY, OBJECT, ARRAY_TYPED, INT32, UINT32, BOOLEAN_TRUE, BOOLEAN_FALSE, INT64_ZERO, INT64_ONE, DOUBLE_ZERO, DOUBLE_ONE, FLOAT, INT16, UINT16, INT8, UINT8, ARRAY_TYPE_BYTE_LENGTH, ARRAY_TYPE_AUXILIARY_BUFFER, UINT32_ZERO, UINT32_ONE = 1,
2,
3,
4,
5,
6,
7,
8,
9,
10,
11,
12,
13,
14,
15,
16,
17,
18,
19,
20,
21,
22,
23,
24,
25,
26,
27
local i8_t = ffi.typeof("const int8_t *")
local u8_t = ffi.typeof("const uint8_t *")
local i16_t = ffi.typeof("const int16_t *")
local u16_t = ffi.typeof("const uint16_t *")
local i32_t = ffi.typeof("const int32_t *")
local u32_t = ffi.typeof("const uint32_t *")
local f32_t = ffi.typeof("const float *")
local i64_t = ffi.typeof("const int64_t *")
local u64_t = ffi.typeof("const uint64_t *")
local f64_t = ffi.typeof("const double *")

local function align(offset, alignment)
	return math.ceil(offset / alignment) * alignment
end

function kv3.DecodeText(str)
	str = str:gsub("^%s*<!%-%-.-%-%->", "")
	local pos = 1

	local function skip()
		while true do
			pos = str:find("%S", pos) or #str + 1
			local two = str:sub(pos, pos + 1)

			if two == "//" then
				pos = (str:find("\n", pos, true) or #str) + 1
			elseif two == "/*" then
				pos = (select(2, str:find("*/", pos, true)) or #str) + 1
			else
				break
			end
		end
	end

	local read_value

	local function read_string()
		local quote = str:sub(pos, pos)

		if str:sub(pos, pos + 2) == "\"\"\"" then
			local e = str:find("\"\"\"", pos + 3, true)
			local v = str:sub(pos + 3, e - 1)
			pos = e + 3
			return v
		end

		local e = pos + 1

		while str:sub(e, e) ~= quote do
			if str:sub(e, e) == "\\" then e = e + 1 end

			e = e + 1
		end

		local v = str:sub(pos + 1, e - 1)
		pos = e + 1
		return v
	end

	local function read_key()
		skip()

		if str:sub(pos, pos) == "\"" then return read_string() end

		local key = str:match("^[%w_%.%$]+", pos)
		pos = pos + #key
		return key
	end

	function read_value()
		skip()
		local c = str:sub(pos, pos)

		if c == "{" then
			pos = pos + 1
			local out = {}

			while true do
				skip()

				if str:sub(pos, pos) == "}" then
					pos = pos + 1
					return out
				end

				local key = read_key()
				skip()
				pos = pos + 1
				out[key] = read_value()
				skip()

				if str:sub(pos, pos) == "," then pos = pos + 1 end
			end
		elseif c == "[" then
			pos = pos + 1
			local out = {}

			while true do
				skip()

				if str:sub(pos, pos) == "]" then
					pos = pos + 1
					return out
				end

				out[#out + 1] = read_value()
				skip()

				if str:sub(pos, pos) == "," then pos = pos + 1 end
			end
		elseif c == "\"" then
			return read_string()
		end

		local word = str:match("^[^%s,%]}%[{\"]+", pos)
		pos = pos + #word

		if str:sub(pos, pos) == "\"" then return read_string() end

		if word == "true" then return true end

		if word == "false" then return false end

		if word == "null" then return nil end

		return tonumber(word) or word
	end

	return read_value()
end

local function block_decompress(src, pos, size)
	local out = ffi.new("uint8_t[?]", size)
	local out_pos, mask, left = 0, 0, 0

	while out_pos < size do
		if left == 0 then
			mask = src[pos] + src[pos + 1] * 256
			pos = pos + 2
			left = 16
		end

		if bit.band(mask, 1) ~= 0 then
			local value = src[pos] + src[pos + 1] * 256
			pos = pos + 2
			local offset = bit.rshift(value, 4) + 1
			local length = bit.band(value, 15) + 3

			for j = 0, length - 1 do
				out[out_pos + j] = out[out_pos - offset + j]
			end

			out_pos = out_pos + length
		else
			out[out_pos] = src[pos]
			out_pos = out_pos + 1
			pos = pos + 1
		end

		mask = bit.rshift(mask, 1)
		left = left - 1
	end

	return out
end

local ENCODING_BLOCK_LZ4 = "\x8a\x34\x47\x68\xa1\x63\x5c\x4f\xa1\x97\x53\x80\x6f\xd9\xb1\x19"
local ENCODING_BLOCK_COMPRESSED = "\x46\x1a\x79\x95\xbc\x95\x6c\x4f\xa7\x0b\x05\xbc\xa1\xb7\xdf\xd2"

function kv3.DecodeLegacy(str, start)
	local src = ffi.cast(u8_t, str)
	local encoding = str:sub(start + 5, start + 20)
	local pos = start + 4 + 32
	local buffer

	if encoding == ENCODING_BLOCK_LZ4 then
		local size = ffi.cast(i32_t, src + pos)[0]
		buffer = lz4.DecodeBlock(src, pos + 4, #str, size)
	elseif encoding == ENCODING_BLOCK_COMPRESSED then
		local size = ffi.cast(u32_t, src + pos)[0]

		if size >= 0x80000000 then
			buffer = src + pos + 4
		else
			buffer = block_decompress(src, pos + 4, size)
		end
	else
		buffer = src + pos
	end

	local p = 0
	local strings = {}
	local string_count = ffi.cast(u32_t, buffer + p)[0]
	p = p + 4

	for i = 0, string_count - 1 do
		local e = p

		while buffer[e] ~= 0 do
			e = e + 1
		end

		strings[i] = ffi.string(buffer + p, e - p)
		p = e + 1
	end

	local read_value

	local function read_type()
		local b = buffer[p]
		p = p + 1

		if b >= 0x80 then p = p + 1 end

		return b % 128
	end

	local function read_node(is_array)
		local name

		if not is_array then
			name = strings[ffi.cast(i32_t, buffer + p)[0]] or ""
			p = p + 4
		end

		return name, read_value(read_type())
	end

	function read_value(t)
		if t == NULL then
			return nil
		elseif t == BOOLEAN then
			p = p + 1
			return buffer[p - 1] ~= 0
		elseif t == BOOLEAN_TRUE then
			return true
		elseif t == BOOLEAN_FALSE then
			return false
		elseif t == INT64_ZERO or t == DOUBLE_ZERO then
			return 0
		elseif t == INT64_ONE or t == DOUBLE_ONE then
			return 1
		elseif t == INT64 then
			p = p + 8
			return tonumber(ffi.cast(i64_t, buffer + p - 8)[0])
		elseif t == UINT64 then
			p = p + 8
			return tonumber(ffi.cast(u64_t, buffer + p - 8)[0])
		elseif t == INT32 then
			p = p + 4
			return ffi.cast(i32_t, buffer + p - 4)[0]
		elseif t == UINT32 then
			p = p + 4
			return ffi.cast(u32_t, buffer + p - 4)[0]
		elseif t == DOUBLE then
			p = p + 8
			return ffi.cast(f64_t, buffer + p - 8)[0]
		elseif t == STRING then
			p = p + 4
			return strings[ffi.cast(i32_t, buffer + p - 4)[0]] or ""
		elseif t == BINARY_BLOB then
			local len = ffi.cast(i32_t, buffer + p)[0]
			p = p + 4 + len
			return ffi.string(buffer + p - len, len)
		elseif t == ARRAY then
			local len = ffi.cast(i32_t, buffer + p)[0]
			p = p + 4
			local out = {}

			for i = 1, len do
				out[i] = select(2, read_node(true))
			end

			return out
		elseif t == ARRAY_TYPED then
			local len = ffi.cast(i32_t, buffer + p)[0]
			p = p + 4
			local sub = read_type()
			local out = {}

			for i = 1, len do
				out[i] = read_value(sub)
			end

			return out
		elseif t == OBJECT then
			local len = ffi.cast(i32_t, buffer + p)[0]
			p = p + 4
			local out = {}

			for _ = 1, len do
				local name, value = read_node(false)
				out[name] = value
			end

			return out
		end

		error("unknown legacy kv3 node type " .. tostring(t))
	end

	return read_value(read_type())
end

-- the flat tables returned by Decode are plain lua tables: objects have string keys, arrays are 1 based
function kv3.Decode(str, start, finish)
	start = start or 0

	if str:find("^%s*<!%-%-") then return kv3.DecodeText(str) end

	local src = ffi.cast(u8_t, str)
	local magic = ffi.cast(u32_t, src + start)[0]

	if magic == 0x03564B56 then return kv3.DecodeLegacy(str, start) end

	local version = magic % 256

	if magic - version ~= MAGIC_BASE then error("not a binary kv3 block", 2) end

	if version > 3 then error("unsupported kv3 version " .. version, 2) end

	local pos = start + 4 + 16
	local header = ffi.cast(u32_t, src + pos)
	local method = header[0]
	local count_bytes1, count_bytes4, count_bytes8, uncompressed_size, count_types
	local block_count = 0

	if version == 1 then
		count_bytes1, count_bytes4, count_bytes8, uncompressed_size = header[1], header[2], header[3], header[4]
		pos = pos + 20
	else
		count_bytes1, count_bytes4, count_bytes8, count_types = header[2], header[3], header[4], header[5]
		uncompressed_size = header[7]
		block_count = header[9]
		pos = pos + 44
	end

	local buffer

	if method == 0 then
		buffer = ffi.cast(u8_t, src + pos)
	elseif method == 1 then
		buffer = lz4.DecodeBlock(src, pos, start + #str - start, uncompressed_size)
	else
		error("unsupported kv3 compression method " .. method, 2)
	end

	local offset = 0
	local bytes1 = offset
	offset = offset + count_bytes1
	offset = align(offset, 4)
	local bytes4 = offset
	offset = offset + count_bytes4 * 4
	offset = align(offset, 8)
	local bytes8 = offset
	offset = offset + count_bytes8 * 8
	local string_count = ffi.cast(i32_t, buffer + bytes4)[0]
	bytes4 = bytes4 + 4
	local strings = {}
	local s = offset

	for i = 0, string_count - 1 do
		local e = s

		while buffer[e] ~= 0 do
			e = e + 1
		end

		strings[i] = ffi.string(buffer + s, e - s)
		s = e + 1
	end

	local types_pos = s

	if block_count > 0 then error("kv3 binary blobs are not supported") end

	local function read_type()
		local b = buffer[types_pos]
		types_pos = types_pos + 1

		if version >= 3 then
			if b >= 0x80 then types_pos = types_pos + 1 end

			if b % 128 >= 0x40 then types_pos = types_pos + 1 end

			return b % 64
		end

		if b >= 0x80 then types_pos = types_pos + 1 end

		return b % 128
	end

	local read_value

	local function read_node(parent, key_or_nil)
		local t = read_type()
		local name

		if key_or_nil == nil then
			name = strings[ffi.cast(i32_t, buffer + bytes4)[0]] or ""
			bytes4 = bytes4 + 4
		end

		return name, read_value(t)
	end

	function read_value(t)
		if t == NULL then
			return nil
		elseif t == BOOLEAN_TRUE then
			return true
		elseif t == BOOLEAN_FALSE then
			return false
		elseif t == INT64_ZERO or t == DOUBLE_ZERO or t == UINT32_ZERO then
			return 0
		elseif t == INT64_ONE or t == DOUBLE_ONE or t == UINT32_ONE then
			return 1
		elseif t == BOOLEAN then
			local v = buffer[bytes1] ~= 0
			bytes1 = bytes1 + 1
			return v
		elseif t == INT8 then
			local v = ffi.cast(i8_t, buffer + bytes1)[0]
			bytes1 = bytes1 + 1
			return v
		elseif t == UINT8 then
			local v = buffer[bytes1]
			bytes1 = bytes1 + 1
			return v
		elseif t == INT32 then
			local v = ffi.cast(i32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			return v
		elseif t == UINT32 then
			local v = ffi.cast(u32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			return v
		elseif t == FLOAT then
			local v = ffi.cast(f32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			return v
		elseif t == INT64 then
			local v = tonumber(ffi.cast(i64_t, buffer + bytes8)[0])
			bytes8 = bytes8 + 8
			return v
		elseif t == UINT64 then
			local v = tonumber(ffi.cast(u64_t, buffer + bytes8)[0])
			bytes8 = bytes8 + 8
			return v
		elseif t == DOUBLE then
			local v = ffi.cast(f64_t, buffer + bytes8)[0]
			bytes8 = bytes8 + 8
			return v
		elseif t == STRING then
			local v = strings[ffi.cast(i32_t, buffer + bytes4)[0]] or ""
			bytes4 = bytes4 + 4
			return v
		elseif t == BINARY_BLOB then
			local len = ffi.cast(i32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			local v = ffi.string(buffer + bytes1, len)
			bytes1 = bytes1 + len
			return v
		elseif t == ARRAY then
			local len = ffi.cast(i32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			local out = {}

			for i = 1, len do
				out[i] = select(2, read_node(out, 0))
			end

			return out
		elseif t == ARRAY_TYPED then
			local len = ffi.cast(i32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			local sub = read_type()
			local out = {}

			for i = 1, len do
				out[i] = read_value(sub)
			end

			return out
		elseif t == OBJECT then
			local len = ffi.cast(i32_t, buffer + bytes4)[0]
			bytes4 = bytes4 + 4
			local out = {}

			for _ = 1, len do
				local name, value = read_node(out)
				out[name] = value
			end

			return out
		elseif t == INT16 then
			local v = ffi.cast(i16_t, buffer + bytes1)[0]
			bytes1 = bytes1 + 2
			return v
		elseif t == UINT16 then
			local v = ffi.cast(u16_t, buffer + bytes1)[0]
			bytes1 = bytes1 + 2
			return v
		end

		error("unknown kv3 node type " .. tostring(t))
	end

	return read_value(read_type())
end

return kv3
