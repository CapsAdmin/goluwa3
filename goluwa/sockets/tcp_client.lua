local ljsocket = require("bindings.socket")
local prototype = require("prototype")
return function(sockets)
	local META = prototype.CreateTemplate("socket_tcp_client")
	prototype.GetSet(META, "BufferSize", 64000)

	function META:assert(val, err)
		if not val then self:Error(err) end

		return val, err
	end

	function META:__tostring2()
		return "[" .. tostring(self.socket) .. "]"
	end

	function META:Initialize(socket)
		self:SocketRestart(socket)
		sockets.pool:insert(self)
	end

	function META:SocketRestart(socket)
		self.socket = socket or ljsocket.create("inet", "stream", "tcp")
		self:assert(self.socket:set_blocking(false))
		self.socket:set_option("nodelay", true, "tcp")
		self.socket:set_option("cork", false, "tcp")
		self.tls_setup = nil
		self.connected = nil
		self.connecting = nil
	end

	do
		local ssl = require("bindings.tls")

		function META:SetupTLS()
			if self.tls_setup then return end

			self.tls_setup = true
			local tls = ssl.tls_client()
			local tls_closed = false

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

	function META:OnRemove()
		sockets.pool:remove(self)

		if self.socket and self.socket.fd and self.socket.fd >= 0 then
			self.socket:close()
		end
	end

	function META:Close(reason)
		self:Remove()
	end

	-- in case /etc/service don't exist
	local services = {
		https = "443",
		http = "80",
	}

	function META:Connect(host, service)
		if service == "https" then self:SetupTLS() end

		local ok, err = self.socket:connect(host, services[service] or service)

		if ok then
			self.connecting = true
			return true
		end

		return self:Error("Unable to connect to " .. host .. ":" .. service .. ": " .. err)
	end

	function META:Send(data)
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

	function META:Update()
		if self.connecting then
			-- For TLS sockets, try_connect handles the handshake
			-- For regular sockets, just check if connected
			if self.socket.on_connect then self.socket:try_connect() end

			if self.socket:is_connected() then
				self:OnConnect()
				self.connected = true
				self.connecting = false
			end
		elseif self.connected then
			if self.buffered_send then
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

			for i = 1, 500 do
				local chunk, err = self.socket:receive(self.BufferSize)

				if err == "context not connected" then break end

				if err == "tryagain" then break end

				if chunk then
					self:OnReceiveChunk(chunk)
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

	function META:Error(message, ...)
		local tr = debug.traceback()
		self:OnError(message, tr, ...)
		return false, message
	end

	function META:OnError(str, tr)
		self:Remove(str)
		error(str)
	end

	function META:OnReceiveChunk(str) end

	function META:OnClose()
		self:Close()
	end

	function META:OnConnect() end

	META:Register()

	function sockets.TCPClient(socket)
		local self = META:CreateObject()
		self:Initialize(socket)
		return self
	end
end
