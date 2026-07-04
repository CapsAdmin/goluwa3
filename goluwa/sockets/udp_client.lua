local ljsocket = import("goluwa/bindings/socket.lua")
local objects = import("goluwa/objects/objects.lua")
local socket_pool = import("goluwa/sockets/socket_pool.lua")
local UDPClient = objects.CreateTemplate("socket_udp_client")

function UDPClient:assert(val, err)
	if not val then self:Error(err) end

	return val, err
end

function UDPClient:__tostring2()
	return "[" .. tostring(self.socket) .. "]"
end

function UDPClient:Initialize(socket)
	self:SocketRestart(socket)
	socket_pool:insert(self)
end

function UDPClient:SocketRestart(socket)
	self.socket = socket or ljsocket.create("inet", "dgram", "udp")
	self:assert(self.socket:set_blocking(false))
end

function UDPClient:OnRemove()
	socket_pool:remove(self)
	self.socket:close()
end

function UDPClient:Close(reason)
	self:Remove()
end

function UDPClient:SetAddress(host, port)
	self.address = assert(ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp"))
end

function UDPClient:Send(data, host, port)
	local address = self.address

	if host then
		address = assert(ljsocket.find_first_address_info(host, port, nil, "inet", "dgram", "udp"))
	end

	return self.socket:send_to(address, data)
end

function UDPClient:GetPollSocket()
	return self.socket
end

function UDPClient:GetPollFlags()
	return {"in"}
end

function UDPClient:OnPollReady(events)
	if not (events["in"] or events.err or events.hup or events.nval) then return end

	local chunk, err = self.socket:receive_from()

	if chunk then
		if self.OnReceiveChunk then
			self:OnReceiveChunk(chunk, err)
		end
	else
		if err == "closed" then
			self:OnClose("receive")
		elseif err ~= "timeout" and err ~= "tryagain" then
			self:Error(err)
		end
	end
end

function UDPClient:Update()
	self:OnPollReady{
		["in"] = true,
		err = true,
		hup = true,
		nval = true,
	}
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
