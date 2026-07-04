-- Connect Handshake — Client/Server connection lifecycle
-- Part of Step 9: reliable UDP transport layer

local bit = require("bit")
local handshake = {}

-- Handshake packet types (reuses network packet types)
handshake.PACKET_TYPE = {
	CONNECT_REQUEST = 2,
	CONNECT_ACCEPT = 3,
	CONNECT_REJECT = 4,
	CONNECT_CONFIRM = 5,
	DISCONNECT = 6,
}

-- Peer connection states
handshake.STATE = {
	DISCONNECTED = 0,
	CONNECTING = 1,
	CONNECTED = 2,
	DISCONNECTING = 3,
}

-- Handshake configuration
handshake.DEFAULT_CONFIG = {
	connect_timeout = 5000,       -- ms before considering connect failed
	max_retries = 3,
	challenge_size = 16,          -- bytes of random challenge
}

-- Generate a random challenge for handshake
function handshake.GenerateChallenge(size)
	size = size or handshake.DEFAULT_CONFIG.challenge_size
	local bytes = {}

	for i = 1, size do
		bytes[i] = math.random(0, 255)
	end

	return bytes
end

-- Serialize challenge to string
function handshake.SerializeChallenge(challenge)
	local result = {}

	for i = 1, #challenge do
		result[#result + 1] = string.char(challenge[i])
	end

	return table.concat(result)
end

-- Deserialize challenge from string
function handshake.DeserializeChallenge(str)
	local bytes = {}

	for i = 1, #str do
		bytes[i] = string.byte(str, i)
	end

	return bytes
end

-- Peer state — manages connection lifecycle
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

-- Transition to a new state
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

-- Check if connection has timed out
function PeerState:IsTimedOut()
	if self.state ~= handshake.STATE.CONNECTING then return false end

	local elapsed = os.clock() * 1000 - self.connect_start_time
	return elapsed > self.config.connect_timeout
end

-- Check if we should retry connect
function PeerState:ShouldRetry()
	return self.connect_attempts < self.config.max_retries
end

-- Client: Start connection attempt
function PeerState:SendConnectRequest(server_address, client_id)
	if self.state ~= handshake.STATE.DISCONNECTED then
		return nil, "Not in disconnected state"
	end

	self:SetState(handshake.STATE.CONNECTING)
	self.connect_attempts = self.connect_attempts + 1
	self.peer_id = client_id

	-- Generate challenge for this connection
	self.challenge = handshake.GenerateChallenge()

	return {
		type = handshake.PACKET_TYPE.CONNECT_REQUEST,
		client_id = client_id,
		challenge = self.challenge,
		timestamp = os.clock() * 1000,
	}
end

-- Server: Receive connect request and generate response
function PeerState:HandleConnectRequest(client_address, request)
	if self.state ~= handshake.STATE.DISCONNECTED then
		return nil, "Not in disconnected state"
	end

	-- Validate request
	if not request.client_id then
		return nil, "Missing client_id"
	end

	if not request.challenge then
		return nil, "Missing challenge"
	end

	-- Accept the connection (in real usage, you'd validate client_id against whitelist, etc.)
	self:SetState(handshake.STATE.CONNECTED)

	return {
		type = handshake.PACKET_TYPE.CONNECT_ACCEPT,
		server_id = self.peer_id or 0,
		challenge_response = request.challenge, -- Echo challenge back
		timestamp = os.clock() * 1000,
	}
end

-- Client: Receive connect accept
function PeerState:HandleConnectAccept(response)
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	-- Verify challenge response matches what we sent
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

-- Client: Receive connect reject
function PeerState:HandleConnectReject(response)
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	self:SetState(handshake.STATE.DISCONNECTED)

	return {
		error = response.error or "Connection rejected",
	}
end

-- Client: Receive connect timeout (no response from server)
function PeerState:HandleConnectTimeout()
	if self.state ~= handshake.STATE.CONNECTING then
		return nil, "Not in connecting state"
	end

	if self:ShouldRetry() then
		-- Retry connection
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
		-- Give up
		self:SetState(handshake.STATE.DISCONNECTED)

		return {
			error = "Connect timeout after " .. self.config.max_retries .. " attempts",
		}
	end
end

-- Both: Send disconnect
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

-- Both: Receive disconnect
function PeerState:HandleDisconnect(packet)
	if self.state == handshake.STATE.DISCONNECTING then
		self:SetState(handshake.STATE.DISCONNECTED)
		return { completed = true }
	end

	self:SetState(handshake.STATE.DISCONNECTED)
	return { reason = packet.reason or "unknown" }
end

-- Get state name for debugging
function PeerState:GetStateName()
	local names = {
		[handshake.STATE.DISCONNECTED] = "DISCONNECTED",
		[handshake.STATE.CONNECTING] = "CONNECTING",
		[handshake.STATE.CONNECTED] = "CONNECTED",
		[handshake.STATE.DISCONNECTING] = "DISCONNECTING",
	}

	return names[self.state] or "UNKNOWN"
end

-- Export
handshake.PeerState = PeerState
handshake.CreatePeerState = function(config) return PeerState.New(config) end

return handshake
