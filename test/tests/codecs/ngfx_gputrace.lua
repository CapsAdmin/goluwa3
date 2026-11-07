local T = import("test/environment.lua")
local ffi = require("ffi")
local lz4 = import("goluwa/codecs/lz4.lua")
local protobuf = import("goluwa/codecs/protobuf.lua")
local crypto = import("goluwa/crypto.lua")
local uint8_ptr_t = ffi.typeof("const uint8_t *")

T.Test("lz4 decodes literals and overlapping matches", function()
	local src = "\x32abc\x03\x00"
	local out = lz4.DecodeBlock(ffi.cast(uint8_ptr_t, src), 0, #src, 9)
	T(ffi.string(out, 9))["=="]("abcabcabc")
	T(pcall(lz4.DecodeBlock, ffi.cast(uint8_ptr_t, src), 0, #src, 10))["=="](false)
	local bad_offset = "\x32abc\x09\x00"
	T(pcall(lz4.DecodeBlock, ffi.cast(uint8_ptr_t, bad_offset), 0, #bad_offset, 9))["=="](false)
end)

T.Test("lz4 encodes byte for byte like LZ4_compress_default", function()
	local function make(n, f)
		local t = {}

		for i = 0, n - 1 do
			t[i + 1] = string.char(f(i))
		end

		return table.concat(t)
	end

	-- expected sizes and crc32 come from liblz4 1.10 LZ4_compress_default
	local vectors = {
		{
			data = make(5000, function(i)
				return (i * i * 31 + math.floor(i / 7)) % 13 + 97
			end),
			size = 121,
			crc = 2439793446,
		},
		{
			data = make(200000, function(i)
				return (i * 2654435761 % 4294967296) % 7 + (math.floor(i / 1000) % 3) * 40
			end),
			size = 22250,
			crc = 2547350566,
		},
	}

	for _, vector in ipairs(vectors) do
		local out, size = lz4.EncodeBlock(ffi.cast(uint8_ptr_t, vector.data), #vector.data)
		T(size)["=="](vector.size)
		T(tonumber(crypto.CRC32(ffi.string(out, size))))["=="](vector.crc)
		T(ffi.string(lz4.DecodeBlock(out, 0, size, #vector.data), #vector.data) == vector.data)["=="](true)
	end

	local out, size = lz4.EncodeBlock(ffi.cast(uint8_ptr_t, "abc"), 3)
	T(ffi.string(out, size))["=="]("\x30abc")
end)

T.Test("protobuf decodes varints, strings and nested messages", function()
	local src = "\x08\x96\x01\x12\x05hello\x1a\x04\x08\xff\xff\x03\x20\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
	local ptr = ffi.cast(uint8_ptr_t, src)
	local fields = protobuf.Decode(ptr, 0, #src)
	T(protobuf.Find(fields, 1)[3])["=="](150)
	T(protobuf.String(ptr, protobuf.Find(fields, 2)))["=="]("hello")
	local nested = protobuf.Find(fields, 3)
	T(protobuf.Decode(ptr, nested[3], nested[4])[1][3])["=="](65535)
	T(tostring(protobuf.Find(fields, 4)[3]))["=="]("18446744073709551615ULL")
end)
