local ljsocket = import("goluwa/bindings/socket.lua")
local prototype = import("goluwa/prototype.lua")
local repl = import("goluwa/repl.lua")
local socket_pool = import("goluwa/sockets/socket_pool.lua")
local TCPClient = import("goluwa/sockets/tcp_client.lua")
local UDPServer = prototype.CreateTemplate("socket_tcp_server")

function UDPServer:assert(val, err)
	if not val then self:Error(err) end

	return val, err
end

function UDPServer:__tostring2()
	return "[" .. tostring(self.socket) .. "]"
end

function UDPServer:InsertIntoSocketPool()
	if self.in_socket_pool then return end

	socket_pool:insert(self)
	self.in_socket_pool = true
end

function UDPServer:RemoveFromSocketPool()
	if not self.in_socket_pool then return end

	socket_pool:remove(self)
	self.in_socket_pool = nil
end

function UDPServer:Initialize(socket)
	self:SocketRestart(socket)
end

function UDPServer:SocketRestart()
	self.socket = ljsocket.create("inet", "stream", "tcp")
	self:assert(self.socket:set_blocking(false))
	self.socket:set_option("nodelay", true, "tcp")
	self.socket:set_option("reuseaddr", true)
	self.connected = nil
	self.connecting = nil
end

function UDPServer:OnRemove()
	self:RemoveFromSocketPool()
	self:assert(self.socket:close())
end

function UDPServer:Close(reason)
	if reason then print(reason) end

	self:Remove()
end

function UDPServer:Host(host, service)
	local ok, err = self.socket:bind(host, service)

	if not ok then
		return self:Error("Unable to bind " .. host .. ":" .. service .. " - " .. err)
	end

	ok, err = self.socket:listen()

	if not ok then
		return self:Error("Unable to listen on " .. host .. ":" .. service .. " - " .. err)
	end

	self.hosting = true
	self:InsertIntoSocketPool()
	return true
end

function UDPServer:GetPollSocket()
	return self.socket
end

function UDPServer:GetPollFlags()
	if self.hosting then return {"in"} end

	error(tostring(self) .. " is in socket pool without an active poll state")
end

function UDPServer:OnPollReady(events)
	if not self.hosting then return end

	if not (events["in"] or events.err or events.hup or events.nval) then return end

	if not self.hosting then return end

	for i = 1, 512 do
		local client, err = self.socket:accept()

		if err ~= "tryagain" then
			if client then
				local client = TCPClient.New(client)
				client.connected = true
				client:InsertIntoSocketPool()
				self:OnClientConnected(client)
			else
				self:Error(err)

				break
			end
		end
	end
end

function UDPServer:Update()
	self:OnPollReady{
		["in"] = true,
		err = true,
		hup = true,
		nval = true,
	}
end

function UDPServer:Error(message, ...)
	self:OnError(message, ...)
	return false, message
end

function UDPServer:OnError(str, tr)
	self:Remove()
	error(str)
end

function UDPServer:OnReceiveChunk(str) end

function UDPServer:OnClose()
	self:Close()
end

function UDPServer:OnConnect() end

function UDPServer.New()
	local self = UDPServer:CreateObject()
	self:Initialize()
	return self
end

return UDPServer:Register()