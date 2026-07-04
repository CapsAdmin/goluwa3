local objects = import("goluwa/objects/objects.lua")
local UDPClient = import("goluwa/sockets/udp_client.lua")
local UDPServer = import("goluwa/sockets/udp_server.lua")
local transport_layer = {}
transport_layer.sockets = transport_layer.sockets or {}
transport_layer.servers = transport_layer.servers or {}

function transport_layer.Initialize() end

function transport_layer.Update()
	for _, server in ipairs(transport_layer.servers) do
		if server:IsValid() then
			server:Update()

			-- Update ping on all connected peers (RTT not yet measured, set to 0)
			for _, peer in pairs(server.peers) do
				if peer:IsValid() then peer:SetPing(0) end
			end
		end
	end
end

do -- peer template
	local CLIENT = objects.CreateTemplate("enet_peer")
	-- Ping property (RTT not yet measured, defaults to 0)
	CLIENT.ping = 0

	function CLIENT:SetPing(val)
		self.ping = val
	end

	function CLIENT:GetPing()
		return self.ping
	end

	function CLIENT:Connect(ip, port, channels)
		if not self.socket then
			self.socket = UDPClient.New()
			self.socket:SetAddress(ip, port)
			-- Wire up receive callback to forward to peer
			local peer = self

			function self.socket:OnReceiveChunk(chunk, address)
				peer:OnReceiveChunk(chunk, address)
			end
		end

		self.connected = true
		self.address = {ip = ip, port = port}
	end

	function CLIENT:Disconnect(code)
		self.connected = false

		if self.socket then
			self.socket:Close("disconnect")
			self.socket = nil
		end
	end

	function CLIENT:Remove()
		if self.socket then
			if self.socket.OnRemove then
				self.socket:OnRemove()
			else
				self.socket:close()
			end

			self.socket = nil
		end

		self.connected = false
	end

	function CLIENT:Send(str, flags, channel)
		if not self.socket or not self.address then return end

		self.socket:Send(str, self.address.ip, self.address.port)
	end

	function CLIENT:OnReceiveChunk(chunk, address)
		if self.OnReceive then
			self:OnReceive(chunk, "data")
		end
	end

	function CLIENT:GetIP()
		return self.address and self.address.ip or "0.0.0.0"
	end

	function CLIENT:GetPort()
		return self.address and self.address.port or 0
	end

	function CLIENT:IsConnected()
		return self.connected == true
	end

	function CLIENT:IsValid()
		return self.connected == true
	end

	function CLIENT:OnConnect() end

	function CLIENT:OnDisconnect() end

	function CLIENT:OnReceive(str, flags, channel) end

	CLIENT.peer = CLIENT.peer or {}
	CLIENT.peer.roundTripTime = 0
	CLIENT.connected = false

	function transport_layer.CreatePeer(ip, port, max_connections, max_channels, incomming_bandwidth, outgoing_bandwidth)
		local self = CLIENT:CreateObject()
		self:Connect(ip, port)
		list.insert(transport_layer.sockets, self)
		return self
	end

	function transport_layer.CreateDummyPeer()
		local self = CLIENT:CreateObject()
		self.connected = true
		return self
	end

	objects.Register(CLIENT)
end

do -- server template
	local SERVER = objects.CreateTemplate("enet_server")

	function SERVER:OnReceive(peer, str, flags, channel) end

	function SERVER:OnPeerConnect(peer) end

	function SERVER:OnPeerDisconnect(peer, code) end

	objects.Register(SERVER)

	function transport_layer.CreateServer(ip, port, max_connections, max_channels, incomming_bandwidth, outgoing_bandwidth)
		local server = UDPServer.New()
		server.peers = {}
		server:SetAddress(ip, port)
		-- Bind the socket to the address
		server.socket:bind(ip, port)

		-- Attach transport layer methods to the server instance
		function server:GetPeers()
			local result = {}

			for _, peer in pairs(self.peers) do
				if peer:IsValid() then table.insert(result, peer) end
			end

			return result
		end

		function server:Broadcast(str, flags, channel)
			for _, peer in pairs(self.peers) do
				if peer:IsValid() and peer.socket then
					peer.socket:Send(str, peer.address.ip, peer.address.port)
				end
			end
		end

		function server:Remove()
			for _, peer in pairs(self.peers) do
				if peer:IsValid() then
					peer:OnDisconnect()
					peer:Remove()
				end
			end

			self.peers = {}

			if self.socket then
				-- server.socket is a raw socket, not a UDPServer. Remove from pool directly.
				local socket_pool = import("goluwa/sockets/socket_pool.lua")
				socket_pool:remove(self)
				self.socket:close()
				self.socket = nil
			end

			-- Remove from transport_layer.servers
			for i, s in ipairs(transport_layer.servers) do
				if s == self then
					table.remove(transport_layer.servers, i)

					break
				end
			end
		end

		function server:IsValid()
			return self.socket ~= nil
		end

		function server:OnReceive(peer, str, flags, channel) end

		function server:OnPeerConnect(peer) end

		function server:OnPeerDisconnect(peer, code) end

		-- Override OnReceiveChunk to dispatch to peers
		local original_on_receive_chunk = server.OnReceiveChunk

		function server:OnReceiveChunk(chunk, address)
			if not address then return end

			local key = address:get_ip() .. ":" .. tostring(address:get_port())

			if not self.peers[key] then
				local peer_meta = objects.GetRegistered("enet_peer")

				if not peer_meta then
					wlog("transport_layer: enet_peer template not registered, skipping peer creation")
					return
				end

				local peer = objects.CreateObject(peer_meta)
				peer.address = {ip = address:get_ip(), port = address:get_port()}
				peer.connected = true

				-- Create a UDP socket for this peer so we can send data back
				peer.socket = UDPClient.New()
				peer.socket:SetAddress(peer.address.ip, peer.address.port)
				list.insert(transport_layer.sockets, peer)

				self.peers[key] = peer
				llog("[transport] Created peer for %s:%d", peer.address.ip, peer.address.port)
				self:OnPeerConnect(peer)
			end

			local peer = self.peers[key]

			if peer and peer:IsValid() then self:OnReceive(peer, chunk, 0, 0) end

			if original_on_receive_chunk then
				original_on_receive_chunk(self, chunk, address)
			end
		end

		table.insert(transport_layer.servers, server)
		return server
	end
end

return transport_layer
