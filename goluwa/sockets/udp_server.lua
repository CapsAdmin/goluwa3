local ljsocket = require("bindings.socket")
local prototype = require("prototype")
local socket_pool = require("sockets.socket_pool")
local UDPServer = prototype.CreateTemplate("socket_udp_server")

function UDPServer:assert(val, err)
	if not val then self:Error(err) end

	return val, err
end

function UDPServer:__tostring2()
	return "[" .. tostring(self.socket) .. "]"
end

function UDPServer:Initialize(socket)
	self:SocketRestart(socket)
	socket_pool:insert(self)
end

function UDPServer:SocketRestart(socket)
	self.socket = socket or ljsocket.create("inet", "dgram", "udp")

	if not self:assert(self.socket:set_blocking(false)) then return end
end

function UDPServer:OnRemove()
	socket_pool:remove(self)
	self.socket:close()
end

function UDPServer:Close(reason)
	self:Remove()
end

function UDPServer:SetAddress(host, port)
	self.address = ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp")
end

function UDPServer:Send(data, host, port)
	local address = self.address

	if host then
		address = ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp")
	end

	return self.socket:send_to(address, data)
end

function UDPServer:Update()
	local chunk, err = self.socket:receive_from(self.address)

	if chunk then
		self:OnReceiveChunk(chunk, err)
	else
		if err == "closed" then
			self:OnClose("receive")
		elseif err ~= "timeout" then
			self:Error(err)
		end
	end
end

function UDPServer:Error(message, ...)
	local tr = debug.traceback()
	self:OnError(message, tr, ...)
	return false
end

function UDPServer:OnReceiveChunk(chunk, address) end

function UDPServer.New(socket)
	local self = UDPServer:CreateObject()
	self:Initialize(socket)
	return self
end

return UDPServer:Register()