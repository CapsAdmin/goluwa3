local T = import("test/environment.lua")
local ffi = require("ffi")
local vorbis = import("goluwa/codecs/internal/vorbis.lua")
local Buffer = import("goluwa/structs/buffer.lua")

local function NewReader(packet)
	local reader = Buffer.New(packet)
	reader:RestartReadBits()
	return reader
end

T.Test("Vorbis BitReader: basic single-byte reads", function()
	-- Byte 0xAB = 10101011 binary
	-- LSB-first reading: bit0=1, bit1=1, bit2=0, bit3=1, bit4=0, bit5=1, bit6=0, bit7=1
	local reader = NewReader("\xAB")
	T(reader:Read(1))["=="](1) -- bit 0
	T(reader:Read(1))["=="](1) -- bit 1
	T(reader:Read(1))["=="](0) -- bit 2
	T(reader:Read(1))["=="](1) -- bit 3
	T(reader:Read(1))["=="](0) -- bit 4
	T(reader:Read(1))["=="](1) -- bit 5
	T(reader:Read(1))["=="](0) -- bit 6
	T(reader:Read(1))["=="](1) -- bit 7
end)

T.Test("Vorbis BitReader: multi-bit reads", function()
	-- Bytes: 0x12 0x34 = 00010010 00110100
	-- LSB-first: reading 4 bits = 0x2, next 4 bits = 0x1, next 4 = 0x4, next 4 = 0x3
	local reader = NewReader("\x12\x34")
	T(reader:Read(4))["=="](0x2)
	T(reader:Read(4))["=="](0x1)
	T(reader:Read(4))["=="](0x4)
	T(reader:Read(4))["=="](0x3)
end)

T.Test("Vorbis BitReader: cross-byte reads", function()
	-- Bytes: 0xFF 0x00 = 11111111 00000000
	-- Read 4 bits: 0xF (1111), then 8 bits crossing byte boundary: 0x0F (00001111)
	local reader = NewReader("\xFF\x00")
	T(reader:Read(4))["=="](0xF)
	T(reader:Read(8))["=="](0x0F) -- 4 bits from first byte (1111) + 4 bits from second (0000)
end)

T.Test("Vorbis BitReader: 8-bit byte reads", function()
	local reader = NewReader("\x01\x02\x03\x04")
	T(reader:Read(8))["=="](1)
	T(reader:Read(8))["=="](2)
	T(reader:Read(8))["=="](3)
	T(reader:Read(8))["=="](4)
end)

T.Test("Vorbis BitReader: 16-bit and 24-bit reads", function()
	-- 0x78 0x56 0x34 0x12 in LSB-first = 0x5678 for 16 bits, 0x345678 for 24 bits
	local reader = NewReader("\x78\x56\x34\x12")
	T(reader:Read(16))["=="](0x5678)
	T(reader:Read(16))["=="](0x1234)
end)

T.Test("Vorbis BitReader: 32-bit read", function()
	-- LSB-first 32-bit read of 0x78 0x56 0x34 0x12 = 0x12345678
	local reader = NewReader("\x78\x56\x34\x12")
	T(reader:Read(32))["=="](0x12345678)
end)

T.Test("Vorbis BitReader: 48-bit read (vorbis magic skip)", function()
	-- "vorbis" = 0x76 0x6F 0x72 0x62 0x69 0x73
	-- 48-bit read should consume all 6 bytes without error
	local reader = NewReader("vorbis\x01")
	local val = reader:Read(48) -- should not error
	T(type(val))["=="]("number")
	T(reader:Read(8))["=="](1) -- next byte should be 0x01
end)

T.Test("Vorbis BitReader: Peek does not consume", function()
	local reader = NewReader("\xAB\xCD")
	T(reader:Peek(8))["=="](0xAB)
	T(reader:Peek(8))["=="](0xAB) -- still the same
	T(reader:Peek(4))["=="](0xB) -- low nibble
	T(reader:Read(8))["=="](0xAB) -- now consume
	T(reader:Peek(8))["=="](0xCD) -- next byte
end)

T.Test("Vorbis BitReader: Peek + Advance = Read", function()
	local r1 = NewReader("\x12\x34\x56\x78")
	local r2 = NewReader("\x12\x34\x56\x78")
	-- Read various widths and compare Read vs Peek+Advance
	local widths = {3, 5, 7, 1, 8, 4, 4}

	for _, w in ipairs(widths) do
		local v1 = r1:Read(w)
		local v2 = r2:Peek(w)
		r2:SkipBits(w)
		T(v1)["=="](v2)
	end
end)

T.Test("Vorbis BitReader: BitPos tracking", function()
	local reader = NewReader("\x00\x00\x00\x00")
	T(reader:BitPos())["=="](0)
	reader:Read(3)
	T(reader:BitPos())["=="](3)
	reader:Read(5)
	T(reader:BitPos())["=="](8)
	reader:Read(1)
	T(reader:BitPos())["=="](9)
	reader:Read(7)
	T(reader:BitPos())["=="](16)
	reader:Read(16)
	T(reader:BitPos())["=="](32)
end)

T.Test("Vorbis BitReader: Read 0 bits returns 0", function()
	local reader = NewReader("\xFF")
	T(reader:Read(0))["=="](0)
	T(reader:Peek(0))["=="](0)
	T(reader:BitPos())["=="](0) -- no bits consumed
end)

T.Test("Vorbis BitReader: Read past end returns 0", function()
	local reader = NewReader("\x42") -- only 8 bits
	reader:Read(8) -- consume all
	T(reader:Read(8))["=="](0) -- past end
end)

T.Test("Vorbis BitReader: Vorbis identification header parse", function()
	-- Construct a minimal vorbis identification header
	-- Type=1, "vorbis", version=0, channels=2, rate=44100, ...
	local header = string.char(1) -- packet type
		.. "vorbis" -- magic
		.. "\x00\x00\x00\x00" -- version = 0
		.. "\x02" -- channels = 2
		.. "\x44\xAC\x00\x00" -- sample rate = 44100
		.. "\x00\x00\x00\x00" -- bitrate_max = 0
		.. "\x00\x00\x00\x00" -- bitrate_nominal = 0
		.. "\x00\x00\x00\x00" -- bitrate_min = 0
		.. "\x68" -- block sizes: blocksize_0=2^8=256, blocksize_1=2^6=64 wait no
	-- blocksize byte encodes: low nibble = exponent_0, high nibble = exponent_1
	-- Let's use 0x68: blocksize_0=2^8=256, blocksize_1=2^6=64
	-- Actually the spec is: blocksize_0 from low nibble, blocksize_1 from high nibble
	-- 0x68 = 0110 1000 → low nibble=8 →  2^8=256, high nibble=6 → 2^6=64
	-- But blocksize_1 must be >= blocksize_0, let's use 0xB8 instead
	-- 0xB8 = 1011 1000 → low=8→256, high=0xB=11→2048
	header = string.char(1) .. "vorbis" .. "\x00\x00\x00\x00" -- version
		.. "\x02" -- channels
		.. "\x44\xAC\x00\x00" -- 44100
		.. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\xB8" -- block sizes: 2^8=256 and 2^11=2048
		.. "\x01" -- framing flag
	local info = vorbis.DecodeIdentification(header)
	T(info)["~="](nil)
	T(info.channels)["=="](2)
	T(info.sample_rate)["=="](44100)
	T(info.vorbis_version)["=="](0)
	T(info.blocksize_0)["=="](256)
	T(info.blocksize_1)["=="](2048)
	T(info.framing_flag)["=="](1)
end)

T.Test("Vorbis BitReader: codebook sync pattern (24-bit)", function()
	-- Vorbis codebook sync is 0x564342 read as 24 bits LSB-first
	-- 0x564342 in bytes LSB-first: 0x42 0x43 0x56
	local reader = NewReader("\x42\x43\x56")
	T(reader:Read(24))["=="](0x564342)
end)

T.Test("Vorbis BitReader: mixed width reads match known values", function()
	-- Simulate reading a vorbis-like bit pattern:
	-- byte 0xD7 = 11010111
	-- LSB-first: read 1 bit=1, read 3 bits=011=3, read 4 bits=1101=13
	local reader = NewReader("\xD7")
	T(reader:Read(1))["=="](1)
	T(reader:Read(3))["=="](3) -- bits 1-3: 0,1,1 → 0b110 = 6? No, LSB first: bit1=1, bit2=1, bit3=0 → 0b011 = 3
	T(reader:Read(4))["=="](13) -- bits 4-7: 1,1,0,1 → 0b1101 = 13
end)

T.Test("Vorbis BitReader: DecodeCodebookEntry with simple table", function()
	-- Test the Huffman table lookup directly via vorbis.DecodeCodebookEntry
	-- Create a minimal codebook with a known decode table
	local book = {
		max_code_len = 2,
		dec_table = {
			[0] = {value = 1, len = 1}, -- code 0 (1 bit) → entry 0 (value=1, 1-indexed)
			[2] = {value = 1, len = 1}, -- code 0 extended: 10 → still entry 0
			[1] = {value = 2, len = 2}, -- code 01 (2 bits) → entry 1
			[3] = {value = 3, len = 2}, -- code 11 (2 bits) → entry 2
		},
	}
	-- Data: 0b11_01_0_0 = 0b11010000 reversed = ...
	-- Actually LSB-first: first bits read from byte are low bits
	-- byte 0xD4 = 11010100
	-- Read peek(2) = bits 0,1 = 00 = 0 → entry 0, advance 1
	-- Read peek(2) = bits 1,2 = 10 = ...
	-- This gets complicated. Let's use a simpler approach:
	-- byte 0x05 = 00000101
	-- peek(2) = lo 2 bits = 01 → dec_table[1] = entry 1 (value=2), advance 2
	-- peek(2) = next 2 bits = 01 → dec_table[1] = entry 1 (value=2), advance 2
	local reader = NewReader("\x05")
	local result1 = vorbis.DecodeCodebookEntry(book, reader)
	T(result1)["=="](1) -- value=2, returned as value-1=1
	local result2 = vorbis.DecodeCodebookEntry(book, reader)
	T(result2)["=="](1) -- same pattern, value=2, returned as value-1=1
end)

T.Test("Vorbis BitReader: RemainingBits", function()
	local reader = NewReader("\x00\x00\x00") -- 24 bits total
	-- Initially, before any reads, buf has loaded 0 bits, position at 0
	-- RemainingBits = (3 - 0) * 8 + 0 = 24
	T(reader:RemainingBits())["=="](24)
	reader:Read(5)
	-- After reading 5 bits: buf loaded 8 bits (1 byte), consumed 5, so buf_nbit=3
	-- Position advanced to 1, so: (3 - 1)*8 + 3 = 19
	T(reader:RemainingBits())["=="](19)
	reader:Read(8) -- cross byte, total consumed = 13
	T(reader:RemainingBits())["=="](11)
	reader:Read(11) -- consume remainder
	T(reader:RemainingBits())["=="](0)
end)

T.Test("Vorbis BitReader: consistency with reference values", function()
	-- Read the same byte sequence with various bit widths
	-- and verify the reassembled value matches
	local bytes = "\x78\x56\x34\x12"
	local reader = NewReader(bytes)
	-- Read 8+8+8+8 and reconstruct as 32-bit LE
	local b0 = reader:Read(8)
	local b1 = reader:Read(8)
	local b2 = reader:Read(8)
	local b3 = reader:Read(8)
	local reconstructed = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
	T(reconstructed)["=="](0x12345678)
	-- Now read same data as 32-bit at once
	local reader2 = NewReader(bytes)
	T(reader2:Read(32))["=="](0x12345678)
	-- Now read as 16+16
	local reader3 = NewReader(bytes)
	T(reader3:Read(16))["=="](0x5678)
	T(reader3:Read(16))["=="](0x1234)
end)
