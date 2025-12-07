local jit_profiler = require("helpers.jit_profiler")
local TraceTrack = require("helpers.jit_trace_track")
local timer = require("timer")
local profile_stop, profile_report
local trace_tracker
local profiler = {}
local f

local function save_progress()
	if trace_tracker then
		f:write(trace_tracker:GetReportProblematicTraces() .. "\n")
	end

	if profile_report then f:write(profile_report() .. "\n") end

	f:flush()
	f:seek("set", 0)
end

function profiler.Start(id)
	trace_tracker = TraceTrack.New()
	trace_tracker:Start()
	profile_stop, profile_report = jit_profiler.Start()
	f = assert(io.open("logs/profiler_" .. id .. ".txt", "w"))
	timer.Repeat("debug", 1, math.huge, save_progress)
end

function profiler.Stop()
	save_progress()
	f:close()
	profile_stop()

	if trace_tracker then trace_tracker:Stop() end

	timer.RemoveTimer("debug")
end

return profiler
