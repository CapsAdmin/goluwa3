local event = require("event")
local render = require("graphics.render")
local system = require("system")
local jit_profiler = require("helpers.jit_profiler")
local jit_trace_track = require("helpers.jit_trace_track")
local profile_stop, profile_report
local trace_stop, trace_report
local timer = require("timer")
local input = require("input")

event.AddListener("KeyInput", "renderdoc", function(key, press)
	if not press then return end

	--if key == "f8" then render.renderdoc.CaptureFrame() end
	if key == "f11" then render.renderdoc.OpenUI() end

	if key == "t" then
		if not trace_stop then
			trace_stop, trace_report = jit_trace_track.Start()
		else
			trace_stop()
			trace_stop = nil
		end
	end

	if key == "p" then
		if not profile_stop then
			profile_stop, profile_report = jit_profiler.Start()
		else
			profile_stop()
			profile_stop = nil
		end
	end

	if key == "c" and input.IsKeyDown("left_control") then system.ShutDown(0) end
end)

timer.Repeat(
	"debug",
	0.5,
	math.huge,
	function()
		if trace_report then
			print(jit_trace_track.ToStringProblematicTraces(trace_report()))
		end

		if profile_report then print(profile_report()) end
	end
)
