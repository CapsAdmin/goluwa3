require("goluwa.global_environment")
--
local system = require("system")
local profiler = require("profiler") -- init started in global_environment.lua
local event = require("event")
local process = require("bindings.process")
local fs = require("fs")
local vfs = require("vfs")
local tasks = require("tasks")
local commands = require("commands")
require("helpers.test") -- add test command
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

return function(...)
	if ... then
		local args = {...}
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

	if _G.PROFILE then
		profiler.Stop("init")
		profiler.Start("update")
	end

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

	if _G.PROFILE then profiler.Stop("update") end

	event.Call("ShutDown")
	fs.remove_file(".running_pid")
	os.realexit(os.exitcode) -- no need to wait for gc!!1
end
