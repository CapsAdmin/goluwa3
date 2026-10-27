local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local UDPClient = import("goluwa/sockets/udp_client.lua")
local UDPServer = import("goluwa/sockets/udp_server.lua")
local connection = import("goluwa/network/connection.lua")
local packet_header = import("goluwa/network/packet_header.lua")
local handshake = import("goluwa/network/handshake.lua")
local ljsocket = import("goluwa/bindings/socket.lua")
local threads = import("goluwa/bindings/threads.lua")
local get_time = import("goluwa/bindings/time.lua")
local transport_layer = {}
transport_layer.sockets = transport_layer.sockets or {}
transport_layer.servers = transport_layer.servers or {}
transport_layer.received = transport_layer.received or {}
transport_layer.SOCKET_BUFFER_CAP = 32 * 1024 * 1024

function transport_layer.Initialize() end

function transport_layer.MaximizeSocketBuffers(socket)
	return socket:maximize_buffer("rcvbuf", transport_layer.SOCKET_BUFFER_CAP),
	socket:maximize_buffer("sndbuf", transport_layer.SOCKET_BUFFER_CAP)
end

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
	local received = transport_layer.received

	if received[1] then
		transport_layer.received = {}

		for i = 1, #received, 3 do
			local obj = received[i]

			if obj:IsValid() then obj:OnReceiveChunk(received[i + 1], received[i + 2]) end
		end
	end

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

function transport_layer.Flush()
	local sockets = transport_layer.sockets

	for i = #sockets, 1, -1 do
		local peer = sockets[i]

		if peer and peer.conn then peer.conn:Flush() end
	end
end

function transport_layer.Wait(seconds)
	local entries = {}

	for _, peer in ipairs(transport_layer.sockets) do
		if peer.client_socket then
			entries[#entries + 1] = {peer.client_socket.socket, {"in"}, peer.client_socket}
		end
	end

	for _, server in ipairs(transport_layer.servers) do
		entries[#entries + 1] = {server.socket, {"in"}, server}
	end

	if not entries[1] then return false end

	local deadline = get_time() + seconds
	local received = transport_layer.received

	while true do
		local ms = math.floor((deadline - get_time()) * 1000)

		if ms <= 0 then break end

		local results = ljsocket.poll(entries, ms)

		if not results then
			threads.sleep(math.max(deadline - get_time(), 0) * 1000)
			return true
		end

		for _, result in ipairs(results) do
			if not result.events["in"] then
				threads.sleep(math.max(deadline - get_time(), 0) * 1000)
				return true
			end

			local obj = result.entry[3]

			for _ = 1, 16384 do
				local chunk, address = obj.socket:receive_from(2048)

				if not chunk then break end

				local n = #received
				received[n + 1] = obj
				received[n + 2] = chunk
				received[n + 3] = address
				obj:ReceiveAcks(chunk, address)
			end
		end

		transport_layer.Flush()
	end

	return true
end

event.AddListener("Update", "transport_layer", transport_layer.Update)
event.AddListener("PostUpdate", "transport_layer", transport_layer.Flush, {priority = -100})
event.AddListener("FrameSleep", "transport_layer", transport_layer.Wait)

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
		self.receive_buffer_size, self.send_buffer_size = transport_layer.MaximizeSocketBuffers(self.client_socket.socket)
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
		self.client_socket.ReceiveAcks = function(_, chunk)
			if self.conn then self.conn:ReceiveAcks(chunk) end
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
	local IsDatagram = packet_header.IsDatagram
	local DecodeRecord = packet_header.DecodeRecord
	local FIRST_RECORD = packet_header.PrefixSize + 1

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
			if not IsDatagram(chunk) then return end

			local type_, _, _, _, _, _, start = DecodeRecord(chunk, FIRST_RECORD)

			if type_ ~= TYPE_CONNECT or chunk:byte(start) ~= REQUEST then return end

			peer = self:CreatePeer(key, address)
		end

		peer.conn:Receive(chunk)
	end

	function PeerServer:ReceiveAcks(chunk, address)
		local addrinfo = address.addrinfo
		local peer = self.peers[ffi_string(addrinfo.ai_addr, addrinfo.ai_addrlen)]

		if peer then peer.conn:ReceiveAcks(chunk) end
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
		server.receive_buffer_size, server.send_buffer_size = transport_layer.MaximizeSocketBuffers(server.socket)
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
