local jit_profiler = require("helpers.jit_profiler")
local jit_trace_track = require("helpers.jit_trace_track")
local timer = require("timer")
local profile_stop, profile_report
local trace_stop, trace_report
local profiler = {}

function profiler.Start()
	trace_stop, trace_report = jit_trace_track.Start()
	profile_stop, profile_report = jit_profiler.Start()
	local f = io.open("logs/profiler.txt", "w")

	timer.Repeat(
		"debug",
		1,
		math.huge,
		function()
			f:write(os.clock() .. "\n")

			if trace_report then
				f:write(jit_trace_track.ToStringProblematicTraces(trace_report()) .. "\n")
			end

			if profile_report then f:write(profile_report() .. "\n") end

			f:flush()
			f:seek("set", 0)
		end
	)
end

function profiler.Stop()
	profile_stop()
	trace_stop()
	timer.RemoveTimer("debug")
end

return profiler
