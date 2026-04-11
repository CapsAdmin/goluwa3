local ljsocket = import("goluwa/bindings/socket.lua")
local prototype = import("goluwa/prototype.lua")
local socket_pool = import("goluwa/sockets/socket_pool.lua")
local UDPClient = prototype.CreateTemplate("socket_tcp_client")
UDPClient:GetSet("BufferSize", 64000)

function UDPClient:assert(val, err)
	if not val then self:Error(err) end

	return val, err
end

function UDPClient:__tostring2()
	return "[" .. tostring(self.socket) .. "]"
end

function UDPClient:InsertIntoSocketPool()
	if self.in_socket_pool then return end

	socket_pool:insert(self)
	self.in_socket_pool = true
end

function UDPClient:RemoveFromSocketPool()
	if not self.in_socket_pool then return end

	socket_pool:remove(self)
	self.in_socket_pool = nil
end

function UDPClient:Initialize(socket)
	self:SocketRestart(socket)
end

function UDPClient:SocketRestart(socket)
	self.socket = socket or ljsocket.create("inet", "stream", "tcp")
	self:assert(self.socket:set_blocking(false))
	self.socket:set_option("nodelay", true, "tcp")
	self.socket:set_option("cork", false, "tcp")
	self.tls_setup = nil
	self.connected = nil
	self.connecting = nil
end

do
	local ssl = import("goluwa/bindings/tls.lua")

	function UDPClient:SetupTLS()
		if self.tls_setup then return end

		ssl.initialize()
		local tls = ssl.tls_client()
		local tls_closed = false
		self.tls_setup = true

		function self.socket:on_connect(host, service)
			return tls.connect(self.fd, host)
		end

		function self.socket:on_send(data, flags)
			return tls.send(data)
		end

		function self.socket:on_receive(buffer, max_size, flags)
			return tls.receive(buffer, max_size)
		end

		function self.socket:on_close()
			if not tls_closed then
				tls_closed = true
				return tls.close()
			end
		end
	end
end

function UDPClient:OnRemove()
	self:RemoveFromSocketPool()
	self.connected = false
	self.connecting = false
	local socket = self.socket
	self.socket = nil

	if socket and socket.fd and socket.fd >= 0 then socket:close() end
end

function UDPClient:Close(reason)
	self:Remove()
end

-- in case /etc/service don't exist
local services = {
	https = "443",
	http = "80",
}

function UDPClient:Connect(host, service)
	if service == "https" then self:SetupTLS() end

	local ok, err = self.socket:connect(host, services[service] or service)

	if ok then
		self.connecting = true
		self:InsertIntoSocketPool()
		return true
	end

	return self:Error("Unable to connect to " .. host .. ":" .. service .. ": " .. err)
end

function UDPClient:Send(data)
	local ok, err

	if self.socket:is_connected() and not self.connecting then
		local pos = 0
		local t = os.clock() + 1

		for i = 1, math.huge do
			ok, err = self.socket:send(data:sub(pos + 1))

			if t < os.clock() then return false, "tryagain" end

			if not ok and err ~= "tryagain" then return self:Error(err) end

			if err ~= "tryagain" then
				pos = pos + tonumber(ok)

				if pos >= #data then break end
			end
		end
	else
		ok, err = false, "tryagain"
	end

	if not ok then
		if err == "tryagain" then
			self.buffered_send = self.buffered_send or {}
			list.insert(self.buffered_send, data)
			return true
		end

		return self:Error(err)
	end

	return ok, err
end

function UDPClient:GetPollSocket()
	return self.socket
end

function UDPClient:GetPollFlags()
	if self.connecting then return {"in", "out"} end

	if self.connected then
		if self.buffered_send and #self.buffered_send > 0 then
			return {"in", "out"}
		end

		return {"in"}
	end

	error(tostring(self) .. " is in socket pool without an active poll state")
end

function UDPClient:HandleConnectReady()
	if self.connecting then
		-- For TLS sockets, try_connect handles the handshake
		-- For regular sockets, just check if connected
		if self.socket.on_connect then
			local ok, err = self.socket:try_connect()

			if ok then
				self:OnConnect()
				self.connected = true
				self.connecting = false
			elseif err == "connecting" or err == "tryagain" then

			-- still connecting
			else
				self:Error(err or "failed to connect (tls)")
			end
		elseif self.socket:is_connected() then
			self:OnConnect()
			self.connected = true
			self.connecting = false
		else
			-- For non-TLS sockets, check for connection errors during asynchronous connect
			local ok, err = self.socket:get_option("error")

			if
				ok == 0 or
				ok == ljsocket.errno.ENOTCONN or
				ok == ljsocket.errno.EINPROGRESS or
				ok == ljsocket.errno.EWOULDBLOCK
			then

			-- Keep waiting until getpeername/getsockname reports a real connected socket.
			elseif ok and ok ~= 0 then
				self:Error(ljsocket.socket.lasterror(ok))
			end
		end
	end
end

function UDPClient:HandleWriteReady()
	if self.connected and self.buffered_send then
		for _ = 1, #self.buffered_send * 4 do
			local data = self.buffered_send[1]

			if not data then break end

			local ok, err = self:Send(data)

			if ok then
				list.remove(self.buffered_send)
			elseif err ~= "tryagain" then
				self:Error("error while processing buffered queue: " .. err)
			end
		end
	end
end

function UDPClient:HandleReadReady()
	if self.connected then
		for i = 1, 500 do
			local chunk, err = self.socket:receive(self.BufferSize)

			if err == "context not connected" then break end

			if err == "tryagain" then break end

			if chunk then
				local current_socket = self.socket
				self:OnReceiveChunk(chunk)

				if current_socket ~= self.socket or self.connecting or not self.connected then
					break
				end
			else
				if err == "closed" then
					self:OnClose("receive")

					break
				elseif err ~= "tryagain" then
					self:Error(err)

					break
				end
			end
		end
	end
end

function UDPClient:OnPollReady(events)
	if
		self.connecting and
		(
			events["in"] or
			events.out or
			events.err or
			events.hup or
			events.nval
		)
	then
		self:HandleConnectReady()
	end

	if self.connected and (events.out or events.err or events.hup or events.nval) then
		self:HandleWriteReady()
	end

	if self.connected and (events["in"] or events.err or events.hup or events.nval) then
		self:HandleReadReady()
	end
end

function UDPClient:Update()
	self:OnPollReady{
		["in"] = true,
		out = true,
		err = true,
		hup = true,
		nval = true,
	}
end

function UDPClient:Error(message, ...)
	local tr = debug.traceback()
	self:OnError(message, tr, ...)
	return false, message
end

function UDPClient:OnError(str, tr)
	self:Remove(str)
	error(str)
end

function UDPClient:OnReceiveChunk(str) end

function UDPClient:OnClose()
	self:Close()
end

function UDPClient:OnConnect() end

function UDPClient.New(socket)
	local self = UDPClient:CreateObject()
	self:Initialize(socket)
	return self
end

return UDPClient:Register()
