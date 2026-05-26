local commands = import("goluwa/commands.lua")
local event = import("goluwa/event.lua")
local profiler = import("goluwa/profiler.lua")
local started = false

local function toggle()
	if not started then
		profiler.Start("game", {trace_recorder = true})
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

event.AddListener("KeyInput", "profiler_toggle", function(key, press)
	if not press then return end

	if key == "p" then toggle() end
end)
