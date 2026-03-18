local ljsocket = import("goluwa/bindings/socket.lua")
local prototype = import("goluwa/prototype.lua")
local UDPClient = prototype.CreateTemplate("socket_udp_client")

function UDPClient:assert(val, err)
	if not val then self:Error(err) end

	return val, err
end

function UDPClient:__tostring2()
	return "[" .. tostring(self.socket) .. "]"
end

function UDPClient:Initialize(socket)
	self:SocketRestart(socket)
end

function UDPClient:SocketRestart(socket)
	self.socket = socket or ljsocket.create("inet", "dgram", "udp")
end

function UDPClient:OnRemove()
	self.socket:close()
end

function UDPClient:Close(reason)
	self:Remove()
end

function UDPClient:SetAddress(host, port)
	self.address = ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp")
end

function UDPClient:Send(data, host, port)
	local address = self.address

	if host then
		address = ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp")
	end

	return self.socket:send_to(address, data)
end

function UDPClient:Error(message, ...)
	local tr = debug.traceback()
	self:OnError(message, tr, ...)
	return false
end

function UDPClient.New(socket)
	local self = UDPClient:CreateObject()
	self:Initialize(socket)
	return self
end

do
	local client

	function UDPClient.SendDatagram(data, ip, port)
		client = client or UDPClient.New()
		client:Send(data, ip, port)
	end
end

return UDPClient:Register()
