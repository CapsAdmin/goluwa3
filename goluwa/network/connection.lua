local ffi = require("ffi")
local bit = require("bit")
local string_buffer = require("string.buffer")
local packet_header = import("goluwa/network/packet_header.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local handshake = import("goluwa/network/handshake.lua")
local connection = {}
connection.MAX_DATAGRAM = reliable_send.DATAGRAM_SIZE
connection.MAX_FRAGMENT = connection.MAX_DATAGRAM - packet_header.PrefixSize - packet_header.FragmentRecordHeaderSize
connection.MAX_UNRELIABLE = connection.MAX_DATAGRAM - packet_header.PrefixSize - packet_header.RecordHeaderSize
connection.MAX_FRAGMENTS = 65535
connection.MAX_ACKS_PER_RECORD = math.floor(connection.MAX_UNRELIABLE / 2)
connection.TIMEOUT = 10
connection.PING_INTERVAL = 1
connection.CONNECT_INTERVAL = 0.5
connection.CONNECT_ATTEMPTS = 10
connection.RECEIVE_WINDOW = 2048
connection.QUEUE_LIMIT = 1024
local STATE = handshake.STATE
local SUBTYPE = handshake.PACKET_TYPE
local TYPE_DATA = packet_header.TYPE_DATA
local TYPE_ACK = packet_header.TYPE_ACK
local TYPE_CONNECT = packet_header.TYPE_CONNECT
local TYPE_DISCONNECT = packet_header.TYPE_DISCONNECT
local TYPE_PING = packet_header.TYPE_PING
local TYPE_PONG = packet_header.TYPE_PONG
local FLAG_RELIABLE = packet_header.FLAG_RELIABLE
local FLAG_SEQUENCED = packet_header.FLAG_UNRELIABLE_SEQUENCED
local PREFIX = packet_header.Prefix
local PREFIX_SIZE = packet_header.PrefixSize
local EncodeRecord = packet_header.EncodeRecord
local DecodeRecord = packet_header.DecodeRecord
local IsDatagram = packet_header.IsDatagram
local string_char = string.char
local string_sub = string.sub
local table_concat = table.concat
local bit_band = bit.band
local bit_rshift = bit.rshift
local u8_ptr = ffi.typeof("const uint8_t *")
local Connection = {}
Connection.__index = Connection

function connection.Now()
	return reliable_send.Now() / 1000
end

function connection.New(send, is_server)
	local self = setmetatable({}, Connection)
	self.stats = {
		sent = 0,
		received = 0,
		retransmitted = 0,
		bytes_out = 0,
		bytes_in = 0,
		datagrams_out = 0,
		datagrams_in = 0,
		window = 0,
		rto = 0,
	}
	local stats = self.stats
	self.send = function(str)
		stats.bytes_out = stats.bytes_out + #str
		stats.datagrams_out = stats.datagrams_out + 1
		return send(str)
	end
	self.is_server = is_server
	self.state = handshake.CreatePeerState()
	self.ping = 0
	self.last_receive = connection.Now()
	self.last_ping = 0
	self.next_connect_send = 0
	self.connect_attempts = 0
	self:Reset()
	return self
end

function Connection:Reset()
	self.channels = {}
	self.queue = {}
	self.backlog_channels = {}
	self.ack_channels = {}
	self.out = {[0] = PREFIX}
	self.out_count = 0
	self.out_size = PREFIX_SIZE
	self.acked_any = false
	self.sender = reliable_send.New()
end

function Connection:IsConnected()
	return self.state.state == STATE.CONNECTED
end

function Connection:IsConnecting()
	return self.state.state == STATE.CONNECTING
end

function Connection:GetChannel(id)
	local channel = self.channels[id]

	if not channel then
		channel = {
			id = id,
			send_seq = 0,
			send_base = 0,
			next_flight = 0,
			backlog = {},
			backlog_head = 1,
			backlog_tail = 0,
			unacked = {},
			unacked_count = 0,
			recv_expected = 0,
			pending = {},
			assembly = {},
			acks = {},
			ack_count = 0,
			sequenced_out = 0,
			sequenced_in = nil,
		}
		self.channels[id] = channel
	end

	return channel
end

function Connection:Write(record)
	if self.out_size + #record > connection.MAX_DATAGRAM then
		self:FlushDatagram()
	end

	local count = self.out_count + 1
	self.out[count] = record
	self.out_count = count
	self.out_size = self.out_size + #record
end

function Connection:FlushDatagram()
	local count = self.out_count

	if count == 0 then return end

	self.out_count = 0
	self.out_size = PREFIX_SIZE
	self.send(table_concat(self.out, "", 0, count))
end

do
	local buffer = string_buffer.new()

	function Connection:Flush()
		local ack_channels = self.ack_channels

		for i = 1, #ack_channels do
			local ch = ack_channels[i]
			ack_channels[i] = nil
			local acks = ch.acks
			local count = ch.ack_count
			ch.ack_count = 0
			local first = 1

			while first <= count do
				local last = math.min(count, first + connection.MAX_ACKS_PER_RECORD - 1)
				local ptr = buffer:reserve((last - first + 1) * 2)
				local offset = 0

				for j = first, last do
					local seq = acks[j]
					ptr[offset] = bit_band(seq, 0xFF)
					ptr[offset + 1] = bit_rshift(seq, 8)
					offset = offset + 2
				end

				buffer:commit(offset)
				self:Write(EncodeRecord(TYPE_ACK, 0, ch.id, 0, buffer:get()))
				first = last + 1
			end
		end

		self:FlushDatagram()
	end
end

function Connection:QueueAck(ch, seq)
	local count = ch.ack_count + 1
	ch.acks[count] = seq
	ch.ack_count = count

	if count == 1 then
		local ack_channels = self.ack_channels
		ack_channels[#ack_channels + 1] = ch
	end
end

function Connection:FlushBacklogs()
	local list = self.backlog_channels
	local count = #list

	if count == 0 then return end

	local sender = self.sender
	local window = connection.RECEIVE_WINDOW
	local now = reliable_send.Now()
	local progressed = true

	while progressed and count > 0 do
		progressed = false
		local i = 1

		while i <= count do
			local ch = list[i]
			local entry = ch.backlog[ch.backlog_head]

			if (ch.next_flight - ch.send_base) % 65536 < window and sender:CanSend(entry.size) then
				ch.backlog[ch.backlog_head] = nil
				ch.backlog_head = ch.backlog_head + 1
				ch.next_flight = (entry.seq + 1) % 65536
				ch.unacked[entry.seq] = entry
				ch.unacked_count = ch.unacked_count + 1
				sender:OnSent(entry, now)
				self:Write(entry.record)
				progressed = true

				if ch.backlog_head > ch.backlog_tail then
					list[i] = list[count]
					list[count] = nil
					count = count - 1
				else
					i = i + 1
				end
			else
				i = i + 1
			end
		end
	end

	sender.cwnd_limited = count > 0
end

function Connection:SendHandshake(subtype)
	self:Write(EncodeRecord(TYPE_CONNECT, 0, 0, 0, string_char(subtype) .. self.challenge))
	self:FlushDatagram()
end

function Connection:Connect(now)
	local request = assert(self.state:SendConnectRequest(nil, 1))
	self.challenge = handshake.SerializeChallenge(request.challenge)
	self.connect_attempts = 0
	self.next_connect_send = now or connection.Now()
end

function Connection:Disconnect(code, now)
	if self.state.state == STATE.DISCONNECTED then return end

	local was_connected = self.state.state == STATE.CONNECTED
	self.state:SetState(STATE.DISCONNECTED)
	code = code or 1

	if was_connected then
		self:Flush()
		local datagram = PREFIX .. EncodeRecord(TYPE_DISCONNECT, 0, 0, 0, string_char(code % 256))
		self.send(datagram)
		self.send(datagram)
	end

	self:Reset()

	if self.OnDisconnect then self:OnDisconnect(code) end
end

function Connection:Send(payload, flags, channel)
	channel = channel or 0

	if self.state.state ~= STATE.CONNECTED then
		if self.state.state == STATE.DISCONNECTED then return false end

		assert(#self.queue < connection.QUEUE_LIMIT, "connection queue is full")
		self.queue[#self.queue + 1] = {payload, flags, channel}
		return true
	end

	self.stats.sent = self.stats.sent + 1

	if flags == "reliable" then
		local max = connection.MAX_FRAGMENT
		local length = #payload
		local total = math.max(1, math.ceil(length / max))
		assert(
			total <= connection.MAX_FRAGMENTS,
			"reliable payload of " .. length .. " bytes is too big"
		)
		local ch = self:GetChannel(channel)
		local backlog = ch.backlog
		local was_empty = ch.backlog_head > ch.backlog_tail

		for i = 1, total do
			local seq = ch.send_seq
			local record = total == 1 and
				EncodeRecord(TYPE_DATA, FLAG_RELIABLE, channel, seq, payload) or
				EncodeRecord(
					TYPE_DATA,
					FLAG_RELIABLE,
					channel,
					seq,
					string_sub(payload, (i - 1) * max + 1, i * max),
					i,
					total
				)
			ch.send_seq = (seq + 1) % 65536
			local tail = ch.backlog_tail + 1
			backlog[tail] = {seq = seq, record = record, size = #record}
			ch.backlog_tail = tail
		end

		if was_empty then
			local list = self.backlog_channels
			list[#list + 1] = ch
		end

		self:FlushBacklogs()
		return true
	end

	assert(
		#payload <= connection.MAX_UNRELIABLE,
		"unreliable payload of " .. #payload .. " bytes is too big, send it reliable"
	)

	if flags == "sequenced" then
		local ch = self:GetChannel(channel)
		local seq = ch.sequenced_out
		ch.sequenced_out = (seq + 1) % 65536
		self:Write(EncodeRecord(TYPE_DATA, FLAG_SEQUENCED, channel, seq, payload))
	else
		self:Write(EncodeRecord(TYPE_DATA, 0, channel, 0, payload))
	end

	return true
end

function Connection:Deliver(payload, flags, channel)
	self.stats.received = self.stats.received + 1

	if self.OnReceive then
		local ok, err = xpcall(self.OnReceive, debug.traceback, self, payload, flags, channel)

		if not ok then wlog("error in network receive callback: %s", err) end
	end
end

function Connection:DeliverReliable(ch, channel, fragment_id, total, payload)
	if total <= 1 then
		self:Deliver(payload, "reliable", channel)
		return
	end

	local assembly = ch.assembly
	assembly[#assembly + 1] = payload

	if fragment_id == total then
		ch.assembly = {}
		self:Deliver(table_concat(assembly), "reliable", channel)
	end
end

function Connection:OnConnected(now)
	self.last_receive = now
	self.last_ping = now
	local queue = self.queue
	self.queue = {}

	if self.OnConnect then self:OnConnect() end

	for _, args in ipairs(queue) do
		self:Send(args[1], args[2], args[3])
	end
end

function Connection:AddHandshakeRttSample(now)
	if not self.handshake_sent_at then return end

	self.sender:AddRttSample((now - self.handshake_sent_at) * 1000)
	self.ping = self.sender.srtt
	self.handshake_sent_at = nil
end

function Connection:HandleHandshake(payload, now)
	local subtype = payload:byte(1)
	local challenge = string_sub(payload, 2)
	local state = self.state

	if subtype == SUBTYPE.CONNECT_REQUEST then
		if not self.is_server then return end

		if state.state == STATE.DISCONNECTED then
			assert(
				state:HandleConnectRequest(nil, {client_id = 1, challenge = handshake.DeserializeChallenge(challenge)})
			)
			self.challenge = challenge
			self.handshake_sent_at = now
			self:SendHandshake(SUBTYPE.CONNECT_ACCEPT)
			self:OnConnected(now)
		elseif challenge == self.challenge then
			self.handshake_sent_at = nil
			self:SendHandshake(SUBTYPE.CONNECT_ACCEPT)
		end
	elseif subtype == SUBTYPE.CONNECT_ACCEPT then
		if self.is_server or state.state ~= STATE.CONNECTING or challenge ~= self.challenge then
			return
		end

		assert(state:HandleConnectAccept{challenge_response = challenge, server_id = 0})
		self:AddHandshakeRttSample(now)
		self:SendHandshake(SUBTYPE.CONNECT_CONFIRM)
		self:OnConnected(now)
	elseif subtype == SUBTYPE.CONNECT_CONFIRM then
		if self.is_server and challenge == self.challenge then
			self:AddHandshakeRttSample(now)
		end
	elseif subtype == SUBTYPE.CONNECT_REJECT then
		if state.state == STATE.CONNECTING then
			state:SetState(STATE.DISCONNECTED)

			if self.OnDisconnect then self:OnDisconnect(0) end
		end
	end
end

function Connection:HandleAck(channel, str, start, stop, now)
	local ch = self.channels[channel]

	if not ch then return end

	local sender = self.sender
	local unacked = ch.unacked
	local ptr = ffi.cast(u8_ptr, str)
	local newest

	for i = start - 1, stop - 2, 2 do
		local seq = ptr[i] + ptr[i + 1] * 256
		local entry = unacked[seq]

		if entry then
			unacked[seq] = nil
			ch.unacked_count = ch.unacked_count - 1
			sender:OnAcked(entry)

			if entry.transmissions == 1 and (not newest or entry.index > newest.index) then
				newest = entry
			end
		end
	end

	if newest then
		sender:AddRttSample(now * 1000 - newest.sent_at)
		self.ping = sender.srtt
	end

	local base = ch.send_base

	while base ~= ch.next_flight and not unacked[base] do
		base = (base + 1) % 65536
	end

	ch.send_base = base
	self.acked_any = true
end

function Connection:ReceiveAcks(str, now)
	if self.state.state ~= STATE.CONNECTED or not IsDatagram(str) then return end

	now = now or connection.Now()
	local window = connection.RECEIVE_WINDOW
	local pos = PREFIX_SIZE + 1
	local size = #str

	while pos <= size do
		local type_, flags, channel, id, _, _, start, stop = DecodeRecord(str, pos)

		if not type_ then break end

		if type_ == TYPE_ACK then
			self:HandleAck(channel, str, start, stop, now)
		elseif type_ == TYPE_DATA and bit_band(flags, FLAG_RELIABLE) ~= 0 then
			local ch = self:GetChannel(channel)
			local diff = (id - ch.recv_expected) % 65536

			if diff < window or diff >= 65536 - window then self:QueueAck(ch, id) end
		end

		pos = stop + 1
	end

	if self.acked_any then
		self.acked_any = false
		self:FlushBacklogs()
	end
end

function Connection:Receive(str, now)
	if not IsDatagram(str) then return end

	now = now or connection.Now()
	local stats = self.stats
	stats.bytes_in = stats.bytes_in + #str
	stats.datagrams_in = stats.datagrams_in + 1
	self.last_receive = now
	local window = connection.RECEIVE_WINDOW
	local pos = PREFIX_SIZE + 1
	local size = #str

	while pos <= size do
		local type_, flags, channel, id, fragment_id, total, start, stop = DecodeRecord(str, pos)

		if not type_ then break end

		pos = stop + 1

		if type_ == TYPE_CONNECT then
			self:HandleHandshake(string_sub(str, start, stop), now)
		elseif self.state.state == STATE.CONNECTED then
			if type_ == TYPE_DATA then
				if bit_band(flags, FLAG_RELIABLE) ~= 0 then
					local ch = self:GetChannel(channel)
					local diff = (id - ch.recv_expected) % 65536

					if diff < window then
						self:QueueAck(ch, id)

						if diff == 0 then
							self:DeliverReliable(ch, channel, fragment_id, total, string_sub(str, start, stop))
							local expected = (ch.recv_expected + 1) % 65536
							local pending = ch.pending[expected]

							while pending do
								ch.pending[expected] = nil
								self:DeliverReliable(ch, channel, pending[1], pending[2], pending[3])
								expected = (expected + 1) % 65536
								pending = ch.pending[expected]
							end

							ch.recv_expected = expected
						elseif not ch.pending[id] then
							ch.pending[id] = {fragment_id, total, string_sub(str, start, stop)}
						end
					elseif diff >= 65536 - window then
						self:QueueAck(ch, id)
					end
				elseif bit_band(flags, FLAG_SEQUENCED) ~= 0 then
					local ch = self:GetChannel(channel)
					local last = ch.sequenced_in

					if not last or (id - last) % 65536 < 32768 and id ~= last then
						ch.sequenced_in = id
						self:Deliver(string_sub(str, start, stop), "sequenced", channel)
					end
				else
					self:Deliver(string_sub(str, start, stop), "unreliable", channel)
				end
			elseif type_ == TYPE_ACK then
				self:HandleAck(channel, str, start, stop, now)
			elseif type_ == TYPE_PING then
				self:Write(EncodeRecord(TYPE_PONG, 0, 0, 0, string_sub(str, start, stop)))
			elseif type_ == TYPE_PONG then
				local sent = tonumber(string_sub(str, start, stop))

				if sent then
					self.sender:AddRttSample((now - sent) * 1000)
					self.ping = self.sender.srtt
				end
			elseif type_ == TYPE_DISCONNECT then
				self.state:SetState(STATE.DISCONNECTED)
				self:Reset()

				if self.OnDisconnect then self:OnDisconnect(str:byte(start) or 0) end
			end
		end
	end

	if self.acked_any then
		self.acked_any = false
		self:FlushBacklogs()
	end
end

function Connection:Update(now)
	now = now or connection.Now()
	local state = self.state.state

	if state == STATE.CONNECTING then
		if now >= self.next_connect_send then
			if self.connect_attempts >= connection.CONNECT_ATTEMPTS then
				self.state:SetState(STATE.DISCONNECTED)

				if self.OnDisconnect then self:OnDisconnect(0) end

				return
			end

			self.connect_attempts = self.connect_attempts + 1
			self.next_connect_send = now + connection.CONNECT_INTERVAL
			self.handshake_sent_at = self.connect_attempts == 1 and now or nil
			self:SendHandshake(SUBTYPE.CONNECT_REQUEST)
		end

		return
	end

	if state ~= STATE.CONNECTED then return end

	if now - self.last_receive > connection.TIMEOUT then
		self:Disconnect(0, now)
		return
	end

	local sender = self.sender

	if sender.in_flight > 0 then
		local now_ms = now * 1000
		local give_up = connection.TIMEOUT * 1000
		local stats = self.stats

		for _, ch in pairs(self.channels) do
			if ch.unacked_count > 0 then
				for _, entry in pairs(ch.unacked) do
					if sender:CheckLost(entry, now_ms) then
						if now_ms - entry.first_sent_at > give_up then
							self:Disconnect(0, now)
							return
						end

						stats.retransmitted = stats.retransmitted + 1
						self:Write(entry.record)
					end
				end
			end
		end
	end

	if now - self.last_ping >= connection.PING_INTERVAL then
		self.last_ping = now
		self:Write(EncodeRecord(TYPE_PING, 0, 0, 0, string.format("%.6f", now)))
	end

	self:FlushBacklogs()
	self.stats.window = sender.cwnd
	self.stats.rto = sender.rto
	self:Flush()
end

return connection
