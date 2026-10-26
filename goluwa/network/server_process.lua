local ffi = require("ffi")
local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local command_input = import("goluwa/cli/command_input.lua")
local commands = import("goluwa/cli/commands.lua")
local crypto = import("goluwa/crypto.lua")
local vfs = import("goluwa/vfs.lua")
local process = import("goluwa/bindings/process.lua")
local server_process = {}
local worker_source = [[
	local input = ...
	_G.SERVER_READY_FLAG = require("ffi").cast("uint8_t *", input.ready)
	_G.SERVER_COMMAND_TOKEN = input.token
	package.path = package.path .. ";" .. input.root .. "?.lua"
	require("goluwa.global_environment")
	local startup_arguments = import("goluwa/system.lua").GetStartupArguments()

	for i, argument in ipairs(input.arguments) do
		startup_arguments[i] = argument
	end

	require("goluwa.main")
]]
local MAX_COMMAND_LENGTH = 4096

function server_process.IsActive()
	return server_process.token ~= nil
end

if CLIENT then
	function server_process.RunCommand(str)
		message.Send("server_command", server_process.token, str)
	end

	message.AddListener("server_command_result", function(output, ok, error_message)
		for line in output:gmatch("[^\n]+") do
			event.Call("Chat", "console", (line:gsub("\t", "    ")), NULL)
		end

		if not ok then event.Call("Chat", "error", error_message, NULL) end
	end)

	function server_process.Start(port, arguments)
		assert(not server_process.token, "server process already started")
		local threads = import("goluwa/bindings/threads.lua")
		local ready = ffi.new("uint8_t[1]")
		local token = crypto.SHA256(
			table.concat(
				{os.time(), os.clock(), process.current:get_id(), tostring({}), math.random()},
				":"
			)
		)
		process.setenv("GOLUWA_PORT", tostring(port))
		process.setenv("GOLUWA_IP", "127.0.0.1")
		local thread = threads.new(worker_source)
		thread:run{
			ready = tonumber(ffi.cast("uintptr_t", ready)),
			token = token,
			root = vfs.GetStorageDirectory("root"),
			arguments = arguments,
		}
		server_process.thread = thread
		server_process.ready = ready
		server_process.token = token

		event.AddListener("Update", "server_process", function()
			if thread:is_done() then
				local _, err = thread:join()
				llog("server thread exited: %s", tostring(err))
				return event.destroy_tag
			end

			if ready[0] == 0 then return end

			logf("connecting to the server process at 127.0.0.1:%i\n", port)
			network.Connect("127.0.0.1", port)
			return event.destroy_tag
		end)
	end
end

if SERVER then
	message.AddListener("server_command", function(client, token, str)
		if not _G.SERVER_COMMAND_TOKEN or token ~= _G.SERVER_COMMAND_TOKEN then
			wlog("%s tried to run a command without the server token", client)
			return
		end

		if #str > MAX_COMMAND_LENGTH then return end

		commands.SetClient(client)
		local called, output, ok, error_message = pcall(command_input.Run, str)
		commands.SetClient(NULL)

		if not called then output, ok, error_message = "", false, output end

		message.Send("server_command_result", client, output, ok, error_message or "")
	end)

	function server_process.NotifyReady()
		if _G.SERVER_READY_FLAG then _G.SERVER_READY_FLAG[0] = 1 end
	end
end

return server_process
