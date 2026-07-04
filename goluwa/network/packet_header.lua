-- Wire protocol header for reliable UDP transport layer (ENet-like)
--
-- Layout (all fields little-endian):
--   +--------+--------+--------+--------+
--   | Magic  | Ver    | Type   | Flags  |  4 bytes
--   +--------+--------+--------+--------+
--   |          Packet ID (16-bit)         |  2 bytes
--   +--------+--------+--------+--------+
--   | Chan | FragID(16) | NFrag(8)       |  4 bytes
--   +--------+--------+--------+--------+
--   |          Payload (variable)         |
--   +------------------------------------+
--
-- Total fixed header: 10 bytes

local bit = require("bit")
local packet_header = {}
packet_header.Magic = 0x474C -- "GL" (Goluwa)
packet_header.Version = 1

-- Packet types
packet_header.TYPE_DATA = 0
packet_header.TYPE_ACK = 1
packet_header.TYPE_CONNECT = 2
packet_header.TYPE_DISCONNECT = 3
packet_header.TYPE_PING = 4
packet_header.TYPE_PONG = 5

-- Reliability flags (bits 0-1)
packet_header.FLAG_UNRELIABLE = 0
packet_header.FLAG_RELIABLE = bit.lshift(1, 0)
packet_header.FLAG_UNRELIABLE_SEQUENCED = bit.lshift(1, 1)

-- Sequence flags (bits 2-3)
packet_header.FLAG_HAS_SEQUENCE = bit.lshift(1, 2)
packet_header.FLAG_HAS_FRAGMENT = bit.lshift(1, 3)

-- Header sizes
packet_header.HeaderSize = 11
packet_header.MaxPayload = 4096 -- bytes per framed packet (tunable MTU)

-- --- Serialization ---

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

-- --- Framing ---

-- Wrap payload bytes into a framed packet (header + payload)
function packet_header.Frame(payload_bytes, channel, fragment_id, total_fragments)
	local buf = import("goluwa/network/packet.lua").CreateBuffer()
	packet_header.WriteHeader(buf, packet_header.TYPE_DATA, 0, 0, channel or 0, fragment_id or 1, total_fragments or 1)

	for _, b in ipairs(payload_bytes) do
		buf:WriteByte(b)
	end

	return buf:GetString()
end

-- Wrap raw string data into a framed packet (header + payload)
function packet_header.FrameString(data, channel, fragment_id, total_fragments)
	local buf = import("goluwa/network/packet.lua").CreateBuffer()
	packet_header.WriteHeader(buf, packet_header.TYPE_DATA, 0, 0, channel or 0, fragment_id or 1, total_fragments or 1)

	for i = 1, #data do
		buf:WriteByte(data:byte(i))
	end

	return buf:GetString()
end

-- Unframe a received packet: strip the header, return (header_info, payload_bytes)
function packet_header.Unframe(data)
	local buf = import("goluwa/network/packet.lua").CreateBuffer(data)
	local header = packet_header.ReadHeader(buf)
	local payload = {}

	while not buf:TheEnd() do
		payload[#payload + 1] = buf:ReadByte()
	end

	return header, payload
end

-- --- Fragmentation ---

-- Split a payload into fragments that fit within MaxPayload (including header)
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

-- Reassemble fragments into a single payload
function packet_header.Reassemble(fragments)
	if #fragments == 0 then return {} end

	-- Read the first fragment's header to get total fragment count
	local first_buf = import("goluwa/network/packet.lua").CreateBuffer(fragments[1])
	local first_header = packet_header.ReadHeader(first_buf)
	local total = first_header.total_fragments

	if total <= 1 then
		-- Single packet: ReadHeader already advanced position past header (11 bytes),
		-- so payload starts at current position. Just read remaining bytes.
		local payload = {}

		while not first_buf:TheEnd() do
			payload[#payload + 1] = first_buf:ReadByte()
		end

		return payload
	end

	-- Multi-fragment: collect all payloads in order
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

return packet_header
