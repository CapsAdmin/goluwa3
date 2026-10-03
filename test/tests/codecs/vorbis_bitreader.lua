local T = import("test/environment.lua")
local ffi = require("ffi")
local bit = require("bit")
local debug = require("debug")
local vorbis = import("goluwa/codecs/internal/vorbis.lua")
local Buffer = import("goluwa/structs/buffer.lua")

local function NewReader(packet)
	local reader = Buffer.New(packet)
	reader:RestartReadBits()
	return reader
end

local function BuildBitstream(write)
	local bits = {}

	local function PushBits(value, width)
		for shift = 0, width - 1 do
			bits[#bits + 1] = bit.band(bit.rshift(value, shift), 1)
		end
	end

	write(PushBits)
	local bytes = {}
	local byte_count = math.ceil(#bits / 8)

	for byte_idx = 0, byte_count - 1 do
		local value = 0

		for bit_idx = 0, 7 do
			local idx = byte_idx * 8 + bit_idx + 1

			if bits[idx] then value = value + bit.lshift(bits[idx], bit_idx) end
		end

		bytes[#bytes + 1] = string.char(value)
	end

	return table.concat(bytes)
end

local function WithInstructionLimit(limit, fn)
	local hook, mask, count = debug.gethook()

	local function RestoreHook()
		debug.sethook(hook, mask, count)
	end

	debug.sethook(function()
		error("instruction limit exceeded", 2)
	end, "", limit)

	local ok, a, b = xpcall(fn, function(err)
		return err
	end)
	RestoreHook()
	return ok, a, b
end

T.Test("Vorbis BitReader: basic single-byte reads", function()
	local reader = NewReader("\xAB")
	T(reader:Read(1))["=="](1)
	T(reader:Read(1))["=="](1)
	T(reader:Read(1))["=="](0)
	T(reader:Read(1))["=="](1)
	T(reader:Read(1))["=="](0)
	T(reader:Read(1))["=="](1)
	T(reader:Read(1))["=="](0)
	T(reader:Read(1))["=="](1)
end)

T.Test("Vorbis BitReader: multi-bit reads", function()
	local reader = NewReader("\x12\x34")
	T(reader:Read(4))["=="](0x2)
	T(reader:Read(4))["=="](0x1)
	T(reader:Read(4))["=="](0x4)
	T(reader:Read(4))["=="](0x3)
end)

T.Test("Vorbis BitReader: cross-byte reads", function()
	local reader = NewReader("\xFF\x00")
	T(reader:Read(4))["=="](0xF)
	T(reader:Read(8))["=="](0x0F)
end)

T.Test("Vorbis BitReader: 8-bit byte reads", function()
	local reader = NewReader("\x01\x02\x03\x04")
	T(reader:Read(8))["=="](1)
	T(reader:Read(8))["=="](2)
	T(reader:Read(8))["=="](3)
	T(reader:Read(8))["=="](4)
end)

T.Test("Vorbis BitReader: 16-bit and 24-bit reads", function()
	local reader = NewReader("\x78\x56\x34\x12")
	T(reader:Read(16))["=="](0x5678)
	T(reader:Read(16))["=="](0x1234)
end)

T.Test("Vorbis BitReader: 32-bit read", function()
	local reader = NewReader("\x78\x56\x34\x12")
	T(reader:Read(32))["=="](0x12345678)
end)

T.Test("Vorbis BitReader: 48-bit read (vorbis magic skip)", function()
	local reader = NewReader("vorbis\x01")
	local val = reader:Read(48)
	T(type(val))["=="]("number")
	T(reader:Read(8))["=="](1)
end)

T.Test("Vorbis BitReader: Peek does not consume", function()
	local reader = NewReader("\xAB\xCD")
	T(reader:Peek(8))["=="](0xAB)
	T(reader:Peek(8))["=="](0xAB)
	T(reader:Peek(4))["=="](0xB)
	T(reader:Read(8))["=="](0xAB)
	T(reader:Peek(8))["=="](0xCD)
end)

T.Test("Vorbis BitReader: Peek + Advance = Read", function()
	local r1 = NewReader("\x12\x34\x56\x78")
	local r2 = NewReader("\x12\x34\x56\x78")
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
	T(reader:BitPos())["=="](0)
end)

T.Test("Vorbis BitReader: Read past end returns 0", function()
	local reader = NewReader("\x42")
	reader:Read(8)
	T(reader:Read(8))["=="](0)
end)

T.Test("Vorbis BitReader: Vorbis identification header parse", function()
	local header = string.char(1) .. "vorbis" .. "\x00\x00\x00\x00" .. "\x02" .. "\x44\xAC\x00\x00" .. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\x68"
	header = string.char(1) .. "vorbis" .. "\x00\x00\x00\x00" .. "\x02" .. "\x44\xAC\x00\x00" .. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\x00\x00\x00\x00" .. "\xB8" .. "\x01"
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
	local reader = NewReader("\x42\x43\x56")
	T(reader:Read(24))["=="](0x564342)
end)

T.Test("Vorbis BitReader: mixed width reads match known values", function()
	local reader = NewReader("\xD7")
	T(reader:Read(1))["=="](1)
	T(reader:Read(3))["=="](3)
	T(reader:Read(4))["=="](13)
end)

T.Test("Vorbis BitReader: DecodeCodebookEntry with simple table", function()
	local book = {
		max_code_len = 2,
		fast_len = 2,
		fast_mask = 3,
		dec_table_len = ffi.new("uint8_t[4]", {0, 2, 0, 0}),
		dec_table_val = ffi.new("uint32_t[4]", {0, 2, 0, 0}),
	}
	local reader = NewReader("\x05")
	local result1 = vorbis.DecodeCodebookEntry(book, reader)
	T(result1)["=="](1)
	local result2 = vorbis.DecodeCodebookEntry(book, reader)
	T(result2)["=="](1)
end)

T.Test("Vorbis BitReader: RemainingBits", function()
	local reader = NewReader("\x00\x00\x00")
	T(reader:RemainingBits())["=="](24)
	reader:Read(5)
	T(reader:RemainingBits())["=="](19)
	reader:Read(8)
	T(reader:RemainingBits())["=="](11)
	reader:Read(11)
	T(reader:RemainingBits())["=="](0)
end)

T.Test("Vorbis BitReader: consistency with reference values", function()
	local bytes = "\x78\x56\x34\x12"
	local reader = NewReader(bytes)
	local b0 = reader:Read(8)
	local b1 = reader:Read(8)
	local b2 = reader:Read(8)
	local b3 = reader:Read(8)
	local reconstructed = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
	T(reconstructed)["=="](0x12345678)
	local reader2 = NewReader(bytes)
	T(reader2:Read(32))["=="](0x12345678)
	local reader3 = NewReader(bytes)
	T(reader3:Read(16))["=="](0x5678)
	T(reader3:Read(16))["=="](0x1234)
end)

T.Test("Vorbis BitReader: ordered codebook last-entry run completes", function()
	local packet = BuildBitstream(function(PushBits)
		PushBits(5, 8)

		for i = 1, #"vorbis" do
			PushBits(("vorbis"):byte(i), 8)
		end

		PushBits(0, 8)
		PushBits(0x564342, 24)
		PushBits(1, 16)
		PushBits(2, 24)
		PushBits(1, 1)
		PushBits(0, 5)
		PushBits(1, 2)
		PushBits(1, 1)
		PushBits(0, 4)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 8)
		PushBits(0, 16)
		PushBits(0, 16)
		PushBits(0, 6)
		PushBits(0, 8)
		PushBits(0, 4)
		PushBits(0, 8)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 24)
		PushBits(0, 24)
		PushBits(0, 24)
		PushBits(0, 6)
		PushBits(0, 8)
		PushBits(0, 3)
		PushBits(0, 1)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 1)
		PushBits(0, 1)
		PushBits(0, 2)
		PushBits(0, 8)
		PushBits(0, 8)
		PushBits(0, 8)
		PushBits(0, 6)
		PushBits(0, 1)
		PushBits(0, 16)
		PushBits(0, 16)
		PushBits(0, 8)
		PushBits(1, 1)
	end)
	local ok, setup_or_err = WithInstructionLimit(100000, function()
		local setup, err = vorbis.DecodeSetup(packet, {channels = 1})
		assert(setup, err)
		return setup
	end)

	if not ok then error(setup_or_err, 0) end

	local setup = setup_or_err
	T(setup.codebooks[1].lengths[1])["=="](1)
	T(setup.codebooks[1].lengths[2])["=="](2)
end)

T.Test("Vorbis BitReader: ordered codebook zero-length runs are skipped", function()
	local packet = BuildBitstream(function(PushBits)
		PushBits(5, 8)

		for i = 1, #"vorbis" do
			PushBits(("vorbis"):byte(i), 8)
		end

		PushBits(0, 8)
		PushBits(0x564342, 24)
		PushBits(1, 16)
		PushBits(25, 24)
		PushBits(1, 1)
		PushBits(1, 5)
		PushBits(1, 5)
		PushBits(0, 5)
		PushBits(0, 5)
		PushBits(24, 5)
		PushBits(0, 4)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 8)
		PushBits(0, 16)
		PushBits(0, 16)
		PushBits(0, 6)
		PushBits(0, 8)
		PushBits(0, 4)
		PushBits(0, 8)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 24)
		PushBits(0, 24)
		PushBits(0, 24)
		PushBits(0, 6)
		PushBits(0, 8)
		PushBits(0, 3)
		PushBits(0, 1)
		PushBits(0, 6)
		PushBits(0, 16)
		PushBits(0, 1)
		PushBits(0, 1)
		PushBits(0, 2)
		PushBits(0, 8)
		PushBits(0, 8)
		PushBits(0, 8)
		PushBits(0, 6)
		PushBits(0, 1)
		PushBits(0, 16)
		PushBits(0, 16)
		PushBits(0, 8)
		PushBits(1, 1)
	end)
	local ok, setup_or_err = WithInstructionLimit(100000, function()
		local setup, err = vorbis.DecodeSetup(packet, {channels = 1})
		assert(setup, err)
		return setup
	end)

	if not ok then error(setup_or_err, 0) end

	local lengths = setup_or_err.codebooks[1].lengths
	T(lengths[1])["=="](2)

	for i = 2, 25 do
		T(lengths[i])["=="](5)
	end
end)
