local frame = require("sockets.websocket.frame")
local crypto = require("crypto")
local prototype = require("prototype")
local HTTPClient = require("sockets.http.http11_client")
local WebSocketServer = prototype.CreateTemplate("socket_websocket_server")
WebSocketServer.Base = require("sockets.tcp_server")

local function header_to_table(header)
	local tbl = {}

	if not header then return tbl end

	for _, line in ipairs(header:split("\n")) do
		local key, value = line:match("(.+):%s+(.+)\r")

		if key and value then tbl[key:lower()] = tonumber(value) or value end
	end

	return tbl
end

function WebSocketServer:OnClientConnected(client)
	HTTPClient.ConnectedTCP2HTTP(client)

	function client.OnReceiveHeader(client, headers)
		self:Respond(
			"101 Switching Protocols",
			{
				["Upgrade"] = "websocket",
				["Connection"] = headers["connection"],
				["Sec-WebSocket-Accept"] = crypto.Base64Encode(crypto.SHA1(headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")),
			}
		)

		function client.OnReceiveChunk(client, str)
			local first_opcode
			local frames = {}
			local encoded = str

			if client.last_encoded then
				encoded = client.last_encoded .. str
				client.last_encoded = nil
			end

			repeat
				local decoded, fin, opcode, rest = frame.decode(encoded)

				if decoded then
					if not first_opcode then first_opcode = opcode end

					list.insert(frames, decoded)
					encoded = rest

					if fin == true then
						local message = list.concat(frames)

						if first_opcode == frame.CLOSE or opcode == frame.CLOSE then
							local code, reason = frame.decode_close(message)
							local encoded = frame.encode_close(code)
							encoded = frame.encode(encoded, frame.CLOSE, true)
							client:Send(encoded)
							client:OnClose(reason, code)
							client:Remove()
							return
						else
							frames = {}
							client:OnMessage(message, opcode)
							self:OnMessage(client, message, opcode)
						end
					end
				elseif #encoded > 0 then
					client.last_encoded = encoded
				end				
			until not decoded
		end

		function client:OnMessage(message, opcode) end

		function client:SendMessage(data, opcode)
			self:Send(frame.encode(data, opcode))
		end
	end
end

function WebSocketServer.New(socket)
	local self = WebSocketServer:CreateObject()
	self:Initialize(socket)
	self.Clients = {}
	return self
end

return WebSocketServer:Register()