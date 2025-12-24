require("goluwa.global_environment")
--
local system = require("system")
local profiler = require("profiler") -- init started in global_environment.lua
local event = require("event")
local process = require("bindings.process")
local fs = require("fs")
local vfs = require("vfs")

local function normalize_path(path)
	local wdir = vfs.GetStorageDirectory("working_directory")

	if path:starts_with(wdir) then path = path:sub(#wdir + 1, #path) end

	return path
end

return function(...)
	if ... == "-e" then
		local lua = select(2, ...)
		assert(loadstring(lua))(select(3, ...))
		return
	elseif ... == "--reload" then
		local path = select(2, ...)
		path = normalize_path(path)
		assert(loadfile(path))(select(3, ...))

		if not path:starts_with("test/") then return end
	else
		local path = ...
		path = normalize_path(path)
		assert(loadfile(path))(select(2, ...))
	end

	require("hotreload")
	fs.write_file(".running_pid", tostring(process.current:get_id()))
	local last_time = 0
	local i = 0
	event.Call("Initialize")

	if _G.PROFILE then
		profiler.Stop("init")
		profiler.Start("update")
	end

	while system.IsRunning() and not os.exitcode do
		local time = system.GetTime()
		local dt = time - (last_time or 0)
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
