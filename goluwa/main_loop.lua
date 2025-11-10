local system = require("system")
local event = require("event")
local last_time = 0
local i = 0
event.Call("Initialize")

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

event.Call("ShutDown")
