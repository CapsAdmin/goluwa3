local bit = require("bit")
local packet_header = {}
packet_header.Magic = 0x474C
packet_header.Version = 1
packet_header.TYPE_DATA = 0
packet_header.TYPE_ACK = 1
packet_header.TYPE_CONNECT = 2
packet_header.TYPE_DISCONNECT = 3
packet_header.TYPE_PING = 4
packet_header.TYPE_PONG = 5
packet_header.FLAG_UNRELIABLE = 0
packet_header.FLAG_RELIABLE = bit.lshift(1, 0)
packet_header.FLAG_UNRELIABLE_SEQUENCED = bit.lshift(1, 1)
packet_header.FLAG_HAS_SEQUENCE = bit.lshift(1, 2)
packet_header.FLAG_HAS_FRAGMENT = bit.lshift(1, 3)
packet_header.HeaderSize = 11
packet_header.MaxPayload = 4096

function packet_header.WriteHeader(buf, type_, flags, packet_id, channel, fragment_id, total_fragments)
	buf:WriteByte(bit.rshift(packet_header.Magic, 8))
	buf:WriteByte(bit.band(packet_header.Magic, 0xFF))
	buf:WriteByte(packet_header.Version)
	buf:WriteByte(type_)
	buf:WriteByte(flags)
	buf:WriteU16(packet_id)
	buf:WriteByte(channel or 0)

	if total_fragments and total_fragments > 1 then
		buf:WriteU16(fragment_id or 0)
		buf:WriteByte(total_fragments)
	else
		buf:WriteU16(0)
		buf:WriteByte(1)
	end

	return buf
end

function packet_header.ReadHeader(buf)
	local magic = bit.lshift(buf:ReadByte(), 8) + buf:ReadByte()

	if magic ~= packet_header.Magic then
		error("packet_header: bad magic 0x" .. string.format("%04X", magic))
	end

	local version = buf:ReadByte()
	local type_ = buf:ReadByte()
	local flags = buf:ReadByte()
	local packet_id = buf:ReadU16()
	local channel = buf:ReadByte()
	local fragment_id = buf:ReadU16()
	local total_fragments = buf:ReadByte()
	return {
		version = version,
		type = type_,
		flags = flags,
		packet_id = packet_id,
		channel = channel,
		fragment_id = fragment_id,
		total_fragments = total_fragments,
	}
end

function packet_header.Frame(payload_bytes, channel, fragment_id, total_fragments)
	local buf = import("goluwa/network/packet.lua").CreateBuffer()
	packet_header.WriteHeader(
		buf,
		packet_header.TYPE_DATA,
		0,
		0,
		channel or 0,
		fragment_id or 1,
		total_fragments or 1
	)

	for _, b in ipairs(payload_bytes) do
		buf:WriteByte(b)
	end

	return buf:GetString()
end

function packet_header.FrameString(data, channel, fragment_id, total_fragments)
	local buf = import("goluwa/network/packet.lua").CreateBuffer()
	packet_header.WriteHeader(
		buf,
		packet_header.TYPE_DATA,
		0,
		0,
		channel or 0,
		fragment_id or 1,
		total_fragments or 1
	)

	for i = 1, #data do
		buf:WriteByte(data:byte(i))
	end

	return buf:GetString()
end

function packet_header.Unframe(data)
	local buf = import("goluwa/network/packet.lua").CreateBuffer(data)
	local header = packet_header.ReadHeader(buf)
	local payload = {}

	while not buf:TheEnd() do
		payload[#payload + 1] = buf:ReadByte()
	end

	return header, payload
end

function packet_header.Fragment(payload_bytes, channel)
	local max_data = packet_header.MaxPayload - packet_header.HeaderSize
	local total = #payload_bytes
	local num_fragments = math.ceil(total / max_data)
	local fragments = {}

	for i = 0, num_fragments - 1 do
		local start = i * max_data + 1
		local len = math.min(max_data, total - start + 1)
		local fragment_bytes = {}

		for j = start, start + len - 1 do
			fragment_bytes[#fragment_bytes + 1] = payload_bytes[j]
		end

		fragments[i + 1] = packet_header.Frame(fragment_bytes, channel, i + 1, num_fragments)
	end

	return fragments
end

function packet_header.Reassemble(fragments)
	if #fragments == 0 then return {} end

	local first_buf = import("goluwa/network/packet.lua").CreateBuffer(fragments[1])
	local first_header = packet_header.ReadHeader(first_buf)
	local total = first_header.total_fragments

	if total <= 1 then
		local payload = {}

		while not first_buf:TheEnd() do
			payload[#payload + 1] = first_buf:ReadByte()
		end

		return payload
	end

	local all_payloads = {}

	for _, frag_data in ipairs(fragments) do
		local fbuf = import("goluwa/network/packet.lua").CreateBuffer(frag_data)
		packet_header.ReadHeader(fbuf)

		while not fbuf:TheEnd() do
			all_payloads[#all_payloads + 1] = fbuf:ReadByte()
		end
	end

	return all_payloads
end

do
	local string_char = string.char
	local string_byte = string.byte
	local string_sub = string.sub
	local magic_hi = bit.rshift(packet_header.Magic, 8)
	local magic_lo = bit.band(packet_header.Magic, 0xFF)

	function packet_header.Encode(type_, flags, packet_id, channel, fragment_id, total_fragments, payload)
		return string_char(
				magic_hi,
				magic_lo,
				packet_header.Version,
				type_,
				flags,
				packet_id % 256,
				bit.rshift(packet_id, 8) % 256,
				channel,
				fragment_id % 256,
				bit.rshift(fragment_id, 8) % 256,
				total_fragments
			) .. (
				payload or
				""
			)
	end

	function packet_header.Decode(str)
		if #str < packet_header.HeaderSize then return nil end

		local magic_a, magic_b, version, type_, flags, id_lo, id_hi, channel, frag_lo, frag_hi, total = string_byte(str, 1, 11)

		if magic_a ~= magic_hi or magic_b ~= magic_lo or version ~= packet_header.Version then
			return nil
		end

		return type_,
		flags,
		id_lo + id_hi * 256,
		channel,
		frag_lo + frag_hi * 256,
		total,
		string_sub(str, packet_header.HeaderSize + 1)
	end
end

return packet_header
