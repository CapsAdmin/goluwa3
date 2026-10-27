local json = import("goluwa/codecs/json.lua")
local base64 = import("goluwa/codecs/base64.lua")
local callback = import("goluwa/callback.lua")
local clients = import("goluwa/network/clients.lua")
local network = import("goluwa/network/network.lua")
local process = import("goluwa/bindings/process.lua")
local system = import("goluwa/system.lua")
local vfs = import("goluwa/vfs.lua")
local mcp = import("addons/mcp/lua/mcp.lua")
mcp.AddTool(
	"run_lua",
	{
		description = "Run Lua in this process (the engine's global environment) and return what it printed plus its return values. A single expression returns its value; statements need an explicit return.",
		inputSchema = {
			type = "object",
			properties = {code = {type = "string", description = "The Lua code to run."}},
			required = {"code"},
		},
		callback = function(args)
			local func, err = load("return " .. args.code, "mcp_lua", "t")

			if not func then func, err = load(args.code, "mcp_lua", "t") end

			if not func then
				return {content = {{type = "text", text = err}}, isError = true}
			end

			local printed, result = mcp.Capture(function()
				return xpcall(func, debug.traceback)
			end)
			local out = {}

			if printed ~= "" then table.insert(out, printed) end

			if not result[1] then
				local message = tostring(result[2])
				table.insert(out, "error: " .. (message:match("^(.-)\n%s*%[C%]: in function 'func'") or message))
				return {content = {{type = "text", text = table.concat(out, "\n")}}, isError = true}
			end

			for i = 2, result.n do
				table.insert(out, "=> " .. table.tostring(result[i]))
			end

			return table.concat(out, "\n")
		end,
	}
)
mcp.AddTool(
	"get_logs",
	{
		description = "Recent output of this process (everything printed since the mcp addon loaded, last 4000 lines), colors stripped.",
		inputSchema = {
			type = "object",
			properties = {
				lines = {type = "number", description = "How many lines to return (default 50)."},
				pattern = {type = "string", description = "Only lines matching this Lua pattern."},
			},
		},
		callback = function(args)
			return table.concat(mcp.GetLogLines(args.lines or 50, args.pattern), "\n")
		end,
	}
)
mcp.AddTool(
	"screenshot",
	{
		description = "Capture the frame this process is rendering and save it as a PNG; returns the path. Errors in a headless process.",
		inputSchema = {
			type = "object",
			properties = {
				inline = {type = "boolean", description = "Also return the image data in the response."},
			},
		},
		callback = function(args)
			local path = vfs.GetStorageDirectory("storage") .. "mcp/screenshot_" .. mcp.Role .. ".png"
			local cb = callback.Create()

			Screenshot(function(texture)
				cb:Resolve(texture:SaveWithoutAlpha(path))
			end)

			local saved = cb:Get()
			local content = {{type = "text", text = tostring(saved)}}

			if args.inline then
				local file = assert(io.open(path, "rb"))
				table.insert(content, mcp.Image(base64.Encode(file:read("*a")), "image/png"))
				file:close()
			end

			return {content = content}
		end,
	}
)
mcp.AddTool(
	"info",
	{
		description = "Which process this is: role, pid, flags, network state, frame and time, and the clients it knows.",
		inputSchema = {type = "object", properties = json.createEmptyObject()},
		callback = function()
			local players = {}

			for _, client in ipairs(clients.GetAll()) do
				table.insert(
					players,
					{
						nick = client:GetNick(),
						id = client:GetUniqueID(),
						ping = client:GetPing(),
						bot = client:IsBot(),
					}
				)
			end

			return {
				role = mcp.Role,
				pid = process.current:get_id(),
				port = mcp.port,
				arguments = system.GetStartupArguments(),
				server = SERVER or false,
				client = CLIENT or false,
				server_client = SERVER_CLIENT or false,
				render_2d = RENDER_2D or false,
				render_3d = RENDER_3D or false,
				physics = PHYSICS or false,
				connected = CLIENT and network.IsConnected() or false,
				hosting = SERVER and network.IsHosting() or false,
				frame = system.GetFrameNumber(),
				time = system.GetTime(),
				players = players,
			}
		end,
	}
)
