local commands = import("goluwa/cli/commands.lua")
local input = import("goluwa/input.lua")
local profiler = import("goluwa/profiler.lua")
local started = false

local function toggle()
	if not started then
		profiler.Start("game", {trace_recorder = false})
		started = true
		logn("profiler started")
	else
		profiler.Stop()
		started = false
		logn("profiler stopped")
	end
end

commands.Add("profile", function()
	toggle()
end)

input.Bind("p", "profile")
