local T = import("test/environment.lua")
_G.CLIENT = true
_G.SERVER = true
local transport_layer = import("goluwa/network/transport_layer.lua")

local function pump(done, max)
	for _ = 1, max or 200 do
		transport_layer.Update()

		if done() then return true end
	end

	return done()
end

T.Test("UDP transport layer connects a peer to a server", function()
	local connected_peer
	local server = transport_layer.CreateServer("0.0.0.0", 27015)

	function server:OnPeerConnect(peer)
		connected_peer = peer
	end

	local peer = transport_layer.CreatePeer("127.0.0.1", 27015)
	T(peer:IsValid())["=="](true)
	T(peer:IsConnected())["=="](false)
	T(peer:GetIP())["=="]("127.0.0.1")
	T(peer:GetPort())["=="](27015)
	T(pump(function()
		return peer:IsConnected()
	end))["=="](true)
	T(connected_peer ~= nil)["=="](true)
	T(connected_peer:IsConnected())["=="](true)
	T(#server:GetPeers())["=="](1)
	server:Remove()
	peer:Remove()
end)

T.Test("UDP transport layer sends and receives data in both directions", function()
	local server_received, client_received, flags_seen
	local server = transport_layer.CreateServer("0.0.0.0", 27016)

	function server:OnReceive(peer, str, flags, channel)
		server_received = str
		flags_seen = flags
		peer:Send("pong", "reliable", 0)
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27016)

	function client:OnReceive(str)
		client_received = str
	end

	client:Send("hello world", "reliable", 0)
	T(pump(function()
		return client_received
	end))["=="](true)
	T(server_received)["=="]("hello world")
	T(flags_seen)["=="]("reliable")
	T(client_received)["=="]("pong")
	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer delivers many messages in order", function()
	local received = {}
	local server = transport_layer.CreateServer("0.0.0.0", 27017)

	function server:OnReceive(peer, str)
		table.insert(received, str)
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27017)

	for i = 1, 300 do
		client:Send("msg" .. i, "reliable", 0)
	end

	T(pump(function()
		return #received == 300
	end))["=="](true)

	for i = 1, 300 do
		T(received[i])["=="]("msg" .. i)
	end

	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer sends large reliable messages", function()
	local received
	local server = transport_layer.CreateServer("0.0.0.0", 27018)

	function server:OnReceive(peer, str)
		received = str
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27018)
	local big = string.rep("goluwa", 5000)
	client:Send(big, "reliable", 0)
	T(pump(function()
		return received
	end))["=="](true)
	T(received == big)["=="](true)
	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer tracks multiple peers and broadcasts", function()
	local received = {}
	local server = transport_layer.CreateServer("0.0.0.0", 27019)
	local client1 = transport_layer.CreatePeer("127.0.0.1", 27019)
	local client2 = transport_layer.CreatePeer("127.0.0.1", 27019)

	function client1:OnReceive(str)
		received[1] = str
	end

	function client2:OnReceive(str)
		received[2] = str
	end

	T(
		pump(function()
			return #server:GetPeers() == 2 and client1:IsConnected() and client2:IsConnected()
		end)
	)["=="](true)
	server:Broadcast("everyone", "reliable", 0)
	T(pump(function()
		return received[1] and received[2]
	end))["=="](true)
	T(received[1])["=="]("everyone")
	T(received[2])["=="]("everyone")
	server:Remove()
	client1:Remove()
	client2:Remove()
end)

T.Test("UDP transport layer notifies disconnects on both ends", function()
	local server_disconnect, client_disconnect
	local server = transport_layer.CreateServer("0.0.0.0", 27020)

	function server:OnPeerDisconnect(peer, code)
		server_disconnect = code
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27020)

	function client:OnDisconnect(code)
		client_disconnect = code
	end

	T(pump(function()
		return client:IsConnected()
	end))["=="](true)
	server:GetPeers()[1]:Disconnect(5)
	T(pump(function()
		return client_disconnect
	end))["=="](true)
	T(client_disconnect)["=="](5)
	T(server_disconnect)["=="](5)
	T(#server:GetPeers())["=="](0)
	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer peer cleanup", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27021)
	local peer = transport_layer.CreatePeer("127.0.0.1", 27021)
	T(pump(function()
		return peer:IsConnected()
	end))["=="](true)
	peer:Remove()
	T(peer:IsValid())["=="](false)
	T(peer:IsConnected())["=="](false)
	T(pump(function()
		return #server:GetPeers() == 0
	end))["=="](true)
	server:Remove()
end)

T.Test("UDP transport layer ignores garbage from strangers", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27022)
	local UDPClient = import("goluwa/sockets/udp_client.lua")
	local raw = UDPClient.New()
	raw:SetAddress("127.0.0.1", 27022)
	raw:Send("not a goluwa packet")
	raw:Send(import("goluwa/network/packet_header.lua").Encode(0, 0, 0, 0, 1, 1, "data without handshake"))

	for _ = 1, 20 do
		transport_layer.Update()
	end

	T(#server:GetPeers())["=="](0)
	raw:Remove()
	server:Remove()
end)

T.Test("UDP transport layer server cleanup removes peers", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27023)
	local peer1 = transport_layer.CreatePeer("127.0.0.1", 27023)
	local peer2 = transport_layer.CreatePeer("127.0.0.1", 27023)
	T(pump(function()
		return #server:GetPeers() == 2
	end))["=="](true)
	server:Remove()
	T(server:IsValid())["=="](false)
	T(#server:GetPeers())["=="](0)
	T(
		pump(function()
			return not peer1:IsConnected() and not peer2:IsConnected()
		end)
	)["=="](true)
	peer1:Remove()
	peer2:Remove()
end)
