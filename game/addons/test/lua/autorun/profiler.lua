local commands = require("commands")
local profiler = require("profiler")
local started = false

commands.Add("profile", function()
	if not started then
		profiler.Start("test")
		started = true
		logn("profiler started")
	else
		profiler.Stop()
		started = false
		logn("profiler stopped")
	end
end)
