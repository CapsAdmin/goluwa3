local bit = require("bit")
local packet_header = {}
packet_header.Magic = 0x474C
packet_header.Version = 2
packet_header.TYPE_DATA = 0
packet_header.TYPE_ACK = 1
packet_header.TYPE_CONNECT = 2
packet_header.TYPE_DISCONNECT = 3
packet_header.TYPE_PING = 4
packet_header.TYPE_PONG = 5
packet_header.FLAG_UNRELIABLE = 0
packet_header.FLAG_RELIABLE = bit.lshift(1, 0)
packet_header.FLAG_UNRELIABLE_SEQUENCED = bit.lshift(1, 1)
packet_header.FLAG_FRAGMENT = bit.lshift(1, 2)
packet_header.PrefixSize = 3
packet_header.RecordHeaderSize = 7
packet_header.FragmentRecordHeaderSize = 11

do
	local string_char = string.char
	local string_byte = string.byte
	local band = bit.band
	local bor = bit.bor
	local rshift = bit.rshift
	local magic_hi = bit.rshift(packet_header.Magic, 8)
	local magic_lo = bit.band(packet_header.Magic, 0xFF)
	local version = packet_header.Version
	local FLAG_FRAGMENT = packet_header.FLAG_FRAGMENT
	packet_header.Prefix = string_char(magic_hi, magic_lo, version)

	function packet_header.IsDatagram(str)
		local a, b, v = string_byte(str, 1, 3)
		return a == magic_hi and b == magic_lo and v == version
	end

	function packet_header.EncodeRecord(type_, flags, channel, id, payload, fragment_id, total_fragments)
		local length = #payload

		if total_fragments then
			return string_char(
					type_,
					bor(flags, FLAG_FRAGMENT),
					channel,
					band(id, 0xFF),
					rshift(id, 8),
					band(length, 0xFF),
					rshift(length, 8),
					band(fragment_id, 0xFF),
					rshift(fragment_id, 8),
					band(total_fragments, 0xFF),
					rshift(total_fragments, 8)
				) .. payload
		end

		return string_char(
				type_,
				flags,
				channel,
				band(id, 0xFF),
				rshift(id, 8),
				band(length, 0xFF),
				rshift(length, 8)
			) .. payload
	end

	function packet_header.DecodeRecord(str, pos)
		local type_, flags, channel, id_lo, id_hi, length_lo, length_hi = string_byte(str, pos, pos + 6)

		if not length_hi then return nil end

		local start = pos + 7
		local fragment_id = 1
		local total_fragments = 1

		if band(flags, FLAG_FRAGMENT) ~= 0 then
			local fragment_lo, fragment_hi, total_lo, total_hi = string_byte(str, start, start + 3)

			if not total_hi then return nil end

			fragment_id = fragment_lo + fragment_hi * 256
			total_fragments = total_lo + total_hi * 256
			start = start + 4
		end

		local stop = start + length_lo + length_hi * 256 - 1

		if stop > #str then return nil end

		return type_,
		flags,
		channel,
		id_lo + id_hi * 256,
		fragment_id,
		total_fragments,
		start,
		stop
	end
end

return packet_header
