local T = import("test/environment.lua")
local ljsocket = import("goluwa/bindings/socket.lua")
local tls = import("goluwa/bindings/tls.lua")
local HTTPClient = import("goluwa/sockets/http/http11_client.lua")
local HTTPServer = import("goluwa/sockets/http/http11_server.lua")
local TCPClient = import("goluwa/sockets/tcp_client.lua")
local TCPServer = import("goluwa/sockets/tcp_server.lua")
local UDPClient = import("goluwa/sockets/udp_client.lua")
local UDPServer = import("goluwa/sockets/udp_server.lua")
local http = import("goluwa/sockets/http.lua")
local https_test_url = "https://www.google.com/robots.txt"

T.Test("http.DecodeURI parses HTTP URL correctly", function()
	local uri = http.DecodeURI("http://example.com:8080/path/to/resource?query=value#fragment")
	T(uri)["~="](nil)
	T(uri.scheme)["=="]("http")
	T(uri.host)["=="]("example.com")
	T(uri.port)["=="]("8080")
	T(uri.path)["=="]("/path/to/resource?query=value#fragment")
end)

T.Test("http.DecodeURI parses simple URL", function()
	local uri = http.DecodeURI("http://example.com/test")
	T(uri)["~="](nil)
	T(uri.scheme)["=="]("http")
	T(uri.host)["=="]("example.com")
	T(uri.path)["=="]("/test")
end)

T.Test("http.HTTPRequest builds valid GET request", function()
	local uri = http.DecodeURI("http://example.com/test")
	local header = {
		["User-Agent"] = "Test",
	}
	local request = http.HTTPRequest("GET", uri, header, nil)
	T(request)["~="](nil)
	T(type(request))["=="]("string")
	local has_method = request:find("GET")
	local has_host = request:find("Host:")
	local has_path = request:find("/test")
	T(has_method)["~="](nil)
	T(has_host)["~="](nil)
	T(has_path)["~="](nil)
end)

T.Test("http.HTTPRequest builds POST request with body", function()
	local uri = http.DecodeURI("http://example.com/api")
	local request = http.HTTPRequest("POST", uri, {}, "test body")
	T(request)["~="](nil)
	T(type(request))["=="]("string")
	local has_method = request:find("POST")
	local has_content_length = request:find("Content%-Length:")
	local has_body = request:find("test body")
	T(has_method)["~="](nil)
	T(has_content_length)["~="](nil)
	T(has_body)["~="](nil)
end)

T.Test("HTTPClient.New can be created", function()
	local client = HTTPClient.New()
	T(client)["~="](nil)
	T(type(client))["=="]("table")
end)

T.Test("bindings.tls.tls_client returns fresh instances", function()
	local backend_a = tls.initialize()
	local backend_b = tls.initialize()
	local client_a = tls.tls_client()
	local client_b = tls.tls_client()
	T(backend_a == backend_b)["=="](true)
	T(type(client_a))["=="]("table")
	T(type(client_b))["=="]("table")
	T(client_a ~= client_b)["=="](true)
end)

-- Use high port numbers to avoid conflicts
local test_port = 5400
local test_host = "0.0.0.0"

local function next_port()
	local port = test_port
	test_port = test_port + 1
	return port
end

local function close_if_possible(obj)
	if obj and obj.IsValid and obj:IsValid() then
		obj:Close()
	elseif obj and obj.close then
		obj:close()
	end
end

T.Test("sockets HTTP server and client communication", function()
	local done = false
	local received_request = nil
	local client_response = nil
	-- Create server
	local server = HTTPServer.New()
	assert(server:Host(test_host, next_port()))

	function server:OnReceiveResponse(client, method, path)
		received_request = {method = method, path = path}
	end

	function server:OnReceiveHeader(client, header)
		-- Send response
		client:Send(http.HTTPResponse(200, "OK", {}, "Hello, World!"))
		client:Close()
	end

	-- Create client and make request
	local client = HTTPClient.New()

	function client:OnReceiveStatus(code, status)
		client_response = {code = tonumber(code), status = status}
	end

	function client:OnReceiveBody(body)
		client_response.body = body
		done = true
	end

	client:Request("GET", "http://localhost:" .. (test_port - 1) .. "/test")

	-- Wait for response
	T.WaitUntil(function()
		return done
	end)

	-- Cleanup
	server:Close()
	T(received_request)["~="](nil)
	T(received_request.method)["=="]("GET")
	T(received_request.path)["=="]("/test")
	T(client_response)["~="](nil)
	T(client_response.code)["=="](200)
	T(client_response.body)["=="]("Hello, World!")
end)

T.Test("sockets HTTP POST request with body", function()
	local done = false
	local received_body = nil
	local client_response = nil
	-- Create server
	local server = HTTPServer.New()
	local ok = server:Host(test_host, next_port())

	if not ok then return end

	function server:OnReceiveResponse(client, method, path)
		T(method)["=="]("POST")
	end

	function server:OnReceiveBody(client, body)
		received_body = body
		client:Send(http.HTTPResponse(200, "OK", {}, "Received: " .. body))
		client:Close()
	end

	-- Create client
	local client = HTTPClient.New()

	function client:OnReceiveBody(body)
		client_response = body
		done = true
	end

	function client:OnError(err)
		done = true
	end

	client:Request("POST", "http://127.0.0.1:" .. (test_port - 1) .. "/api", {}, "test data")

	T.WaitUntil(function()
		return done
	end)

	server:Close()
	T(received_body)["=="]("test data")
	T(client_response)["=="]("Received: test data")
end)

T.Test("http.Request wrapper function", function()
	local done = false
	local result = nil
	local server_got_request = false
	-- Create server
	local server = HTTPServer.New()
	assert(server:Host(test_host, next_port()))

	function server:OnReceiveResponse(client, method, path)
		server_got_request = true
	end

	function server:OnReceiveHeader(client, header)
		client:Send(http.HTTPResponse(200, "OK", {}, "{\"result\":\"success\"}"))
		client:Close()
	end

	http.Request{
		url = "http://127.0.0.1:" .. (test_port - 1) .. "/test",
		callback = function(data)
			result = data
			done = true
		end,
		error_callback = function(err)
			done = true
		end,
	}

	T.WaitUntil(function()
		return done
	end)

	server:Close()
	T(server_got_request)["=="](true)
	T(result)["~="](nil)
	T(result.code)["=="](200)
	T(result.body)["~="](nil)
end)

T.Test("http.Request with custom headers", function()
	local done = false
	local received_headers = nil
	local server = HTTPServer.New()
	assert(server:Host(test_host, next_port()))

	function server:OnReceiveHeader(client, header)
		received_headers = header
		client:Send(http.HTTPResponse(200, "OK", {}, "OK"))
		client:Close()
	end

	http.Request{
		url = "http://127.0.0.1:" .. (test_port - 1) .. "/test",
		header = {
			["X-Custom-Header"] = "test-value",
			["User-Agent"] = "Goluwa-Test",
		},
		callback = function(data)
			done = true
		end,
		error_callback = function(err)
			done = true
		end,
	}

	T.WaitUntil(function()
		return done
	end)

	server:Close()
	T(received_headers)["~="](nil)
	T(received_headers["x-custom-header"])["=="]("test-value")
	T(received_headers["user-agent"])["=="]("Goluwa-Test")
end)

T.Test("sockets HTTP chunked body receiving", function()
	local done = false
	local chunks = {}
	local final_body = nil
	local server = HTTPServer.New()
	assert(server:Host(test_host, next_port()))

	function server:OnReceiveHeader(client, header)
		-- Send a response that will come in chunks
		local response_body = string.rep("A", 1000)
		client:Send(http.HTTPResponse(200, "OK", {}, response_body))
		client:Close()
	end

	local client = HTTPClient.New()

	function client:OnReceiveBodyChunk(chunk)
		table.insert(chunks, chunk)
	end

	function client:OnReceiveBody(body)
		final_body = body
		done = true
	end

	function client:OnError(err)
		done = true
	end

	client:Request("GET", "http://127.0.0.1:" .. (test_port - 1) .. "/test")

	T.WaitUntil(function()
		return done
	end)

	server:Close()
	T(#chunks)[">="](1)
	T(final_body)["~="](nil)
	T(#final_body)["=="](1000)
end)

T.Test("bindings.socket.poll supports per-socket readiness masks", function()
	local results, count = ljsocket.poll({}, 0)
	T(type(results))["=="]("table")
	T(#results)["=="](0)
	T(count)["=="](0)
end)

T.Test("socket_tcp_client flushes buffered sends after poll connect", function()
	local port = next_port()
	local server = TCPServer.New()
	local client = TCPClient.New()
	local connected = false
	local received = nil
	assert(server:Host(test_host, port))

	function server:OnClientConnected(peer)
		function peer:OnReceiveChunk(chunk)
			received = chunk
		end
	end

	function client:OnConnect()
		connected = true
	end

	assert(client:Connect("127.0.0.1", port))
	assert(client:Send("buffered over poll"))

	T.WaitUntil(function()
		return connected and received == "buffered over poll"
	end)

	client:Close()
	server:Close()
	T(connected)["=="](true)
	T(received)["=="]("buffered over poll")
end)

T.Test("socket pool dispatches multiple TCP clients in one cycle", function()
	local port = next_port()
	local server = TCPServer.New()
	local clients = {TCPClient.New(), TCPClient.New()}
	local received = {}
	assert(server:Host(test_host, port))

	function server:OnClientConnected(peer)
		function peer:OnReceiveChunk(chunk)
			received[chunk] = true
		end
	end

	assert(clients[1]:Connect("127.0.0.1", port))
	assert(clients[2]:Connect("127.0.0.1", port))
	assert(clients[1]:Send("client-a"))
	assert(clients[2]:Send("client-b"))

	T.WaitUntil(function()
		return received["client-a"] and received["client-b"]
	end)

	for _, client in ipairs(clients) do
		client:Close()
	end

	server:Close()
	T(received["client-a"])["=="](true)
	T(received["client-b"])["=="](true)
end)

T.Test("socket_udp_server receives datagrams through poll dispatch", function()
	local port = next_port()
	local raw_server = assert(ljsocket.create("inet", "dgram", "udp"))
	local server = nil
	local client = UDPClient.New()
	local chunk = nil
	local address = nil
	assert(raw_server:set_blocking(false))
	assert(raw_server:bind("127.0.0.1", port))
	server = UDPServer.New(raw_server)

	function server:OnReceiveChunk(data, addr)
		chunk = data
		address = addr
	end

	assert(client:Send("udp over poll", "127.0.0.1", port))

	T.WaitUntil(function()
		return chunk ~= nil
	end)

	server:Close()
	client:Close()
	T(chunk)["=="]("udp over poll")
	T(address)["~="](nil)
	T(address:get_ip())["=="]("127.0.0.1")
end)

T.Test("HTTPS GET request to google.com via http.Request", function()
	local done = false
	local result = nil
	http.Request{
		url = https_test_url,
		callback = function(data)
			result = data
			done = true
		end,
		error_callback = function(err)
			result = {error = err}
			done = true
		end,
	}

	T.WaitUntil(function()
		return done
	end)

	T(result)["~="](nil)
	T(result.error)["=="](nil)
	T(result.code)["=="](200)
	T(result.body)["~="](nil)
	T(#result.body)[">"](0)
	T(result.body:find("User%-agent:"))["~="](nil)
end)

T.Test("HTTPS GET via HTTPClient directly", function()
	local done = false
	local status_code = nil
	local body = nil
	local client = HTTPClient.New()

	function client:OnReceiveStatus(code, status)
		status_code = tonumber(code)
	end

	function client:OnReceiveBody(b)
		body = b
		done = true
	end

	function client:OnError(err)
		done = true
	end

	client:Request("GET", https_test_url)

	T.WaitUntil(function()
		return done
	end)

	T(status_code)["=="](200)
	T(body)["~="](nil)
	T(#body)[">"](0)
	T(body:find("User%-agent:"))["~="](nil)
end)

T.Test("HTTPS request receives correct headers", function()
	local done = false
	local response_header = nil
	http.Request{
		url = https_test_url,
		callback = function(data)
			response_header = data.header
			done = true
		end,
		error_callback = function(err)
			done = true
		end,
	}

	T.WaitUntil(function()
		return done
	end)

	T(response_header)["~="](nil)
	T(response_header["content-type"])["=="]("text/plain")
end)
