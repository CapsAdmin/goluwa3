local T = require("test.environment")
local tls = require("bindings.tls")
local HTTPClient = require("sockets.http.http11_client")
local HTTPServer = require("sockets.http.http11_server")
local http = require("sockets.http")

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

T.Test("sockets HTTP server and client communication", function()
	local done = false
	local received_request = nil
	local client_response = nil
	-- Create server
	local server = HTTPServer.New()
	assert(server:Host(test_host, test_port))
	test_port = test_port + 1

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
	local ok = server:Host(test_host, test_port)
	test_port = test_port + 1

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
	assert(server:Host(test_host, test_port))
	test_port = test_port + 1

	function server:OnReceiveResponse(client, method, path)
		server_got_request = true
	end

	function server:OnReceiveHeader(client, header)
		client:Send(http.HTTPResponse(200, "OK", {}, "{\"result\":\"success\"}"))
		client:Close()
	end

	http.Request(
		{
			url = "http://127.0.0.1:" .. (test_port - 1) .. "/test",
			callback = function(data)
				result = data
				done = true
			end,
			error_callback = function(err)
				done = true
			end,
		}
	)

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
	assert(server:Host(test_host, test_port))
	test_port = test_port + 1

	function server:OnReceiveHeader(client, header)
		received_headers = header
		client:Send(http.HTTPResponse(200, "OK", {}, "OK"))
		client:Close()
	end

	http.Request(
		{
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
	)

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
	assert(server:Host(test_host, test_port))
	test_port = test_port + 1

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