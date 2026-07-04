local objects = import("goluwa/objects/objects.lua")
local transport_layer = {}
transport_layer.sockets = transport_layer.sockets or {}

function transport_layer.Initialize() -- mock: no real transport_layer library
end

do -- peer template
	local CLIENT = objects.CreateTemplate("enet_peer")

	function CLIENT:Connect(ip, port, channels) end

	function CLIENT:Disconnect(code) end

	function CLIENT:Remove() end

	function CLIENT:Send(str, flags, channel) end

	function CLIENT:GetIP()
		return "127.0.0.1"
	end

	function CLIENT:GetPort()
		return 0
	end

	function CLIENT:IsConnected()
		return true
	end

	function CLIENT:IsValid()
		return true
	end

	function CLIENT:OnConnect() end

	function CLIENT:OnDisconnect() end

	function CLIENT:OnReceive(str, flags, channel) end

	CLIENT.peer = CLIENT.peer or {}
	CLIENT.peer.roundTripTime = 0
	CLIENT.connected = true

	function transport_layer.CreatePeer(ip, port, max_connections, max_channels, incomming_bandwidth, outgoing_bandwidth)
		local self = CLIENT:CreateObject()
		list.insert(transport_layer.sockets, self)
		return self
	end

	function transport_layer.CreateDummyPeer()
		return CLIENT:CreateObject()
	end

	objects.Register(CLIENT)
end

do -- server template
	local SERVER = objects.CreateTemplate("enet_server")

	function SERVER:GetPeers()
		return {}
	end

	function SERVER:Broadcast(str, flags, channel) end

	function SERVER:Remove() end

	function SERVER:IsValid()
		return true
	end

	function SERVER:OnReceive(peer, str, flags, channel) end

	function SERVER:OnPeerConnect(peer) end

	function SERVER:OnPeerDisconnect(peer, code) end

	function transport_layer.CreateServer(ip, port, max_connections, max_channels, incomming_bandwidth, outgoing_bandwidth)
		local self = SERVER:CreateObject()
		list.insert(transport_layer.sockets, self)
		return self
	end

	objects.Register(SERVER)
end

return transport_layer
