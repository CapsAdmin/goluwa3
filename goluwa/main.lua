require("goluwa.global_environment")
--
local crash_trace = import("goluwa/crash_trace.lua")
crash_trace.Install()
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local process = import("goluwa/bindings/process.lua")
local fs = import("goluwa/fs.lua")
local vfs = import("goluwa/vfs.lua")
local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/commands.lua")
import.loadfile = vfs.LoadFile
vfs.MountStorageDirectories()
_G.R = vfs.GetAbsolutePath
import("goluwa/helpers/test.lua") -- add test command
local function normalize_path(path)
	local wdir = vfs.GetStorageDirectory("working_directory")

	if path:starts_with(wdir) then path = path:sub(#wdir + 1, #path) end

	return path
end

commands.Add("run", function(path, ...)
	local path = normalize_path(path)
	assert(loadfile(path))(...)
end)

commands.Add("lua", function(code, ...)
	assert(loadstring(code))(...)
end)

commands.Add("reload", function(path, ...)
	path = normalize_path(path)
	assert(loadfile(path))(...)
end)

commands.Add("cli", function(path, ...)
	_G.GRAPHICS = false
	_G.AUDIO = true
	assert(loadfile("game/run.lua"))()
end)

local function shutdown_and_exit(code, remove_pid)
	event.Call("ShutDown")

	if remove_pid then fs.remove_file(".running_pid") end

	os.realexit(code or os.exitcode or 0)
end

return function(...)
	local argv = {...}
	return crash_trace.Run(function()
		if argv[1] then
			local args = argv
			local cmd = args[1]

			if cmd == "-e" then
				cmd = "lua"
			elseif cmd == "--reload" then
				cmd = "reload"
			elseif cmd:ends_with(".lua") then
				cmd = "run"
				args = {"run", cmd, unpack(args, 2)}
			end

			args[1] = cmd

			if cmd == "lua" then
				if _G.GRAPHICS ~= false then _G.GRAPHICS = true end

				_G.AUDIO = true
				assert(loadfile("game/run.lua"))()
				event.Call("Initialize")
				commands.RunArguments(args)
				shutdown_and_exit(os.exitcode or 0)
			end

			commands.RunArguments(args)
		else
			_G.GRAPHICS = true
			_G.AUDIO = true
			assert(loadfile("game/run.lua"))()
		end

		fs.write_file(".running_pid", tostring(process.current:get_id()))
		local last_time = system.GetTime()
		local i = 0
		event.Call("Initialize")

		while system.IsRunning() and not os.exitcode do
			local time = system.GetTime()
			local dt = time - (last_time or 0)
			--if dt > 0.1 then print("LONG FRAME", dt) end
			system.SetFrameTime(dt)
			system.SetFrameNumber(i)
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			event.Call("Update", dt)
			system.SetInternalFrameTime(system.GetTime() - time)
			i = i + 1
			last_time = time
			event.Call("FrameEnd")
		end

		shutdown_and_exit(os.exitcode, true)
	end)
end
