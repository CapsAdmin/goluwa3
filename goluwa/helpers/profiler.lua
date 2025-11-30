local profiler = {}
local jit_profiler = require("helpers.jit_profiler")
local jit_trace_track = require("helpers.jit_trace_track")

function profiler.Start()
	local trace_stop, trace_report = jit_trace_track.Start()
	local profile_stop, profile_report = jit_profiler.Start()
	return function()
		if trace_report then
			print(jit_trace_track.ToStringProblematicTraces(trace_report()))
		end

		if profile_report then print(profile_report()) end

		if trace_stop then
			trace_stop()
			trace_stop = nil
		end

		if profile_stop then
			profile_stop()
			profile_stop = nil
		end
	end
end

return profiler
