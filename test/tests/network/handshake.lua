-- Tests for connect handshake (Step 9)

local T = import("test/environment.lua")
local handshake = import("goluwa/network/handshake.lua")

T.Test("Handshake packet types are defined", function()
	T(handshake.PACKET_TYPE.CONNECT_REQUEST)["=="](2)
	T(handshake.PACKET_TYPE.CONNECT_ACCEPT)["=="](3)
	T(handshake.PACKET_TYPE.CONNECT_REJECT)["=="](4)
	T(handshake.PACKET_TYPE.CONNECT_CONFIRM)["=="](5)
	T(handshake.PACKET_TYPE.DISCONNECT)["=="](6)
end)

T.Test("Handshake states are defined", function()
	T(handshake.STATE.DISCONNECTED)["=="](0)
	T(handshake.STATE.CONNECTING)["=="](1)
	T(handshake.STATE.CONNECTED)["=="](2)
	T(handshake.STATE.DISCONNECTING)["=="](3)
end)

T.Test("GenerateChallenge creates byte array", function()
	local challenge = handshake.GenerateChallenge(16)
	T(#challenge)["=="](16)

	-- Each byte should be 0-255
	for i = 1, #challenge do
		T(challenge[i])["~="](nil)
		T(challenge[i])[">="](0)
		T(challenge[i])["<="](255)
	end
end)

T.Test("SerializeChallenge/DeserializeChallenge round-trip", function()
	local original = {65, 66, 67, 68, 69}
	local str = handshake.SerializeChallenge(original)
	local deserialized = handshake.DeserializeChallenge(str)

	T(#deserialized)["=="](#original)

	for i = 1, #original do
		T(deserialized[i])["=="](original[i])
	end
end)

T.Test("PeerState starts in DISCONNECTED state", function()
	local peer = handshake.CreatePeerState()
	T(peer.state)["=="](handshake.STATE.DISCONNECTED)
	T(peer:GetStateName())["=="]("DISCONNECTED")
end)

T.Test("Client: SendConnectRequest transitions to CONNECTING", function()
	local client = handshake.CreatePeerState()
	local request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 12345)

	T(request)["~="](nil)
	T(request.type)["=="](handshake.PACKET_TYPE.CONNECT_REQUEST)
	T(request.client_id)["=="](12345)
	T(request.challenge)["~="](nil)
	T(client.state)["=="](handshake.STATE.CONNECTING)
end)

T.Test("Client: Cannot send connect request from CONNECTING state", function()
	local client = handshake.CreatePeerState()
	client:SetState(handshake.STATE.CONNECTING)

	local request, error = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 12345)
	T(request)["=="](nil)
	T(error)["~="](nil)
end)

T.Test("Server: HandleConnectRequest accepts valid request", function()
	local server = handshake.CreatePeerState()
	server.peer_id = 99999

	local client_request = {
		client_id = 12345,
		challenge = {1, 2, 3, 4},
	}

	local response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(response)["~="](nil)
	T(response.type)["=="](handshake.PACKET_TYPE.CONNECT_ACCEPT)
	T(response.server_id)["=="](99999)
	T(server.state)["=="](handshake.STATE.CONNECTED)
end)

T.Test("Server: HandleConnectRequest rejects missing client_id", function()
	local server = handshake.CreatePeerState()
	local response, error = server:HandleConnectRequest({}, {challenge = {1, 2, 3}})
	T(response)["=="](nil)
	T(error)["~="](nil)
end)

T.Test("Server: HandleConnectRequest rejects missing challenge", function()
	local server = handshake.CreatePeerState()
	local response, error = server:HandleConnectRequest({}, {client_id = 12345})
	T(response)["=="](nil)
	T(error)["~="](nil)
end)

T.Test("Client: HandleConnectAccept transitions to CONNECTED", function()
	local client = handshake.CreatePeerState()
	client:SetState(handshake.STATE.CONNECTING)

	local response = client:HandleConnectAccept({
		server_id = 99999,
		challenge_response = {1, 2, 3, 4},
	})

	T(response)["~="](nil)
	T(client.state)["=="](handshake.STATE.CONNECTED)
	T(client.peer_id)["=="](99999)
end)

T.Test("Client: HandleConnectReject transitions to DISCONNECTED", function()
	local client = handshake.CreatePeerState()
	client:SetState(handshake.STATE.CONNECTING)

	local result = client:HandleConnectReject({error = "Bad password"})
	T(result)["~="](nil)
	T(result.error)["=="]("Bad password")
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Client: HandleConnectTimeout retries if under limit", function()
	local client = handshake.CreatePeerState()
	client:SetState(handshake.STATE.CONNECTING)
	client.connect_attempts = 1 -- Already tried once

	local result = client:HandleConnectTimeout()
	T(result)["~="](nil)
	T(result.type)["=="](handshake.PACKET_TYPE.CONNECT_REQUEST)
	T(client.connect_attempts)["=="](2)
	T(client.state)["=="](handshake.STATE.CONNECTING)
end)

T.Test("Client: HandleConnectTimeout gives up after max retries", function()
	local client = handshake.CreatePeerState()
	client:SetState(handshake.STATE.CONNECTING)
	client.connect_attempts = handshake.DEFAULT_CONFIG.max_retries

	local result = client:HandleConnectTimeout()
	T(result)["~="](nil)
	T(result.error)["~="](nil)
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Client: HandleConnectTimeout from wrong state returns error", function()
	local client = handshake.CreatePeerState()
	local result, error = client:HandleConnectTimeout()
	T(result)["=="](nil)
	T(error)["~="](nil)
end)

T.Test("Both: SendDisconnect transitions to DISCONNECTING", function()
	local peer = handshake.CreatePeerState()
	peer:SetState(handshake.STATE.CONNECTED)

	local packet = peer:SendDisconnect("leaving")
	T(packet)["~="](nil)
	T(packet.type)["=="](handshake.PACKET_TYPE.DISCONNECT)
	T(packet.reason)["=="]("leaving")
	T(peer.state)["=="](handshake.STATE.DISCONNECTING)
end)

T.Test("Both: HandleDisconnect from CONNECTED goes to DISCONNECTED", function()
	local peer = handshake.CreatePeerState()
	peer:SetState(handshake.STATE.CONNECTED)

	local result = peer:HandleDisconnect({reason = "peer_request"})
	T(result)["~="](nil)
	T(result.reason)["=="]("peer_request")
	T(peer.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Both: HandleDisconnect from DISCONNECTING completes", function()
	local peer = handshake.CreatePeerState()
	peer:SetState(handshake.STATE.DISCONNECTING)

	local result = peer:HandleDisconnect({})
	T(result)["~="](nil)
	T(result.completed)["=="](true)
	T(peer.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("Full handshake: Client → Server → Client → Disconnect", function()
	-- Client starts
	local client = handshake.CreatePeerState()
	T(client.state)["=="](handshake.STATE.DISCONNECTED)

	-- Client sends connect request
	local client_request = client:SendConnectRequest({ip = "127.0.0.1", port = 9000}, 111)
	T(client.state)["=="](handshake.STATE.CONNECTING)

	-- Server receives and accepts
	local server = handshake.CreatePeerState()
	server.peer_id = 222
	local server_response = server:HandleConnectRequest({ip = "127.0.0.1", port = 9000}, client_request)
	T(server.state)["=="](handshake.STATE.CONNECTED)

	-- Client receives accept
	local confirm = client:HandleConnectAccept(server_response)
	T(client.state)["=="](handshake.STATE.CONNECTED)

	-- Both are now connected
	T(client.state)["=="](handshake.STATE.CONNECTED)
	T(server.state)["=="](handshake.STATE.CONNECTED)

	-- Client disconnects
	local disconnect_packet = client:SendDisconnect("done")
	T(client.state)["=="](handshake.STATE.DISCONNECTING)

	-- Server receives disconnect
	local result = server:HandleDisconnect(disconnect_packet)
	T(server.state)["=="](handshake.STATE.DISCONNECTED)

	-- Client receives disconnect confirmation
	local client_result = client:HandleDisconnect(disconnect_packet)
	T(client.state)["=="](handshake.STATE.DISCONNECTED)
end)

T.Test("PeerState:IsTimedOut returns false when not connecting", function()
	local peer = handshake.CreatePeerState()
	T(peer:IsTimedOut())["=="](false)
end)

T.Test("PeerState:ShouldRetry returns true initially", function()
	local peer = handshake.CreatePeerState()
	peer:SetState(handshake.STATE.CONNECTING)
	T(peer:ShouldRetry())["=="](true)
end)

T.Test("PeerState:ShouldRetry returns false after max retries", function()
	local peer = handshake.CreatePeerState()
	peer.connect_attempts = handshake.DEFAULT_CONFIG.max_retries
	T(peer:ShouldRetry())["=="](false)
end)

return {}
