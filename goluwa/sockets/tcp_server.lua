local ljsocket = require("bindings.socket")
local prototype = require("prototype")
local repl = require("repl")
return function(sockets)
	local META = prototype.CreateTemplate("socket_tcp_server")

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

	function META:SocketRestart()
		self.socket = ljsocket.create("inet", "stream", "tcp")
		self:assert(self.socket:set_blocking(false))
		self.socket:set_option("nodelay", true, "tcp")
		self.socket:set_option("reuseaddr", true)
		self.connected = nil
		self.connecting = nil
	end

	function META:OnRemove()
		sockets.pool:remove(self)
		self:assert(self.socket:close())
	end

	function META:Close(reason)
		if reason then print(reason) end

		self:Remove()
	end

	function META:Host(host, service)
		local ok, err = self.socket:bind(host, service)

		if not ok then
			return self:Error("Unable to bind " .. host .. ":" .. service .. " - " .. err)
		end

		ok, err = self.socket:listen()

		if not ok then
			return self:Error("Unable to listen on " .. host .. ":" .. service .. " - " .. err)
		end

		self.hosting = true
		return true
	end

	function META:Update()
		if not self.hosting then return end

		for i = 1, 512 do
			local client, err = self.socket:accept()

			if err ~= "tryagain" then
				if client then
					local client = sockets.TCPClient(client)
					client.connected = true
					self:OnClientConnected(client)
				else
					self:Error(err)

					break
				end
			end
		end
	end

	function META:Error(message, ...)
		self:OnError(message, ...)
		return false, message
	end

	function META:OnError(str, tr)
		self:Remove()
		error(str)
	end

	function META:OnReceiveChunk(str) end

	function META:OnClose()
		self:Close()
	end

	function META:OnConnect() end

	META:Register()

	function sockets.TCPServer()
		local self = META:CreateObject()
		self:Initialize()
		return self
	end

	if HOTRELOAD then
		local function gen_body()
			local log = vfs.Read("logs/console_linux.txt")
			--log = log:gsub("\n", "<br/>")
			--log = log:gsub("\t", "    ")
			local body = [[<html><body>

        <pre>]] .. log .. [[</pre>

        <form>
            <input type="text" name="input" autofocus style="width:100%;position: relative;bottom: 0px">
        </form>

        </body></html>]]
			local header = "HTTP/1.1 200 OK\r\n" .. "Server: masrv/0.1.0\r\n" .. "Date: Thu, 28 Mar 2013 22:16:09 GMT\r\n" .. "Content-Type: text/html\r\n" .. "Connection: Keep-Alive\r\n" .. "Content-Length: " .. #body .. "\r\n" .. "Last-Modified: Wed, 21 Sep 2011 14:34:51 GMT\r\n" .. "Accept-Ranges: bytes\r\n" .. "\r\n"
			local content = header .. body
			return content
		end

		if HTTP_SERVER then HTTP_SERVER:Remove() end

		local server = sockets.TCPServer()
		server:Host("*", 5001)
		server.OnClientConnected = function(_, client)
			client:Send(gen_body())
			client.OnReceiveChunk = function(_, str)
				local str = str:match("GET /%?input=(.+) HTTP")

				if not str then return end

				str = str:gsub("%%(%x%x)", function(hex)
					return string.char(tonumber(hex, 16))
				end)
				logn(str)
				repl.InputLua(str)

				timer.Delay(0.5, function()
					client:Send(gen_body())
				end)
			end
		end
		HTTP_SERVER = server
	end
end
