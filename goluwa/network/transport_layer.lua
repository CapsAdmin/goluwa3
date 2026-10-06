local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local UDPClient = import("goluwa/sockets/udp_client.lua")
local UDPServer = import("goluwa/sockets/udp_server.lua")
local connection = import("goluwa/network/connection.lua")
local packet_header = import("goluwa/network/packet_header.lua")
local handshake = import("goluwa/network/handshake.lua")
local transport_layer = {}
transport_layer.sockets = transport_layer.sockets or {}
transport_layer.servers = transport_layer.servers or {}

function transport_layer.Initialize() end

do
	local conditions = {
		latency = (tonumber(os.getenv("GOLUWA_NET_LATENCY")) or 0) / 1000,
		jitter = (tonumber(os.getenv("GOLUWA_NET_JITTER")) or 0) / 1000,
		loss = (tonumber(os.getenv("GOLUWA_NET_LOSS")) or 0) / 100,
	}
	local delayed = {}

	function transport_layer.SetConditions(latency_ms, jitter_ms, loss_percent)
		conditions.latency = latency_ms / 1000
		conditions.jitter = jitter_ms / 1000
		conditions.loss = loss_percent / 100
	end

	function transport_layer.SendWithConditions(send, str)
		if conditions.loss > 0 and math.random() < conditions.loss then return end

		if conditions.latency <= 0 and conditions.jitter <= 0 then return send(str) end

		delayed[#delayed + 1] = {
			connection.Now() + conditions.latency + math.random() * conditions.jitter,
			send,
			str,
		}
	end

	function transport_layer.FlushDelayed(now)
		local count = #delayed

		if count == 0 then return end

		local kept = 0

		for i = 1, count do
			local entry = delayed[i]
			delayed[i] = nil

			if entry[1] <= now then
				entry[2](entry[3])
			else
				kept = kept + 1
				delayed[kept] = entry
			end
		end
	end
end

local function remove_value(tbl, value)
	for i, v in ipairs(tbl) do
		if v == value then
			table.remove(tbl, i)
			return
		end
	end
end

function transport_layer.Update()
	local now = connection.Now()
	transport_layer.FlushDelayed(now)
	local sockets = transport_layer.sockets

	for i = #sockets, 1, -1 do
		local peer = sockets[i]

		if peer and peer.client_socket then peer.client_socket:Update() end
	end

	local servers = transport_layer.servers

	for i = #servers, 1, -1 do
		servers[i]:Update()
	end

	for i = #sockets, 1, -1 do
		local peer = sockets[i]

		if peer and peer.conn then peer.conn:Update(now) end
	end
end

event.AddListener("Update", "transport_layer", transport_layer.Update)

do
	local PeerClient = objects.CreateTemplate("peer_client")
	PeerClient.ping = 0

	function PeerClient:GetPing()
		return self.conn and self.conn.ping or 0
	end

	function PeerClient:SetPing(val)
		if self.conn then self.conn.ping = val end
	end

	function PeerClient:GetStats()
		return self.conn.stats
	end

	function PeerClient:IsConnected()
		return self.conn ~= nil and self.conn:IsConnected()
	end

	function PeerClient:IsValid()
		return self.conn ~= nil
	end

	function PeerClient:Send(str, flags, channel)
		if not self.conn then return end

		return self.conn:Send(str, flags, channel)
	end

	function PeerClient:Disconnect(code)
		if self.conn then self.conn:Disconnect(tonumber(code) or 1) end
	end

	function PeerClient:Remove()
		local conn = self.conn

		if not conn then return end

		conn:Disconnect(1)
		self.conn = nil
		remove_value(transport_layer.sockets, self)

		if self.client_socket then
			self.client_socket:Remove()
			self.client_socket = nil
		end

		if self.server then self.server.peers[self.key] = nil end
	end

	function PeerClient:GetIP()
		return self.address and self.address.ip or "0.0.0.0"
	end

	function PeerClient:GetPort()
		return self.address and self.address.port or 0
	end

	function PeerClient:OnConnect() end

	function PeerClient:OnDisconnect(code) end

	function PeerClient:OnReceive(str, flags, channel) end

	function PeerClient:SetupConnection(conn)
		local peer = self
		self.conn = conn
		conn.OnConnect = function()
			peer:OnConnect()
		end
		conn.OnDisconnect = function(_, code)
			peer:OnDisconnect(code)
		end
		conn.OnReceive = function(_, payload, flags, channel)
			peer:OnReceive(payload, flags, channel)
		end
	end

	function transport_layer.CreatePeer(ip, port)
		local self = PeerClient:CreateObject()
		self.address = {ip = ip, port = port}
		self.client_socket = UDPClient.New()
		self.client_socket:SetAddress(ip, port)
		local socket = self.client_socket

		local function raw_send(str)
			socket:Send(str)
		end

		self:SetupConnection(
			connection.New(function(str)
				transport_layer.SendWithConditions(raw_send, str)
			end, false)
		)
		self.client_socket.OnReceiveChunk = function(_, chunk)
			if self.conn then self.conn:Receive(chunk) end
		end
		self.conn:Connect()
		list.insert(transport_layer.sockets, self)
		return self
	end

	function transport_layer.CreateDummyPeer()
		local self = PeerClient:CreateObject()
		self:SetupConnection(connection.New(function() end, false))
		self.conn.state:SetState(handshake.STATE.CONNECTED)
		return self
	end

	objects.Register(PeerClient)
end

do
	local PeerServer = objects.CreateTemplate("peer_server")
	PeerServer.Base = UDPServer
	local PeerClient = objects.GetRegistered("peer_client")
	local ffi_string = ffi.string
	local TYPE_CONNECT = packet_header.TYPE_CONNECT
	local REQUEST = handshake.PACKET_TYPE.CONNECT_REQUEST

	function PeerServer:OnReceive(peer, str, flags, channel) end

	function PeerServer:OnPeerConnect(peer) end

	function PeerServer:OnPeerDisconnect(peer, code) end

	function PeerServer:Broadcast(str, flags, channel)
		for _, peer in pairs(self.peers) do
			peer:Send(str, flags, channel)
		end
	end

	function PeerServer:GetPeers()
		local result = {}

		for _, peer in pairs(self.peers) do
			if peer:IsValid() then table.insert(result, peer) end
		end

		return result
	end

	local socket_pool = import("goluwa/sockets/socket_pool.lua")

	function PeerServer:Remove()
		for _, peer in pairs(self.peers) do
			peer:Remove()
		end

		self.peers = {}

		if self.socket then
			socket_pool:remove(self)
			self.socket:close()
			self.socket = nil
		end

		remove_value(transport_layer.servers, self)
	end

	function PeerServer:CreatePeer(key, address)
		local server = self
		local peer = PeerClient:CreateObject()
		local ip = address:get_ip()
		local port = address:get_port()
		peer.address = {ip = ip, port = port}
		peer.server = self
		peer.key = key

		local function raw_send(str)
			if server.socket then server.socket:send_to(address, str) end
		end

		peer:SetupConnection(
			connection.New(function(str)
				transport_layer.SendWithConditions(raw_send, str)
			end, true)
		)
		peer.conn.OnConnect = function()
			server:OnPeerConnect(peer)
		end
		peer.conn.OnDisconnect = function(_, code)
			server:OnPeerDisconnect(peer, code)
			peer:Remove()
		end
		peer.conn.OnReceive = function(_, payload, flags, channel)
			server:OnReceive(peer, payload, flags, channel)
		end
		self.peers[key] = peer
		list.insert(transport_layer.sockets, peer)
		return peer
	end

	function PeerServer:OnReceiveChunk(chunk, address)
		if not address then return end

		local addrinfo = address.addrinfo
		local key = ffi_string(addrinfo.ai_addr, addrinfo.ai_addrlen)
		local peer = self.peers[key]

		if not peer then
			local type_, _, _, _, _, _, payload = packet_header.Decode(chunk)

			if type_ ~= TYPE_CONNECT or payload:byte(1) ~= REQUEST then return end

			peer = self:CreatePeer(key, address)
		end

		peer.conn:Receive(chunk)
	end

	function PeerServer:IsValid()
		return self.socket ~= nil
	end

	objects.Register(PeerServer)

	function transport_layer.CreateServer(ip, port)
		local server = PeerServer:CreateObject()
		server:Initialize()
		server.peers = {}
		server:SetAddress(ip, port)
		local ok, err = server.socket:bind(ip, port)

		if not ok then
			server:Remove()
			error(string.format("unable to host on %s:%s: %s", ip, port, tostring(err)), 0)
		end

		table.insert(transport_layer.servers, server)
		return server
	end
end

return transport_layer
