local commands = require("commands")
local Profiler = require("profiler")
local started = false

commands.Add("profile", function()
	if not started then
		Profiler.Start("test")
		started = true
		logn("profiler started")
	else
		Profiler.Stop()
		started = false
		logn("profiler stopped")
	end
end)