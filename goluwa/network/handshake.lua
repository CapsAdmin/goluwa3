local bit = require("bit")
local handshake = {}
handshake.PACKET_TYPE = {
	CONNECT_REQUEST = 2,
	CONNECT_ACCEPT = 3,
	CONNECT_REJECT = 4,
	CONNECT_CONFIRM = 5,
	DISCONNECT = 6,
}
handshake.STATE = {
	DISCONNECTED = 0,
	CONNECTING = 1,
	CONNECTED = 2,
	DISCONNECTING = 3,
}
handshake.DEFAULT_CONFIG = {
	connect_timeout = 5000,
	max_retries = 3,
	challenge_size = 16,
}

function handshake.GenerateChallenge(size)
	size = size or handshake.DEFAULT_CONFIG.challenge_size
	local bytes = {}

	for i = 1, size do
		bytes[i] = math.random(0, 255)
	end

	return bytes
end

function handshake.SerializeChallenge(challenge)
	local result = {}

	for i = 1, #challenge do
		result[#result + 1] = string.char(challenge[i])
	end

	return table.concat(result)
end

function handshake.DeserializeChallenge(str)
	local bytes = {}

	for i = 1, #str do
		bytes[i] = string.byte(str, i)
	end

	return bytes
end

local PeerState = {}
PeerState.__index = PeerState

function PeerState.New(config)
	local self = setmetatable({}, PeerState)
	self.config = config or handshake.DEFAULT_CONFIG
	self.state = handshake.STATE.DISCONNECTED
	self.connect_attempts = 0
	self.connect_start_time = 0
	self.challenge = nil
	self.peer_id = nil
	return self
end

function PeerState:SetState(new_state)
	self.state = new_state

	if new_state == handshake.STATE.CONNECTING then
		self.connect_start_time = os.clock() * 1000
		self.connect_attempts = 0
	elseif new_state == handshake.STATE.DISCONNECTED then
		self.peer_id = nil
		self.challenge = nil
	end
end

function PeerState:IsTimedOut()
	if self.state ~= handshake.STATE.CONNECTING then return false end

	local elapsed = os.clock() * 1000 - self.connect_start_time
	return elapsed > self.config.connect_timeout
end

function PeerState:ShouldRetry()
	return self.connect_attempts < self.config.max_retries
end

function PeerState:SendConnectRequest(server_address, client_id)
	if self.state ~= handshake.STATE.DISCONNECTED then
		return nil, "Not in disconnected state"
	end

	self:SetState(handshake.STATE.CONNECTING)
	self.connect_attempts = self.connect_attempts + 1
	self.peer_id = client_id
	self.challenge = handshake.GenerateChallenge()
	return {
		type = handshake.PACKET_TYPE.CONNECT_REQUEST,
		client_id = client_id,
		challenge = self.challenge,
		timestamp = os.clock() * 1000,
	}
end

function PeerState:HandleConnectRequest(client_address, request)
	if self.state ~= handshake.STATE.DISCONNECTED then
		return nil, "Not in disconnected state"
	end

	if not request.client_id then return nil, "Missing client_id" end

	if not request.challenge then return nil, "Missing challenge" end

	self:SetState(handshake.STATE.CONNECTED)
	return {
		type = handshake.PACKET_TYPE.CONNECT_ACCEPT,
		server_id = self.peer_id or 0,
		challenge_response = request.challenge,
		timestamp = os.clock() * 1000,
	}
end

function PeerState:HandleConnectAccept(response)
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	if not response.challenge_response then
		return nil, "Missing challenge_response"
	end

	self:SetState(handshake.STATE.CONNECTED)
	self.peer_id = response.server_id
	return {
		type = handshake.PACKET_TYPE.CONNECT_CONFIRM,
		timestamp = os.clock() * 1000,
	}
end

function PeerState:HandleConnectReject(response)
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	self:SetState(handshake.STATE.DISCONNECTED)
	return {
		error = response.error or "Connection rejected",
	}
end

function PeerState:HandleConnectTimeout()
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	if self:ShouldRetry() then
		self.connect_attempts = self.connect_attempts + 1
		self.connect_start_time = os.clock() * 1000
		self.challenge = handshake.GenerateChallenge()
		return {
			type = handshake.PACKET_TYPE.CONNECT_REQUEST,
			client_id = self.peer_id,
			challenge = self.challenge,
			timestamp = os.clock() * 1000,
		}
	else
		self:SetState(handshake.STATE.DISCONNECTED)
		return {
			error = "Connect timeout after " .. self.config.max_retries .. " attempts",
		}
	end
end

function PeerState:SendDisconnect(reason)
	if self.state == handshake.STATE.DISCONNECTED then
		return nil, "Already disconnected"
	end

	self:SetState(handshake.STATE.DISCONNECTING)
	return {
		type = handshake.PACKET_TYPE.DISCONNECT,
		reason = reason or "normal",
		timestamp = os.clock() * 1000,
	}
end

function PeerState:HandleDisconnect(packet)
	if self.state == handshake.STATE.DISCONNECTING then
		self:SetState(handshake.STATE.DISCONNECTED)
		return {completed = true}
	end

	self:SetState(handshake.STATE.DISCONNECTED)
	return {reason = packet.reason or "unknown"}
end

function PeerState:GetStateName()
	local names = {
		[handshake.STATE.DISCONNECTED] = "DISCONNECTED",
		[handshake.STATE.CONNECTING] = "CONNECTING",
		[handshake.STATE.CONNECTED] = "CONNECTED",
		[handshake.STATE.DISCONNECTING] = "DISCONNECTING",
	}
	return names[self.state] or "UNKNOWN"
end

handshake.PeerState = PeerState
handshake.CreatePeerState = function(config)
	return PeerState.New(config)
end
return handshake
