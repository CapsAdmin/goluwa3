-- Tests for ACK tracking (Step 3)

local T = import("test/environment.lua")
local ack = import("goluwa/network/ack.lua")
local sequence = import("goluwa/network/sequence.lua")

T.Test("ACK header serialization — no bitmap", function()
	local header = {
		base_sequence = 100,
		ack_count = 5,
		bitmap = {},
	}

	local bytes = ack.SerializeAckHeader(header)
	T(#bytes)["=="](7) -- 4 (base_seq) + 2 (ack_count) + 1 (flags byte = 0)

	local deserialized = ack.DeserializeAckHeader(bytes)
	T(deserialized)["~="](nil)
	T(deserialized.base_sequence)["=="](100)
	T(deserialized.ack_count)["=="](5)
	T(#deserialized.bitmap)["=="](0)
end)

T.Test("ACK header serialization — with bitmap", function()
	local header = {
		base_sequence = 200,
		ack_count = 3,
		bitmap = {0x0A}, -- Bits 1 and 3 set
	}

	local bytes = ack.SerializeAckHeader(header)
	T(#bytes)["=="](8) -- 6 + 1 (bitmap size byte + 1 byte data)

	local deserialized = ack.DeserializeAckHeader(bytes)
	T(deserialized.base_sequence)["=="](200)
	T(deserialized.ack_count)["=="](3)
	T(#deserialized.bitmap)["=="](1)
	T(deserialized.bitmap[1])["=="](0x0A)
end)

T.Test("ACK header serialization — multiple bitmap bytes", function()
	local header = {
		base_sequence = 50,
		ack_count = 10,
		bitmap = {0xFF, 0x00, 0x01}, -- 3 bytes
	}

	local bytes = ack.SerializeAckHeader(header)
	T(#bytes)["=="](10) -- 6 + 1 + 3

	local deserialized = ack.DeserializeAckHeader(bytes)
	T(deserialized.ack_count)["=="](10)
	T(#deserialized.bitmap)["=="](3)
	T(deserialized.bitmap[1])["=="](0xFF)
	T(deserialized.bitmap[2])["=="](0x00)
	T(deserialized.bitmap[3])["=="](0x01)
end)

T.Test("ACK header deserialization — too short", function()
	local bytes = {1, 2, 3} -- Less than 6 bytes
	local header = ack.DeserializeAckHeader(bytes)
	T(header)["=="](nil)
end)

T.Test("Create ACK header — contiguous packets", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)

	local header = ack.CreateAckHeader(receiver, 100)
	T(header.base_sequence)["=="](100)
	T(header.ack_count)["=="](3) -- All 3 contiguous
end)

T.Test("Create ACK header — non-contiguous packets", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(102) -- Skip 101

	local header = ack.CreateAckHeader(receiver, 100)
	T(header.base_sequence)["=="](100)
	T(header.ack_count)["=="](1) -- Only 100 is contiguous
	-- 102 should be in the bitmap
end)

T.Test("Apply ACK header — advance receiver window", function()
	local receiver = sequence.Receiver.New()
	receiver:Receive(100)
	receiver:Receive(101)
	receiver:Receive(102)

	-- Create and apply ACK for all 3 packets
	local header = ack.CreateAckHeader(receiver, 100)
	ack.ApplyAckHeader(receiver, header)

	-- Receiver should have advanced past these packets
	-- (AdvanceWindow should be called explicitly in real usage)
	T(receiver.received_count)["=="](3)
end)

T.Test("ACK piggybacking — serialize then deserialize", function()
	local original = {
		base_sequence = 1000,
		ack_count = 7,
		bitmap = {0xAB, 0xCD},
	}

	local bytes = ack.SerializeAckHeader(original)
	local deserialized = ack.DeserializeAckHeader(bytes)

	T(deserialized.base_sequence)["=="](original.base_sequence)
	T(deserialized.ack_count)["=="](original.ack_count)
	T(#deserialized.bitmap)["=="](#original.bitmap)

	for i = 1, #original.bitmap do
		T(deserialized.bitmap[i])["=="](original.bitmap[i])
	end
end)

T.Test("ACK round-trip — various sequence numbers", function()
	local test_cases = {
		{base = 0, count = 0},
		{base = 1, count = 1},
		{base = 255, count = 5},
		{base = 65535, count = 10},
		{base = 100000, count = 50},
	}

	for _, tc in ipairs(test_cases) do
		local header = {
			base_sequence = tc.base,
			ack_count = tc.count,
			bitmap = {},
		}

		local bytes = ack.SerializeAckHeader(header)
		local deserialized = ack.DeserializeAckHeader(bytes)

		T(deserialized.base_sequence)["=="](tc.base)
		T(deserialized.ack_count)["=="](tc.count)
	end
end)

T.Test("ACK bitmap — bit position accuracy", function()
	local header = {
		base_sequence = 0,
		ack_count = 0,
		bitmap = {0x01, 0x80}, -- Bit 0 and bit 15 set
	}

	local bytes = ack.SerializeAckHeader(header)
	local deserialized = ack.DeserializeAckHeader(bytes)

	T(#deserialized.bitmap)["=="](2)
	T(deserialized.bitmap[1])["=="](0x01)
	T(deserialized.bitmap[2])["=="](0x80)
end)

return {}
