local T = import("test/environment.lua")
local packet_header = import("goluwa/network/packet_header.lua")
local packet = import("goluwa/network/packet.lua")

T.Test("Header constants are defined", function()
	T(packet_header.Magic)["=="](0x474C)
	T(packet_header.Version)["=="](1)
	T(packet_header.HeaderSize)["=="](11)
	T(packet_header.MaxPayload)[">"](0)
	T(packet_header.TYPE_DATA)["=="](0)
	T(packet_header.TYPE_ACK)["=="](1)
	T(packet_header.TYPE_CONNECT)["=="](2)
	T(packet_header.TYPE_DISCONNECT)["=="](3)
	T(packet_header.TYPE_PING)["=="](4)
	T(packet_header.TYPE_PONG)["=="](5)
end)

T.Test("WriteHeader and ReadHeader roundtrip — data packet", function()
	local buf = packet.CreateBuffer()
	packet_header.WriteHeader(buf, packet_header.TYPE_DATA, 0, 42, 3, 1, 1)

	-- Reset and read back
	buf:SetPosition(1)
	local header = packet_header.ReadHeader(buf)

	T(header.version)["=="](1)
	T(header.type)["=="](packet_header.TYPE_DATA)
	T(header.flags)["=="](0)
	T(header.packet_id)["=="](42)
	T(header.channel)["=="](3)
	T(header.fragment_id)["=="](0)
	T(header.total_fragments)["=="](1)
end)

T.Test("WriteHeader and ReadHeader roundtrip — reliable sequenced", function()
	local buf = packet.CreateBuffer()
	local flags = bit.bor(packet_header.FLAG_RELIABLE, packet_header.FLAG_UNRELIABLE_SEQUENCED)
	packet_header.WriteHeader(buf, packet_header.TYPE_DATA, flags, 100, 0, 1, 1)

	buf:SetPosition(1)
	local header = packet_header.ReadHeader(buf)

	T(header.type)["=="](packet_header.TYPE_DATA)
	T(header.flags)["=="](flags)
	T(header.packet_id)["=="](100)
	T(header.channel)["=="](0)
end)

T.Test("ReadHeader rejects bad magic", function()
	local buf = packet.CreateBuffer()
	-- Write garbage magic
	buf:WriteByte(0xFF)
	buf:WriteByte(0xFF)
	buf:WriteByte(1) -- version
	buf:WriteByte(0) -- type
	buf:WriteByte(0) -- flags
	buf:WriteI16(0)  -- packet_id
	buf:WriteByte(0) -- channel
	buf:WriteI16(0)  -- fragment_id
	buf:WriteByte(1) -- total_fragments

	T(function()
		packet_header.ReadHeader(buf)
	end)["~="](nil) -- should error
end)

T.Test("Frame produces correct size for empty payload", function()
	local framed = packet_header.Frame({})
	T(#framed)["=="](packet_header.HeaderSize)
end)

T.Test("Frame produces correct size for small payload", function()
	local payload = {1, 2, 3, 4, 5}
	local framed = packet_header.Frame(payload)
	T(#framed)["=="](packet_header.HeaderSize + 5)
end)

T.Test("Unframe returns header and payload", function()
	local payload = {10, 20, 30}
	local framed = packet_header.Frame(payload)
	local header, received_payload = packet_header.Unframe(framed)

	T(header.type)["=="](packet_header.TYPE_DATA)
	T(header.flags)["=="](0)
	T(header.packet_id)["=="](0)
	T(received_payload[1])["=="](10)
	T(received_payload[2])["=="](20)
	T(received_payload[3])["=="](30)
end)

T.Test("Frame + Unframe roundtrip preserves arbitrary bytes", function()
	local payload = {}

	for i = 1, 256 do
		payload[i] = i % 256
	end

	local framed = packet_header.Frame(payload)
	local _, received = packet_header.Unframe(framed)

	T(#received)["=="](#payload)

	for i = 1, #payload do
		T(received[i])["=="](payload[i])
	end
end)

T.Test("Fragment splits large payload into correct number of fragments", function()
	local max_data = packet_header.MaxPayload - packet_header.HeaderSize
	-- Create payload that is exactly 2.5x the max fragment size
	local payload_size = max_data * 3
	local payload = {}

	for i = 1, payload_size do
		payload[i] = (i % 256)
	end

	local fragments = packet_header.Fragment(payload, 0)
	T(#fragments)["=="](3)

	-- Each fragment should fit within MaxPayload
	for _, frag_data in ipairs(fragments) do
		T(#frag_data)["<="](packet_header.MaxPayload)
	end
end)

T.Test("Fragment produces correct fragment IDs", function()
	local max_data = packet_header.MaxPayload - packet_header.HeaderSize
	local payload_size = max_data * 2 + 100 -- slightly more than 2 fragments
	local payload = {}

	for i = 1, payload_size do
		payload[i] = i % 256
	end

	local fragments = packet_header.Fragment(payload, 0)
	T(#fragments)["=="](3)

	-- Check fragment IDs in headers
	for i = 1, 3 do
		local buf = packet.CreateBuffer(fragments[i])
		local hdr = packet_header.ReadHeader(buf)
		T(hdr.fragment_id)["=="](i)
	end
end)

T.Test("Reassemble single fragment returns original payload", function()
	local payload = {42, 43, 44, 45, 46}
	local framed = packet_header.Frame(payload)
	local reassembled = packet_header.Reassemble({framed})

	T(#reassembled)["=="](#payload)

	for i = 1, #payload do
		T(reassembled[i])["=="](payload[i])
	end
end)

T.Test("Reassemble multiple fragments reconstructs original payload", function()
	local max_data = packet_header.MaxPayload - packet_header.HeaderSize
	local payload_size = max_data * 3 + 100 -- 4 fragments with partial last
	local payload = {}

	for i = 1, payload_size do
		payload[i] = (i * 7 + 13) % 256
	end

	local fragments = packet_header.Fragment(payload, 0)
	local reassembled = packet_header.Reassemble(fragments)

	T(#reassembled)["=="](#payload)

	for i = 1, #payload do
		T(reassembled[i])["=="](payload[i])
	end
end)

T.Test("Reassemble empty fragment list returns empty", function()
	local result = packet_header.Reassemble({})
	T(#result)["=="](0)
end)

T.Test("Fragment + Reassemble roundtrip with max-sized payload", function()
	local max_data = packet_header.MaxPayload - packet_header.HeaderSize
	local payload_size = packet_header.MaxPayload * 5 -- 5 full fragments
	local payload = {}

	for i = 1, payload_size do
		payload[i] = (i * 31 + 7) % 256
	end

	local fragments = packet_header.Fragment(payload, 2) -- channel 2
	local reassembled = packet_header.Reassemble(fragments)

	T(#reassembled)["=="](#payload)

	for i = 1, #payload do
		T(reassembled[i])["=="](payload[i])
	end
end)

T.Test("Header size is exactly 11 bytes", function()
	local framed = packet_header.Frame({})
	T(#framed)["=="](11)
end)

T.Test("Packet ID wraps correctly at boundary values", function()
	local buf = packet.CreateBuffer()
	packet_header.WriteHeader(buf, packet_header.TYPE_DATA, 0, 65535, 0, 1, 1)
	buf:SetPosition(1)
	local header = packet_header.ReadHeader(buf)
	T(header.packet_id)["=="](65535)

	local buf2 = packet.CreateBuffer()
	packet_header.WriteHeader(buf2, packet_header.TYPE_DATA, 0, 0, 0, 1, 1)
	buf2:SetPosition(1)
	local header2 = packet_header.ReadHeader(buf2)
	T(header2.packet_id)["=="](0)
end)

T.Test("All packet types serialize correctly", function()
	for type_ = 0, 5 do
		local buf = packet.CreateBuffer()
		packet_header.WriteHeader(buf, type_, 0, 1, 0, 1, 1)
		buf:SetPosition(1)
		local header = packet_header.ReadHeader(buf)
		T(header.type)["=="](type_)
	end
end)

T.Test("Flags bit combinations are preserved", function()
	local flag_values = {
		packet_header.FLAG_RELIABLE,
		packet_header.FLAG_UNRELIABLE_SEQUENCED,
		bit.bor(packet_header.FLAG_RELIABLE, packet_header.FLAG_UNRELIABLE_SEQUENCED),
	}

	for _, flags in ipairs(flag_values) do
		local buf = packet.CreateBuffer()
		packet_header.WriteHeader(buf, packet_header.TYPE_DATA, flags, 1, 0, 1, 1)
		buf:SetPosition(1)
		local header = packet_header.ReadHeader(buf)
		T(header.flags)["=="](flags)
	end
end)
