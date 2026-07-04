local network = library()
import.loaded["goluwa/network/network.lua"] = network
local transport_layer = import("goluwa/network/transport_layer.lua")
local clients = import("goluwa/network/clients.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local commands = import("goluwa/cli/commands.lua")
local pvars = import("goluwa/cli/pvars.lua")
local codec = import("goluwa/codec.lua")
local http = import("goluwa/sockets/http.lua")
local IRCClient = import("goluwa/sockets/irc.lua")
local nvars
network.socket = network.socket or NULL

local function get_nvars()
	if not nvars then nvars = import("goluwa/network/nvars.lua") end

	return nvars
end

function network.Initialize()
	transport_layer.Initialize()
end

function network.IsStarted()
	return network.socket:IsValid()
end

if CLIENT then
	function network.Connect(ip, port, retries)
		network.Disconnect("already connected")
		ip = tostring(ip)
		port = tonumber(port)
		retries = retries or 3

		if retries > 0 then
			timer.Delay(3, function()
				if not network.IsConnected() then
					if network.debug then
						llog("retrying %s:%s (%i retries left)..", ip, port, retries)
					end

					network.Connect(ip, port, retries - 1)
				end
			end)
		end

		local peer = transport_layer.CreatePeer(ip, port)

		function peer:OnReceive(str, type)
			event.Call("PeerReceivePacket", str, nil, type)
		end

		network.socket = peer
		network.just_disconnected = nil
		event.Call("NetworkStarted")
		return peer
	end

	function network.Disconnect()
		if network.IsConnected() then
			network.socket:Disconnect(1)
			network.socket:Remove()
			llog("disconnected from server")
			network.just_disconnected = true
			network.started = false
			event.Call("Disconnected")
		end
	end

	event.AddListener("ShutDown", network.Disconnect)

	function network.IsConnected()
		if network.just_disconnected then return false end

		return network.socket:IsValid() and network.socket:IsConnected()
	end

	function network.SendPacketToHost(str, flags, channel)
		if network.socket:IsValid() then
			network.socket:Send(str, flags, channel)
		end
	end
end

if SERVER then
	function network.Host(ip, port)
		ip = tostring(ip)
		port = tonumber(port)
		network.port = port

		if network.IsHosting() then
			network.CloseServer("already hosting")

			timer.Delay(1, function()
				network.Host(ip, port)
			end)

			return
		end

		if not transport_layer then
			wlog("unable to host server: transport_layer not found")
			return
		end

		local server = transport_layer.CreateServer(ip, port)

		function server:OnReceive(peer, str, type)
			event.Call("PeerReceivePacket", str, peer, type)
		end

		function server:OnPeerConnect(peer)
			event.Call("PeerConnect", peer)
		end

		function server:OnPeerDisconnect(peer, code)
			event.Call("PeerDisconnect", peer, code)
		end

		network.socket = server
		event.Call("NetworkStarted")
	end

	function network.CloseServer(reason)
		llog("server shutdown (%s)", reason or "unknown reason")
		network.socket:Remove()
	end

	function network.IsHosting()
		return network.socket:IsValid()
	end

	function network.GetPeers()
		return network.socket:GetPeers()
	end

	function network.SendPacketToPeer(peer, str, flags, channel)
		if peer and type(peer.IsValid) == "function" and peer:IsValid() then
			peer:Send(str, flags, channel)
		end
	end

	function network.BroadcastPacket(str)
		for _, peer in pairs(network.GetPeers()) do
			network.SendPacketToPeer(peer, str)
		end
	end
end

do
	local function ipport_to_uid(peer)
		if peer.address then
			return peer.address.ip .. ":" .. peer.address.port
		end

		return tostring(peer)
	end

	event.AddListener("PeerReceivePacket", "network", function(str, peer, type)
		local client = NULL

		if peer then
			local uid = ipport_to_uid(peer)
			client = clients.GetByUniqueID(uid)
		end

		if network.debug == 2 then
			llog("received %s packet (%s) from %s", type, utility.FormatFileSize(#str), peer)
		end

		if SERVER and not client:IsValid() then error("client is NULL") end

		event.Call("NetworkPacketReceived", str, client, type)
	end)

	-- TODO
	function network.PingServer(ip, cb)
		local lol = io.popen("ping " .. ip .. (WINDOWS and "-n 1" or " -c 1"))

		timer.Thinker(function()
			local str = lol:read("*all")
			local time = str:match("time=(%S+)")
			cb(tonumber(time) / 100)
			return false
		end)
	end

	if SERVER then
		event.AddListener("PeerDisconnect", "network", function(peer, code)
			local uid = ipport_to_uid(peer)
			local client = clients.GetByUniqueID(uid)

			if client:IsValid() then
				client:Disconnect(code)
				client:Remove()
			end
		end)

		event.AddListener("PeerConnect", "network", function(peer)
			local uid = ipport_to_uid(peer)
			local client = clients.Create(uid, false, false) -- create the client serverside for now
			client.socket = peer

			if network.debug then llog("client %s connected", client) end

			if event.Call("ClientConnect", client) ~= false then
				get_nvars().Synchronize(client, function(client)
					if network.debug then
						llog("client %s done synchronizing nvars", client)
					end

					for _, other in ipairs(clients.GetAll()) do
						if other ~= client then
							-- tell this client about all the clients on the server
							clients.Create(other:GetUniqueID(), other:IsBot(), true, client, false, true)
							-- tell all the other clients that this client entered
							clients.Create(client:GetUniqueID(), client:IsBot(), true, other, false, false)
						end
					end

					-- tell this client that we entered
					clients.Create(client:GetUniqueID(), client:IsBot(), true, client, true, false)
					event.Call("ClientEntered", client)
				end)
			end
		end)
	end

	do -- string table
		if SERVER then
			local i = 0

			function network.AddString(str)
				if not network.IsStarted() then
					timer.Delay(0.1, function()
						network.AddString(str)
					end)

					return 0
				end

				-- this is mainly used by the messsage which uses the packet library internally
				-- which in turn needs network.AddString
				-- -1 is reserved for the message library
				if type(str) == "number" then return str end

				local id = get_nvars().Get(str, nil, "string_table1")

				if id then return id end

				i = i + 1
				get_nvars().Set(str, i, "string_table1")
				get_nvars().Set(i, str, "string_table2")
				return i
			end
		end

		function network.StringToID(str)
			if type(str) == "number" then return str end

			return get_nvars().Get(str, nil, "string_table1")
		end

		function network.IDToString(id)
			if id < 0 then return id end

			return get_nvars().Get(id, nil, "string_table2")
		end
	end

	function network.IsStarted()
		return network.socket:IsValid()
	end

	do
		network.irc_client = network.irc_client or NULL
		network.available_servers = network.available_servers or {}
		network.serverbrowser_hostname = "chat.freenode.net"
		network.serverbrowser_channel = "#goluwa"
		network.serverbrowser_port = 6667

		function network.SetHostName(str)
			get_nvars().Set("hostname", str)
		end

		function network.GetHostname()
			return get_nvars().Get("hostname", e.USERNAME .. "'s server")
		end

		function network.GetAvailableServers()
			return network.available_servers
		end

		function network.JoinIRCServer(cb)
			if network.irc_client:IsValid() then
				if CLIENT then network.QueryAvailableServers(cb) end

				return
			end

			local client = IRCClient.New()

			if SERVER then
				http.Download("https://api.ipify.org/?format=plaintext"):Then(function(s)
					network.public_ip = s
					llog("public ip is %s", s)
				end)

				client:SetNick(client:GetNick() .. "_server")
				client.OnPrivateMessage = network.OnIRCMessage
				client.OnReady = function()
					logn("successfully joined irc channel")

					if cb then cb() end
				end
			end

			if CLIENT then
				client:SetNick(client:GetNick() .. "_client")
				client.OnPrivateMessage = network.OnIRCMessage
				client.OnJoin = function(s, nick)
					if nick:ends_with("_server") then
						client.asked[nick] = true
						client:PRIVMSG(nick .. " info")
					end
				end
				client.OnPart = function(s, nick, ip)
					if nick:ends_with("_server") then network.available_servers[ip] = nil end
				end
				client.OnReady = function()
					logn("successfully joined irc channel")
					network.QueryAvailableServers(cb)
				end
			end

			client:Connect(network.serverbrowser_hostname)
			client:Join(network.serverbrowser_channel, network.serverbrowser_port)
			llog("joining %s:%s", network.serverbrowser_hostname, network.serverbrowser_channel)
			network.irc_client = client
		end

		function network.QueryAvailableServers(cb)
			network.available_servers = {}
			local irc_client = network.irc_client

			if not irc_client:IsValid() then
				wlog("irc client not available")
				return
			end

			logn("fetching public servers...")
			irc_client.asked = {}
			local found = 0

			for user in pairs(network.irc_client:GetUsers()) do
				if user:ends_with("_server") then
					irc_client.asked[user] = true
					irc_client:PRIVMSG(user .. " info")
					found = found + 1
				end
			end

			if cb then cb(found) end
		end

		function network.OnIRCMessage(irc_client, message, nick, ip)
			if CLIENT then
				if irc_client.asked[nick] then
					local info = codec.Decode("msgpack", message)
					info.masked_ip = ip
					network.available_servers[ip] = info

					network.PingServer(info.ip, function(sec)
						info.latency = sec
						event.Call("PublicServerFound", info)
					end)
				end
			end

			if SERVER then
				if message == "info" then
					local players = {}

					for i, ply in ipairs(clients.GetAll()) do
						players[i] = ply:GetNick()
					end

					irc_client:PRIVMSG(
						nick .. " :" .. codec.Encode(
								"msgpack",
								{
									name = network.GetHostname(),
									port = network.port,
									players = players,
									scene_name = "none",
									ip = network.public_ip,
								}
							)
					)
				end
			end
		end
	end

	do
		local default_ip = "*"
		local default_port = 1234

		if CLIENT then
			local ip_cvar = pvars.Setup("cl_ip", default_ip)
			local port_cvar = pvars.Setup("cl_port", default_port)
			local last_ip
			local last_port

			commands.Add("retry", function()
				if last_ip then network.Connect(last_ip, last_port) end
			end)

			commands.Add("connect=string|nil,number|nil", function(ip, port)
				ip = ip or ip_cvar:Get()
				port = tonumber(port) or port_cvar:Get()
				logf("connecting to %s:%i\n", ip, port)
				last_ip = ip
				last_port = port
				network.Connect(ip, port)
			end)

			commands.Add("disconnect", function()
				network.Disconnect()
			end)
		end

		if SERVER then
			local ip_cvar = pvars.Setup("sv_ip", default_ip)
			local port_cvar = pvars.Setup("sv_port", default_port)

			commands.Add("host=string|nil,number|nil", function(ip, port)
				ip = ip or ip_cvar:Get()
				port = tonumber(port) or port_cvar:Get()
				logf("hosting at %s:%i\n", ip, port)
				network.Host(ip, port)
			end)
		end
	end
end

return network
