local prototype = import("goluwa/prototype.lua")
local http = import("goluwa/sockets/http.lua")
local HTTPClient = prototype.CreateTemplate("socket_http11_client")
HTTPClient.Base = import("goluwa/sockets/tcp_client.lua")
HTTPClient.Stage = "none"

do
	http.MixinHTTP(HTTPClient)

	function HTTPClient:OnReceiveChunk(data)
		self:WriteHTTP(data, self.FromClient)
	end

	function HTTPClient:OnReceiveResponse(method, path) end

	function HTTPClient:OnReceiveStatus(code, status) end

	function HTTPClient:OnReceiveHeader(header, raw_header) end

	function HTTPClient:OnReceiveBodyChunk(chunk) end

	function HTTPClient:OnReceiveBody(body) end

	function HTTPClient:OnHTTPEvent(what)
		local ret = nil

		if what == "response" then
			ret = self:OnReceiveResponse(self.http.method, self.http.path)
		elseif what == "status" then
			ret = self:OnReceiveStatus(self.http.code, self.http.status)
		elseif what == "header" then
			ret = self:OnReceiveHeader(self.http.header, self.http.raw_header)
		elseif what == "chunk" then
			ret = self:OnReceiveBodyChunk(self.http.current_body_chunk)
		elseif what == "body" then
			ret = self:OnReceiveBody(self.http.body)
		end

		if ret == false then return false end

		if what == "code" then
			local code = self.http.code

			if not self.NoCodeError and not code:starts_with("2") and not code:starts_with("3") then
				return self:Error(code .. " " .. status)
			end
		elseif what == "header" then
			local header = self.http.header
			local code = self.http.code

			if code and code ~= "304" and code:starts_with("3") and header["location"] then
				self:Redirect(header["location"])
				return false
			end

			if header["connection"] == "close" then
				self:Close()
				return false
			end
		elseif what == "body" then
			self:Close()
		end
	end
end

function HTTPClient:Request(method, url, header, body)
	local uri = assert(http.DecodeURI(url))
	header = header or {}
	self:Connect(uri.host, uri.port or uri.scheme)
	self:Send(http.HTTPRequest(method, uri, header, body))
	self:InitializeHTTPParser()
	self.LocationHistory = self.LocationHistory or {url}
	-- this is for redirect
	self.CurrentRequest = {
		url = url,
		uri = uri,
		header = header,
		method = method,
		body = body,
	}
end

function HTTPClient:Redirect(location)
	local req = self.CurrentRequest

	if not req then
		return self:Error("tried to redirect when no previous request was made")
	end

	self:assert(self.socket:close())
	self:SocketRestart()

	if location:starts_with("/") then
		local host = req.header.Host or req.uri.host

		if req.uri.port then host = host .. ":" .. req.uri.port end

		location = req.uri.scheme .. "://" .. host .. location
	else
		req.header.Host = nil
	end

	req.uri = http.DecodeURI(location)
	self:Connect(req.uri.host, req.uri.scheme)
	self:Send(http.HTTPRequest(req.method, req.uri, req.header, req.body))
	self:InitializeHTTPParser()
	list.insert(self.LocationHistory, location)
end

function HTTPClient:GetRedirectHistory()
	return self.LocationHistory or {}
end

function HTTPClient.New(socket)
	local self = HTTPClient:CreateObject()
	self:Initialize(socket)
	return self
end

function HTTPClient.ConnectedTCP2HTTP(obj)
	setmetatable(obj, prototype.GetRegistered(HTTPClient.Type))
	obj:InitializeHTTPParser()
	obj:OnConnect()
	obj.connected = true
	obj.connecting = false
	obj.FromClient = true
end

return HTTPClient:Register()
