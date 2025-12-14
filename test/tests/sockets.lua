local T = require("test.t")
local sockets = require("sockets.sockets")
require("http") -- This adds sockets.Request to the sockets module
-- Test basic socket utilities that don't require network
T.test("sockets.DecodeURI parses HTTP URL correctly", function()
	local uri = sockets.DecodeURI("http://example.com:8080/path/to/resource?query=value#fragment")
	T(uri)["~="](nil)
	T(uri.scheme)["=="]("http")
	T(uri.host)["=="]("example.com")
	T(uri.port)["=="]("8080")
	T(uri.path)["=="]("/path/to/resource?query=value#fragment")
end)

T.test("sockets.DecodeURI parses simple URL", function()
	local uri = sockets.DecodeURI("http://example.com/test")
	T(uri)["~="](nil)
	T(uri.scheme)["=="]("http")
	T(uri.host)["=="]("example.com")
	T(uri.path)["=="]("/test")
end)

T.test("sockets.HTTPRequest builds valid GET request", function()
	local uri = sockets.DecodeURI("http://example.com/test")
	local header = {
		["User-Agent"] = "Test",
	}
	local request = sockets.HTTPRequest("GET", uri, header, nil)
	T(request)["~="](nil)
	T(type(request))["=="]("string")
	local has_method = request:find("GET")
	local has_host = request:find("Host:")
	local has_path = request:find("/test")
	T(has_method)["~="](nil)
	T(has_host)["~="](nil)
	T(has_path)["~="](nil)
end)

T.test("sockets.HTTPRequest builds POST request with body", function()
	local uri = sockets.DecodeURI("http://example.com/api")
	local request = sockets.HTTPRequest("POST", uri, {}, "test body")
	T(request)["~="](nil)
	T(type(request))["=="]("string")
	local has_method = request:find("POST")
	local has_content_length = request:find("Content%-Length:")
	local has_body = request:find("test body")
	T(has_method)["~="](nil)
	T(has_content_length)["~="](nil)
	T(has_body)["~="](nil)
end)

T.test("sockets.HTTPClient can be created", function()
	local client = sockets.HTTPClient()
	T(client)["~="](nil)
	T(type(client))["=="]("table")
end)

-- Use high port numbers to avoid conflicts
local test_port = 38451

T.test("sockets HTTP server and client communication", function()
	local done = false
	local received_request = nil
	local client_response = nil
	-- Create server
	local server = sockets.HTTPServer()
	local ok = server:Host("*", test_port)
	test_port = test_port + 1

	if not ok then -- Skip test if can't bind port
	return end

	function server:OnReceiveRequest(client, method, path)
		received_request = {method = method, path = path}
	end

	function server:OnReceiveHeader(client, header)
		-- Send response
		client:Send(sockets.HTTPResponse(200, "OK", {}, "Hello, World!"))
		client:Close()
	end

	-- Wait a bit for server to start
	T.run_for(0.05)
	-- Create client and make request
	local client = sockets.HTTPClient()

	function client:OnReceiveStatus(code, status)
		client_response = {code = tonumber(code), status = status}
	end

	function client:OnReceiveBody(body)
		client_response.body = body
		done = true
	end

	function client:OnError(err)
		done = true
	end

	client:Request("GET", "http://127.0.0.1:" .. (test_port - 1) .. "/test")
	-- Wait for response
	local success = T.run_until(function()
		return done
	end, 2.0)
	-- Cleanup
	server:Close()
	T(success)["=="](true)
	T(received_request)["~="](nil)
	T(received_request.method)["=="]("GET")
	T(received_request.path)["=="]("/test")
	T(client_response)["~="](nil)
	T(client_response.code)["=="](200)
	T(client_response.body)["=="]("Hello, World!")
end)

T.test("sockets HTTP POST request with body", function()
	local done = false
	local received_body = nil
	local client_response = nil
	-- Create server
	local server = sockets.HTTPServer()
	local ok = server:Host("*", test_port)
	test_port = test_port + 1

	if not ok then return end

	function server:OnReceiveRequest(client, method, path)
		T(method)["=="]("POST")
	end

	function server:OnReceiveBody(client, body)
		received_body = body
		client:Send(sockets.HTTPResponse(200, "OK", {}, "Received: " .. body))
		client:Close()
	end

	T.run_for(0.05)
	-- Create client
	local client = sockets.HTTPClient()

	function client:OnReceiveBody(body)
		client_response = body
		done = true
	end

	function client:OnError(err)
		done = true
	end

	client:Request("POST", "http://127.0.0.1:" .. (test_port - 1) .. "/api", {}, "test data")
	local success = T.run_until(function()
		return done
	end, 2.0)
	server:Close()
	T(success)["=="](true)
	T(received_body)["=="]("test data")
	T(client_response)["=="]("Received: test data")
end)

T.test("sockets.Request wrapper function", function()
	local done = false
	local result = nil
	local server_got_request = false
	-- Create server
	local server = sockets.HTTPServer()
	local ok = server:Host("*", test_port)
	test_port = test_port + 1

	if not ok then return end

	function server:OnReceiveRequest(client, method, path)
		server_got_request = true
	end

	function server:OnReceiveHeader(client, header)
		client:Send(sockets.HTTPResponse(200, "OK", {}, "{\"result\":\"success\"}"))
		client:Close()
	end

	T.run_for(0.05)
	sockets.Request(
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
	local success = T.run_until(function()
		return done
	end, 2.0)
	server:Close()
	T(success)["=="](true)
	T(server_got_request)["=="](true)
	T(result)["~="](nil)
	T(result.code)["=="](200)
	T(result.body)["~="](nil)
end)

T.test("sockets.Request with custom headers", function()
	local done = false
	local received_headers = nil
	local server = sockets.HTTPServer()
	local ok = server:Host("*", test_port)
	test_port = test_port + 1

	if not ok then return end

	function server:OnReceiveHeader(client, header)
		received_headers = header
		client:Send(sockets.HTTPResponse(200, "OK", {}, "OK"))
		client:Close()
	end

	T.run_for(0.05)
	sockets.Request(
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
	local success = T.run_until(function()
		return done
	end, 2.0)
	server:Close()
	T(success)["=="](true)
	T(received_headers)["~="](nil)
	T(received_headers["x-custom-header"])["=="]("test-value")
	T(received_headers["user-agent"])["=="]("Goluwa-Test")
end)

T.test("sockets HTTP chunked body receiving", function()
	local done = false
	local chunks = {}
	local final_body = nil
	local server = sockets.HTTPServer()
	local ok = server:Host("*", test_port)
	test_port = test_port + 1

	if not ok then return end

	function server:OnReceiveHeader(client, header)
		-- Send a response that will come in chunks
		local response_body = string.rep("A", 1000)
		client:Send(sockets.HTTPResponse(200, "OK", {}, response_body))
		client:Close()
	end

	T.run_for(0.05)
	local client = sockets.HTTPClient()

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
	local success = T.run_until(function()
		return done
	end, 2.0)
	server:Close()
	T(success)["=="](true)
	T(#chunks)[">="](1)
	T(final_body)["~="](nil)
	T(#final_body)["=="](1000)
end)
