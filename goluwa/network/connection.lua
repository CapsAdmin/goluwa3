local bit = require("bit")
local packet_header = import("goluwa/network/packet_header.lua")
local reliable_send = import("goluwa/network/reliable_send.lua")
local handshake = import("goluwa/network/handshake.lua")
local connection = {}
connection.MAX_FRAGMENT = 1100
connection.MAX_UNRELIABLE = 1200
connection.TIMEOUT = 10
connection.PING_INTERVAL = 1
connection.CONNECT_INTERVAL = 0.5
connection.CONNECT_ATTEMPTS = 10
connection.RECEIVE_WINDOW = 1024
connection.QUEUE_LIMIT = 1024
connection.SEND_WINDOW = 64
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
local RELIABLE = reliable_send.RELIABILITY.RELIABLE
local Encode = packet_header.Encode
local Decode = packet_header.Decode
local string_char = string.char
local string_sub = string.sub
local bit_band = bit.band
local Connection = {}
Connection.__index = Connection

function connection.Now()
	return reliable_send.Now() / 1000
end

function connection.New(send, is_server)
	local self = setmetatable({}, Connection)
	self.stats = {sent = 0, received = 0, retransmitted = 0, bytes_out = 0, bytes_in = 0}
	local stats = self.stats
	self.send = function(str)
		stats.bytes_out = stats.bytes_out + #str
		return send(str)
	end
	self.is_server = is_server
	self.state = handshake.CreatePeerState()
	self.channels = {}
	self.queue = {}
	self.ping = 0
	self.last_receive = connection.Now()
	self.last_ping = 0
	self.next_connect_send = 0
	self.connect_attempts = 0
	return self
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
			send_seq = 1,
			recv_expected = 1,
			pending = {},
			assembly = {},
			backlog = {},
			backlog_head = 1,
			backlog_tail = 0,
			sequenced_out = 1,
			sequenced_in = nil,
			tracker = reliable_send.CreateTracker(),
		}
		self.channels[id] = channel
	end

	return channel
end

function Connection:FlushBacklog(ch)
	local tracker = ch.tracker

	while
		ch.backlog_head <= ch.backlog_tail and
		tracker.unacked_count < connection.SEND_WINDOW
	do
		local entry = ch.backlog[ch.backlog_head]
		ch.backlog[ch.backlog_head] = nil
		ch.backlog_head = ch.backlog_head + 1
		tracker:TrackPacket(entry[1], entry[2], RELIABLE)
		self.send(entry[2])
	end
end

function Connection:SendHandshake(subtype)
	self.send(Encode(TYPE_CONNECT, 0, 0, 0, 0, 1, string_char(subtype) .. self.challenge))
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
		local frame = Encode(TYPE_DISCONNECT, 0, 0, 0, 0, 1, string_char(code % 256))
		self.send(frame)
		self.send(frame)
	end

	self.queue = {}
	self.channels = {}

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

	local ch = self:GetChannel(channel)
	self.stats.sent = self.stats.sent + 1

	if flags == "reliable" then
		local max = connection.MAX_FRAGMENT
		local total = math.max(1, math.ceil(#payload / max))

		for i = 1, total do
			local seq = ch.send_seq
			ch.send_seq = seq % 65535 + 1
			local frame = Encode(
				TYPE_DATA,
				FLAG_RELIABLE,
				seq,
				channel,
				i,
				total,
				total == 1 and payload or string_sub(payload, (i - 1) * max + 1, i * max)
			)
			ch.backlog_tail = ch.backlog_tail + 1
			ch.backlog[ch.backlog_tail] = {seq, frame}
		end

		self:FlushBacklog(ch)
		return true
	end

	assert(
		#payload <= connection.MAX_UNRELIABLE,
		"unreliable payload of " .. #payload .. " bytes is too big, send it reliable"
	)

	if flags == "sequenced" then
		local seq = ch.sequenced_out
		ch.sequenced_out = seq % 65535 + 1
		self.send(Encode(TYPE_DATA, FLAG_SEQUENCED, seq, channel, 1, 1, payload))
	else
		self.send(Encode(TYPE_DATA, 0, 0, channel, 1, 1, payload))
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
		self:Deliver(table.concat(assembly), "reliable", channel)
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
			self:SendHandshake(SUBTYPE.CONNECT_ACCEPT)
			self:OnConnected(now)
		elseif challenge == self.challenge then
			self:SendHandshake(SUBTYPE.CONNECT_ACCEPT)
		end
	elseif subtype == SUBTYPE.CONNECT_ACCEPT then
		if self.is_server or state.state ~= STATE.CONNECTING or challenge ~= self.challenge then
			return
		end

		assert(state:HandleConnectAccept{challenge_response = challenge, server_id = 0})
		self:SendHandshake(SUBTYPE.CONNECT_CONFIRM)
		self:OnConnected(now)
	elseif subtype == SUBTYPE.CONNECT_REJECT then
		if state.state == STATE.CONNECTING then
			state:SetState(STATE.DISCONNECTED)

			if self.OnDisconnect then self:OnDisconnect(0) end
		end
	end
end

function Connection:Receive(str, now)
	local type_, flags, id, channel, fragment_id, total, payload = Decode(str)

	if not type_ then return end

	self.stats.bytes_in = self.stats.bytes_in + #str
	now = now or connection.Now()
	self.last_receive = now

	if type_ == TYPE_CONNECT then
		self:HandleHandshake(payload, now)
		return
	end

	if self.state.state ~= STATE.CONNECTED then return end

	if type_ == TYPE_DATA then
		if bit_band(flags, FLAG_RELIABLE) ~= 0 then
			self.send(Encode(TYPE_ACK, 0, id, channel, 0, 1))
			local ch = self:GetChannel(channel)
			local diff = (id - ch.recv_expected) % 65536

			if diff == 0 then
				self:DeliverReliable(ch, channel, fragment_id, total, payload)
				local expected = ch.recv_expected % 65535 + 1
				local pending = ch.pending[expected]

				while pending do
					ch.pending[expected] = nil
					self:DeliverReliable(ch, channel, pending[1], pending[2], pending[3])
					expected = expected % 65535 + 1
					pending = ch.pending[expected]
				end

				ch.recv_expected = expected
			elseif diff < connection.RECEIVE_WINDOW and not ch.pending[id] then
				ch.pending[id] = {fragment_id, total, payload}
			end
		elseif bit_band(flags, FLAG_SEQUENCED) ~= 0 then
			local ch = self:GetChannel(channel)
			local last = ch.sequenced_in

			if not last or (id - last) % 65536 < 32768 and id ~= last then
				ch.sequenced_in = id
				self:Deliver(payload, "sequenced", channel)
			end
		else
			self:Deliver(payload, "unreliable", channel)
		end
	elseif type_ == TYPE_ACK then
		local ch = self.channels[channel]

		if ch then
			local unacked = ch.tracker.unacked[id]

			if unacked and unacked.retry_count == 0 then
				local rtt = now * 1000 - unacked.send_time
				self.ping = self.ping == 0 and rtt or self.ping * 0.8 + rtt * 0.2
			end

			ch.tracker:AckPacket(id)
			self:FlushBacklog(ch)
		end
	elseif type_ == TYPE_PING then
		self.send(Encode(TYPE_PONG, 0, 0, 0, 0, 1, payload))
	elseif type_ == TYPE_PONG then
		local sent = tonumber(payload)

		if sent then
			local rtt = (now - sent) * 1000
			self.ping = self.ping == 0 and rtt or self.ping * 0.8 + rtt * 0.2
		end
	elseif type_ == TYPE_DISCONNECT then
		self.state:SetState(STATE.DISCONNECTED)
		self.queue = {}
		self.channels = {}

		if self.OnDisconnect then self:OnDisconnect(payload:byte(1) or 0) end
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
			self:SendHandshake(SUBTYPE.CONNECT_REQUEST)
		end

		return
	end

	if state ~= STATE.CONNECTED then return end

	if now - self.last_receive > connection.TIMEOUT then
		self:Disconnect(0, now)
		return
	end

	local now_ms = now * 1000
	local failed_any = false

	for _, ch in pairs(self.channels) do
		if next(ch.tracker.unacked) then
			local retransmit, failed = ch.tracker:OnTimeout(now_ms)

			for _, unacked in ipairs(retransmit) do
				self.stats.retransmitted = self.stats.retransmitted + 1
				self.send(unacked.payload)
			end

			if failed[1] then failed_any = true end
		end
	end

	if failed_any then
		self:Disconnect(0, now)
		return
	end

	if now - self.last_ping >= connection.PING_INTERVAL then
		self.last_ping = now
		self.send(Encode(TYPE_PING, 0, 0, 0, 0, 1, string.format("%.6f", now)))
	end
end

return connection
