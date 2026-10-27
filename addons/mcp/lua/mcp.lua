local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local http = import("goluwa/sockets/http.lua")
local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")
local process = import("goluwa/bindings/process.lua")
local system = import("goluwa/system.lua")
local tasks = import("goluwa/tasks.lua")
local HTTPServer = import("goluwa/sockets/http/http11_server.lua")
local mcp = {}
mcp.PORT_START = 8600
mcp.PORT_COUNT = 64
mcp.LOG_LIMIT = 4000
mcp.tools = mcp.tools or {}
mcp.server = mcp.server or NULL
mcp.log_lines = mcp.log_lines or {}
mcp.log_total = mcp.log_total or 0
mcp.log_partial = mcp.log_partial or ""
mcp.Role = SERVER and "server" or "client"

function mcp.AddTool(name, tool)
	mcp.tools[name] = tool
end

function mcp.Text(text)
	return {content = {{type = "text", text = text}}}
end

function mcp.Image(base64, mime_type)
	return {type = "image", data = base64, mimeType = mime_type}
end

do
	local lines = mcp.log_lines
	local limit = mcp.LOG_LIMIT

	event.AddListener("StdOutWrite", "mcp_log", function(str)
		local start = 1

		while true do
			local stop = str:find("\n", start, true)

			if not stop then
				mcp.log_partial = mcp.log_partial .. str:sub(start)

				break
			end

			mcp.log_total = mcp.log_total + 1
			lines[mcp.log_total % limit] = mcp.log_partial .. str:sub(start, stop - 1)
			mcp.log_partial = ""
			start = stop + 1
		end
	end)

	local function strip(line)
		return (line:gsub("\27%[[%d;]*m", ""))
	end

	function mcp.GetLogLines(count, pattern, after)
		local result = {}
		local first = math.max(mcp.log_total - limit + 1, (after or 0) + 1)

		for i = mcp.log_total, first, -1 do
			local line = strip(lines[i % limit])

			if not pattern or line:find(pattern) then
				table.insert(result, 1, line)

				if #result >= count then break end
			end
		end

		return result
	end

	function mcp.Capture(func)
		local before = mcp.log_total
		local result = list.pack(func())
		local captured = mcp.GetLogLines(limit, nil, before)

		if mcp.log_partial ~= "" then
			table.insert(captured, strip(mcp.log_partial))
		end

		return table.concat(captured, "\n"), result
	end
end

local function jsonrpc_result(id, result)
	return json.encode{jsonrpc = "2.0", id = id, result = result}
end

local function jsonrpc_error(id, code, message)
	return json.encode{
		jsonrpc = "2.0",
		id = id,
		error = {code = code, message = message},
	}
end

local function handle_request(json_str)
	local ok, request = pcall(json.decode, json_str)

	if not ok or type(request) ~= "table" then
		return jsonrpc_error(nil, -32700, "Parse error")
	end

	local method = request.method
	local params = request.params or {}
	local id = request.id

	if method == "initialize" then
		return jsonrpc_result(
			id,
			{
				protocolVersion = "2024-11-05",
				capabilities = {tools = json.createEmptyObject()},
				serverInfo = {name = "goluwa-" .. mcp.Role, version = "1.0.0"},
			}
		)
	end

	if method:starts_with("notifications/") then return nil end

	if method == "ping" then return jsonrpc_result(id, json.createEmptyObject()) end

	if method == "tools/list" then
		local definitions = {}

		for name, tool in pairs(mcp.tools) do
			table.insert(
				definitions,
				{name = name, description = tool.description, inputSchema = tool.inputSchema}
			)
		end

		table.sort(definitions, function(a, b)
			return a.name < b.name
		end)

		return jsonrpc_result(id, {tools = definitions})
	end

	if method == "tools/call" then
		local tool = mcp.tools[params.name]

		if not tool then
			return jsonrpc_error(id, -32602, "Tool not found: " .. tostring(params.name))
		end

		local ok, result = xpcall(tool.callback, debug.traceback, params.arguments or {})

		if not ok then
			return jsonrpc_result(id, {content = {{type = "text", text = tostring(result)}}, isError = true})
		end

		if type(result) == "string" then result = mcp.Text(result) end

		if not result.content then result = mcp.Text(json.encode(result)) end

		return jsonrpc_result(id, result)
	end

	return jsonrpc_error(id, -32601, "Method not found: " .. tostring(method))
end

local pending_clients = setmetatable({}, {__mode = "k"})

local function respond(client, code, status, body)
	client:Send(http.HTTPResponse(code, status, {["Content-Type"] = "application/json"}, body))
end

local function process_body(client, body)
	local ok, response = pcall(handle_request, body)

	if not client:IsValid() then return end

	if not ok then
		respond(client, "500", "Internal Error", jsonrpc_error(nil, -32603, tostring(response)))
	elseif response then
		respond(client, "200", "OK", response)
	else
		client:Send(http.HTTPResponse("202", "Accepted", {}))
	end

	if client:IsValid() then client:Close() end
end

local function on_receive_response(self, client, method, path)
	if path ~= "/mcp" and path ~= "/" then
		respond(client, "404", "Not Found", jsonrpc_error(nil, -32601, "Not Found"))
		return
	end

	if method ~= "POST" then
		respond(
			client,
			"405",
			"Method Not Allowed",
			jsonrpc_error(nil, -32601, "Method Not Allowed")
		)
		return
	end

	pending_clients[client] = true
end

local function on_receive_body(self, client, body)
	if not pending_clients[client] then return end

	pending_clients[client] = nil
	client:SetAutoClose(false)
	tasks.CreateTask(function()
		process_body(client, body)
	end, nil, true)
end

function mcp.RegistryPath()
	return vfs.GetStorageDirectory("storage") .. "mcp/" .. process.current:get_id() .. "_" .. mcp.Role .. ".json"
end

function mcp.StartServer()
	if mcp.server:IsValid() then mcp.server:Remove() end

	for port = mcp.PORT_START, mcp.PORT_START + mcp.PORT_COUNT - 1 do
		local server = HTTPServer.New()
		server.OnReceiveResponse = on_receive_response
		server.OnReceiveBody = on_receive_body

		if pcall(server.Host, server, "127.0.0.1", port) then
			mcp.server = server
			mcp.port = port
			fs.create_directory_recursive(vfs.GetStorageDirectory("storage") .. "mcp/")
			fs.write_file(
				mcp.RegistryPath(),
				json.encode{
					pid = process.current:get_id(),
					role = mcp.Role,
					port = port,
					started = os.time(),
					args = system.GetStartupArguments(),
				}
			)

			event.AddListener("ShutDown", "mcp_registry", function()
				os.remove(mcp.RegistryPath())
			end)

			return port
		end
	end

	wlog(
		"[MCP] no free port in %i-%i",
		mcp.PORT_START,
		mcp.PORT_START + mcp.PORT_COUNT - 1
	)
end

return mcp
