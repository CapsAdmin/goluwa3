local profiler = require("profiler") -- init started in global_environment.lua
require("game.init")

do
	local system = require("system")
	local event = require("event")
	local process = require("bindings.process")
	local fs = require("fs")
	require("hotreload")

	do
		fs.write_file(".running_pid", tostring(process.current:get_id()))
		local last_time = 0
		local i = 0
		event.Call("Initialize")

		if _G.PROFILE then
			profiler.Stop("init")
			profiler.Start("update")
		end

		while system.run == true do
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
	end

	os.realexit(0) -- no need to wait for gc!!1
end
