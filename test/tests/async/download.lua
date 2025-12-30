local T = require("test.environment")
local sockets = require("sockets.sockets")
require("http")
-- Use high port numbers to avoid conflicts
local test_port = 38500

-- Helper function to create and host a test server
local function host_server(on_receive_header)
	local server = sockets.HTTPServer()
	local port = test_port
	test_port = test_port + 1
	assert(server:Host("127.0.0.1", port))
	server.OnReceiveHeader = on_receive_header
	-- Give server time to start accepting connections
	T.Sleep(0.1)
	return server, port
end

-- Helper function to download with callbacks and wait for completion
local function download_and_wait(url, callbacks, timeout)
	local done = false
	local result = {
		data = nil,
		error = nil,
		chunks = {},
		header = nil,
		status_code = nil,
	}
	local on_success = function(data)
		result.data = data
		done = true

		if callbacks and callbacks.on_success then callbacks.on_success(data) end
	end
	local on_error = function(err)
		result.error = err
		done = true

		if callbacks and callbacks.on_error then callbacks.on_error(err) end
	end
	local on_chunks = callbacks and
		callbacks.on_chunks and
		function(chunk, written_size, total_size, friendly_name)
			table.insert(result.chunks, chunk)
			callbacks.on_chunks(chunk, written_size, total_size, friendly_name)
		end or
		nil
	local on_header = callbacks and
		callbacks.on_header and
		function(header, raw)
			result.header = header
			callbacks.on_header(header, raw)
		end or
		nil
	local on_status = callbacks and
		callbacks.on_status and
		function(code)
			result.status_code = code
			callbacks.on_status(code)
		end or
		nil
	local client = sockets.Download(url, on_success, on_error, on_chunks, on_header, on_status)

	T.WaitUntil(function()
		return done
	end)

	return result, client
end

T.Test("sockets.Download basic functionality", function()
	-- Create test server
	local server, port = host_server(function(self, client, header)
		local test_data = "Hello from download test!"
		client:Send(sockets.HTTPResponse(200, "OK", {["Content-Length"] = #test_data}, test_data))
		client:Close()
	end)
	-- Test download
	local result = download_and_wait(
		"http://127.0.0.1:" .. port .. "/test.txt",
		{
			on_error = function(err)
				print("[TEST] Download error:", err)
			end,
		},
		10.0
	)
	server:Close()
	T(result.error)["=="](nil)
	T(result.data)["~="](nil)
	T(result.data)["=="]("Hello from download test!")
end)

T.Test("sockets.Download with chunks callback", function()
	local chunks_received = {}
	local total_bytes = 0
	local server, port = host_server(function(self, client, header)
		local test_data = string.rep("X", 500)
		client:Send(sockets.HTTPResponse(200, "OK", {["Content-Length"] = #test_data}, test_data))
		client:Close()
	end)
	local result = download_and_wait(
		"http://127.0.0.1:" .. port .. "/data",
		{
			on_chunks = function(chunk, written_size, total_size, friendly_name)
				table.insert(chunks_received, chunk)
				total_bytes = written_size
			end,
		}
	)
	server:Close()
	T(#chunks_received)[">="](1)
	T(total_bytes)["=="](500)
end)

T.Test("sockets.Download with header callback", function()
	local received_header = nil
	local server, port = host_server(function(self, client, header)
		local headers = {["Content-Type"] = "text/plain", ["X-Custom"] = "test-value"}
		client:Send(sockets.HTTPResponse(200, "OK", headers, "test"))
		client:Close()
	end)
	local result = download_and_wait(
		"http://127.0.0.1:" .. port .. "/file",
		{
			on_header = function(header, raw)
				received_header = header
			end,
		}
	)
	server:Close()
	T(received_header)["~="](nil)
	T(received_header["content-type"])["=="]("text/plain")
	T(received_header["x-custom"])["=="]("test-value")
end)

T.Test("sockets.Download with status code callback", function()
	local status_code = nil
	local server, port = host_server(function(self, client, header)
		client:Send(sockets.HTTPResponse(200, "OK", {}, "success"))
		client:Close()
	end)
	local result = download_and_wait(
		"http://127.0.0.1:" .. port .. "/status",
		{
			on_status = function(code)
				status_code = code
			end,
		}
	)
	server:Close()
	T(status_code)["=="](200)
end)

T.Test("sockets.Download handles 404 error", function()
	local server, port = host_server(function(self, client, header)
		client:Send(sockets.HTTPResponse(404, "Not Found", {}, ""))
		client:Close()
	end)
	local result = download_and_wait("http://127.0.0.1:" .. port .. "/missing")
	server:Close()
	T(result.error)["~="](nil)
	T(result.data)["=="](nil)
end)

T.Test("sockets.Download can be accessed from active_downloads", function()
	local found_in_active = false
	local test_url = "http://127.0.0.1:" .. test_port .. "/active"
	local server, port = host_server(function(self, client, header)
		-- Check if download is in active list
		for _, download in ipairs(sockets.active_downloads) do
			if download.url == test_url then
				found_in_active = true

				break
			end
		end

		client:Send(sockets.HTTPResponse(200, "OK", {}, "data"))
		client:Close()
	end)
	local result = download_and_wait(test_url)
	server:Close()
	T(found_in_active)["=="](true)
	-- Verify it's removed after completion
	local still_active = false

	for _, download in ipairs(sockets.active_downloads) do
		if download.url == test_url then
			still_active = true

			break
		end
	end

	T(still_active)["=="](false)
end)

T.Test("sockets.StopDownload cancels active download", function()
	local finished = false
	local test_url = "http://127.0.0.1:" .. test_port .. "/cancel"
	local server, port = host_server(function(self, client, header) -- Server will just hold the connection open without responding
	-- The download will be cancelled before a response is sent
	end)
	local done = false
	local client = sockets.Download(test_url, function(data)
		finished = true
		done = true
	end, function(err)
		done = true
	end)
	-- Wait a bit then cancel
	T.Sleep(0.05)
	-- Verify it's in active downloads
	local was_active = false

	for _, download in ipairs(sockets.active_downloads) do
		if download.url == test_url then
			was_active = true

			break
		end
	end

	-- Cancel the download
	sockets.StopDownload(test_url)
	-- Verify it's removed
	local is_active = false

	for _, download in ipairs(sockets.active_downloads) do
		if download.url == test_url then
			is_active = true

			break
		end
	end

	server:Close()
	T(was_active)["=="](true)
	T(is_active)["=="](false)
	T(finished)["=="](false) -- Should not have finished since we cancelled
end)
