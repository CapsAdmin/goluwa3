local T = import("test/environment.lua")
_G.CLIENT = true
_G.SERVER = true
local transport_layer = import("goluwa/network/transport_layer.lua")

T.Test("UDP transport layer creates server and peer", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27015)
	T(server:IsValid())["=="](true)
	T(server:GetPeers())["~="](nil)
	local peer = transport_layer.CreatePeer("127.0.0.1", 27015)
	T(peer:IsValid())["=="](true)
	T(peer:IsConnected())["=="](true)
	T(peer:GetIP())["=="]("127.0.0.1")
	T(peer:GetPort())["=="](27015)
	server:Remove()
	peer:Remove()
end)

T.Test("UDP transport layer sends and receives data", function()
	local received_data = nil
	local server = transport_layer.CreateServer("0.0.0.0", 27016)

	function server:OnReceive(peer, str, flags, channel)
		received_data = str
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27016)
	client:Send("hello world", 0, 0)

	for _ = 1, 5 do
		transport_layer.Update()
	end

	T(received_data)["=="]("hello world")
	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer tracks connected peers", function()
	local peer_count = 0
	local server = transport_layer.CreateServer("0.0.0.0", 27017)

	function server:OnPeerConnect(peer)
		peer_count = peer_count + 1
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27017)
	client:Send("test", 0, 0)

	for _ = 1, 5 do
		transport_layer.Update()
	end

	T(peer_count)["=="](1)
	T(#server:GetPeers())["=="](1)
	local peers = server:GetPeers()
	T(peers[1]:IsValid())["=="](true)
	T(peers[1]:GetIP())["~="](nil)
	server:Remove()
	client:Remove()
end)

T.Test("UDP transport layer broadcast to all peers", function()
	local received_messages = {}
	local server = transport_layer.CreateServer("0.0.0.0", 27018)

	function server:OnReceive(peer, str, flags, channel)
		table.insert(received_messages, str)
	end

	local client1 = transport_layer.CreatePeer("127.0.0.1", 27018)
	local client2 = transport_layer.CreatePeer("127.0.0.1", 27018)
	client1:Send("from client 1", 0, 0)
	client2:Send("from client 2", 0, 0)

	for _ = 1, 5 do
		transport_layer.Update()
	end

	T(#received_messages)["=="](2)
	server:Remove()
	client1:Remove()
	client2:Remove()
end)

T.Test("UDP transport layer peer cleanup", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27019)
	local peer = transport_layer.CreatePeer("127.0.0.1", 27019)
	T(peer:IsValid())["=="](true)
	peer:Remove()
	T(peer:IsValid())["=="](false)
	T(peer:IsConnected())["=="](false)
	server:Remove()
end)

T.Test("UDP transport layer server cleanup removes peers", function()
	local server = transport_layer.CreateServer("0.0.0.0", 27020)
	local peer1 = transport_layer.CreatePeer("127.0.0.1", 27020)
	local peer2 = transport_layer.CreatePeer("127.0.0.1", 27020)
	peer1:Send("test1", 0, 0)
	peer2:Send("test2", 0, 0)

	for _ = 1, 5 do
		transport_layer.Update()
	end

	T(#server:GetPeers())["=="](2)
	server:Remove()
	T(server:IsValid())["=="](false)
	T(#server:GetPeers())["=="](0)
	T(peer1:IsValid())["=="](true)
	T(peer2:IsValid())["=="](true)
	peer1:Remove()
	peer2:Remove()
end)

T.Test("UDP transport layer multiple update cycles", function()
	local received = {}
	local server = transport_layer.CreateServer("0.0.0.0", 27021)

	function server:OnReceive(peer, str, flags, channel)
		table.insert(received, str)
	end

	local client = transport_layer.CreatePeer("127.0.0.1", 27021)
	client:Send("msg1", 0, 0)
	transport_layer.Update()
	client:Send("msg2", 0, 0)
	transport_layer.Update()
	client:Send("msg3", 0, 0)
	transport_layer.Update()
	T(#received)["=="](3)
	T(received[1])["=="]("msg1")
	T(received[2])["=="]("msg2")
	T(received[3])["=="]("msg3")
	server:Remove()
	client:Remove()
end)
