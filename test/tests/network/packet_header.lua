local T = import("test/environment.lua")
local packet_header = import("goluwa/network/packet_header.lua")
local TYPE_DATA = packet_header.TYPE_DATA
local FLAG_RELIABLE = packet_header.FLAG_RELIABLE

T.Test("Datagram prefix is recognized", function()
	T(#packet_header.Prefix)["=="](packet_header.PrefixSize)
	T(packet_header.IsDatagram(packet_header.Prefix))["=="](true)
	T(packet_header.IsDatagram("GL\1"))["=="](false)
	T(packet_header.IsDatagram("not a goluwa packet"))["=="](false)
	T(packet_header.IsDatagram(""))["=="](false)
end)

T.Test("Record roundtrip without fragment fields", function()
	local record = packet_header.EncodeRecord(TYPE_DATA, FLAG_RELIABLE, 3, 42, "hello")
	T(#record)["=="](packet_header.RecordHeaderSize + 5)
	local type_, flags, channel, id, fragment_id, total, start, stop = packet_header.DecodeRecord(record, 1)
	local payload = record:sub(start, stop)
	local next_pos = stop + 1
	T(type_)["=="](TYPE_DATA)
	T(flags)["=="](FLAG_RELIABLE)
	T(channel)["=="](3)
	T(id)["=="](42)
	T(fragment_id)["=="](1)
	T(total)["=="](1)
	T(payload)["=="]("hello")
	T(next_pos)["=="](#record + 1)
end)

T.Test("Record roundtrip with fragment fields", function()
	local record = packet_header.EncodeRecord(TYPE_DATA, FLAG_RELIABLE, 0, 65535, "part", 300, 65535)
	T(#record)["=="](packet_header.FragmentRecordHeaderSize + 4)
	local _, flags, _, id, fragment_id, total, start, stop = packet_header.DecodeRecord(record, 1)
	local payload = record:sub(start, stop)
	T(bit.band(flags, FLAG_RELIABLE))["=="](FLAG_RELIABLE)
	T(id)["=="](65535)
	T(fragment_id)["=="](300)
	T(total)["=="](65535)
	T(payload)["=="]("part")
end)

T.Test("Records decode in order from one datagram", function()
	local datagram = packet_header.Prefix .. packet_header.EncodeRecord(TYPE_DATA, 0, 1, 0, "a") .. packet_header.EncodeRecord(packet_header.TYPE_ACK, 0, 2, 0, "") .. packet_header.EncodeRecord(TYPE_DATA, 0, 3, 7, string.rep("z", 1000))
	local pos = packet_header.PrefixSize + 1
	local seen = {}

	while pos <= #datagram do
		local type_, _, channel, id, _, _, start, stop = packet_header.DecodeRecord(datagram, pos)
		seen[#seen + 1] = {type_, channel, id, stop - start + 1}
		pos = stop + 1
	end

	T(#seen)["=="](3)
	T(seen[1][2])["=="](1)
	T(seen[2][1])["=="](packet_header.TYPE_ACK)
	T(seen[2][4])["=="](0)
	T(seen[3][3])["=="](7)
	T(seen[3][4])["=="](1000)
end)

T.Test("Truncated records are rejected", function()
	local record = packet_header.EncodeRecord(TYPE_DATA, 0, 0, 0, "payload")
	T(packet_header.DecodeRecord(record:sub(1, 5), 1))["=="](nil)
	T(packet_header.DecodeRecord(record:sub(1, #record - 1), 1))["=="](nil)
	local fragment = packet_header.EncodeRecord(TYPE_DATA, FLAG_RELIABLE, 0, 0, "x", 1, 2)
	T(packet_header.DecodeRecord(fragment:sub(1, 9), 1))["=="](nil)
end)

return {}
