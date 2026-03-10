local prototype = require("prototype")
local HTTPClient = require("sockets.http.http11_client")
local HTTPServer = prototype.CreateTemplate("socket_http11_server")
HTTPServer.Base = require("sockets.tcp_server")

function HTTPServer:OnClientConnected(client)
	if self:OnClientConnected2(client) == false then return false end

	HTTPClient.ConnectedTCP2HTTP(client)
	list.insert(self.Clients, client)
	client.OnReceiveResponse = function(client, method, path)
		if not self:IsValid() then return end

		return self:OnReceiveResponse(client, method, path)
	end
	client.OnReceiveHeader = function(client, header)
		if not self:IsValid() then return end

		return self:OnReceiveHeader(client, header)
	end
	client.OnReceiveBody = function(client, body)
		if not self:IsValid() then return end

		return self:OnReceiveBody(client, body)
	end

	client:CallOnRemove(function(client, reason)
		if self:IsValid() then list.remove_value(self.Clients, client) end
	end)
end

function HTTPServer:OnReceiveResponse(client, method, path) end

function HTTPServer:OnReceiveHeader(client, header) end

function HTTPServer:OnReceiveBody(client, body) end

function HTTPServer:OnClientConnected2() end -- idk what to do here

function HTTPServer.New(socket)
	local self = HTTPServer:CreateObject()
	self:Initialize(socket)
	self.Clients = {}
	return self
end

return HTTPServer:Register()