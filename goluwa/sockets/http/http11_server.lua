local http = require("sockets.http")
local prototype = require("prototype")
local META = prototype.CreateTemplate("socket_http11_server")
META.Base = prototype.GetRegistered("socket_tcp_server")

function META:OnClientConnected(client)
	if self:OnClientConnected2(client) == false then return false end

	http.ConnectedTCP2HTTP(client)
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

function META:OnReceiveResponse(client, method, path) end

function META:OnReceiveHeader(client, header) end

function META:OnReceiveBody(client, body) end

function META:OnClientConnected2() end -- idk what to do here

META:Register()

function http.HTTPServer(socket)
	local self = META:CreateObject()
	self:Initialize(socket)
	self.Clients = {}
	return self
end
