local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local http = import("goluwa/sockets/http.lua")
local callback = import("goluwa/callback.lua")
local event = import("goluwa/event.lua")
local output = import("goluwa/cli/output.lua")
local mcp = library()
local tools = {
	run_lua = {
		description = "Execute Lua code in the game environment and return the output.",
		inputSchema = {
			type = "object",
			properties = {
				code = {type = "string", description = "The Lua code to execute."},
			},
			required = {"code"},
		},
		callback = function(args)
			local code = args.code

			if not code or type(code) ~= "string" then
				return nil, {code = -32602, message = "Missing or invalid 'code' parameter"}
			end

			local str, result = output.Capture(function()
				local func, err = load(code, "mcp_lua", "t")

				if not func then return list.pack(false, err) end

				return list.pack(pcall(func))
			end)
			local ok = table.remove(result, 1)

			if not ok then
				return {output = str .. "\nError: " .. tostring(result[2]), success = false}
			end

			return {output = str .. table.tostring(result), success = true}
		end,
	},
	get_logs = {
		description = "Retrieve recent game logs.",
		inputSchema = {
			type = "object",
			properties = {
				lines = {
					type = "number",
					description = "Number of recent log lines to retrieve.",
					default = 50,
				},
			},
		},
		callback = function(args)
			local count = args and args.lines and math.floor(args.lines) or 50
			return {logs = output.GetLogLines(count)}
		end,
	},
	async_test = {
		description = "Test async support by waiting for the next frame to complete.",
		inputSchema = {
			type = "object",
			properties = json.createEmptyObject(),
		},
		callback = function(args)
			local cb = callback.Create()

			event.AddListener("FrameEnd", nil, function()
				cb:Resolve("frame completed")
				return event.destroy_tag
			end)

			-- cb:Get() blocks until resolved (works in coroutine context)
			local result = cb:Get()
			return {message = result}
		end,
	},
	screenshot = {
		description = "Take a screenshot of the current game frame and return it as a PNG image.",
		inputSchema = {
			type = "object",
			properties = json.createEmptyObject(),
		},
		callback = function(args)
			local base64 = import("goluwa/codecs/base64.lua")
			local render = import("goluwa/render/render.lua")
			local cb = callback.Create()

			render.Screenshot(function(downloaded_texture)
				local png_data = downloaded_texture:ToPNG(true)
				fs.write_file("last_screenshot.png", png_data)
				local encoded = base64.Encode(png_data)
				cb:Resolve(encoded)
			end)

			return {image = cb:Get(), mimeType = "image/png"}
		end,
	},
}
local tools_definition = {}

for name, tool in pairs(tools) do
	local tool = table.copy(tool)
	tool.name = name
	tool.callback = nil
	table.insert(tools_definition, tool)
end

local function jsonrpc_response(id, body)
	return json.encode{jsonrpc = "2.0", id = id, [body.error and "error" or "result"] = body}
end

local function handle_mcp_request(json_str)
	local request = json.decode(json_str)
	local method = request.method
	local params = request.params or {}
	local req_id = request.id

	if method == "initialize" then
		return jsonrpc_response(
			req_id,
			{
				protocolVersion = "2024-11-05",
				capabilities = {tools = {listChanged = true}},
				serverInfo = {name = "goluwa-mcp", version = "1.0.0"},
			}
		)
	end

	if method == "notifications/initialized" then return nil end

	if method:starts_with("notifications/") then return nil end

	if method == "tools/list" then
		return jsonrpc_response(req_id, {tools = tools_definition})
	end

	if method == "tools/call" then
		local tool_name = params.name
		local tool_args = params.arguments or {}
		llog("[MCP] Tool call: " .. tostring(tool_name))

		if not tools[tool_name] then
			return jsonrpc_response(
				req_id,
				{error = {code = -32601, message = "Tool not found: " .. tostring(tool_name)}}
			)
		end

		local ok, result = pcall(tools[tool_name].callback, tool_args)

		if not ok then
			llog("[MCP] Tool callback error: " .. tostring(result))
			return jsonrpc_response(req_id, {error = {code = -32603, message = tostring(result)}})
		end

		-- Check if result is an image
		if result.image then
			llog("[MCP] Screenshot result, image data size: " .. #result.image .. " bytes")
			return jsonrpc_response(
				req_id,
				{
					content = {{type = "image", data = result.image, mimeType = result.mimeType}},
				}
			)
		end

		return jsonrpc_response(req_id, {
			content = {{type = "text", text = json.encode(result)}},
		})
	end

	return jsonrpc_response(
		req_id,
		{error = {code = -32601, message = "Method not found: " .. tostring(method)}}
	)
end

mcp.server = mcp.server or NULL

function mcp.StartServer(port)
	port = port or 8600
	local HTTPServer = import("goluwa/sockets/http/http11_server.lua")
	local tasks = import("goluwa/tasks.lua")

	if mcp.server:IsValid() then mcp.server:Remove() end

	local server = HTTPServer.New()
	mcp.server = server
	local client_pending_response = {}

	function server:OnReceiveResponse(client, method, path)
		if path == "/mcp" or path == "/" then
			if method ~= "POST" then
				client:Send(
					http.HTTPResponse(
						"405",
						"Method Not Allowed",
						{
							["Content-Type"] = "application/json",
						},
						json.encode{error = {code = -32601, message = "Method Not Allowed"}}
					)
				)
				return
			end

			client_pending_response[client] = {}
		else
			client:Send(
				http.HTTPResponse(
					"404",
					"Not Found",
					{
						["Content-Type"] = "application/json",
					},
					json.encode{error = {code = -32601, message = "Not Found"}}
				)
			)
		end
	end

	function server:OnReceiveBody(client, body)
		local pending = client_pending_response[client]

		if not pending then return end

		client_pending_response[client] = nil
		client:SetAutoClose(false)
		local response_client = client
		llog("[MCP] Received body, size: " .. #body .. " bytes")

		-- Handle request in a task coroutine so async operations can yield
		tasks.CreateTask(
			function()
				llog("[MCP] Processing request...")
				local ok, response_str = pcall(handle_mcp_request, body)

				if not response_client:IsValid() then
					llog("[MCP] Client disconnected before response")
					return
				end

				if not ok then
					llog("[MCP] Request handler error: " .. tostring(response_str))
					response_client:Send(
						http.HTTPResponse(
							"500",
							"Internal Error",
							{
								["Content-Type"] = "application/json",
							},
							jsonrpc_response(nil, {error = {code = -32603, message = tostring(response_str)}})
						)
					)
					response_client:Close()
					return
				end

				if response_str then
					llog("[MCP] Sending response, size: " .. #response_str .. " bytes")
					response_client:Send(
						http.HTTPResponse(
							"200",
							"OK",
							{
								["Content-Type"] = "application/json",
							},
							response_str
						)
					)
				else
					llog("[MCP] Sending 202 No Content")
					response_client:Send(
						http.HTTPResponse(
							"202",
							"No Content",
							{
								["Content-Type"] = "application/json",
							}
						)
					)
				end

				if response_client:IsValid() then
					llog("[MCP] Closing connection")
					response_client:Close()
				end
			end,
			nil,
			true -- run immediately
		)
	end

	local ok, err = server:Host("0.0.0.0", port)

	if ok then
		llog("[MCP] HTTP server started on port " .. port)
		llog("[MCP] connection url: http://localhost:" .. port .. "/mcp")
	else
		wlog("[MCP] failed to start: " .. tostring(err))
	end
end

if HOTRELOAD then mcp.StartServer() end

return mcp
