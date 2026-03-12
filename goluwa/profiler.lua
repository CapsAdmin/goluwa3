local JitProfiler = import("goluwa/helpers/jit_profiler.lua")
local system = import("goluwa/system.lua")
local profiler = library()
local jit_profiler

function profiler.Start(id)
	time_start = system.GetTime()
	jit_profiler = JitProfiler.New{
		path = "logs/jit_profile_" .. id .. ".html",
		file_url = "vscode://file/${path}:${line}:1",
		get_time = system.GetTime,
	}
end

function profiler.Stop()
	jit_profiler:Stop()
end

local simple_times = {}
local simple_stack = {}

function profiler.StartSection(name--[[#: string]])
	simple_times[name] = simple_times[name] or {total = 0}
	simple_times[name].time = system.GetTime()
	table.insert(simple_stack, name)

	if not jit_profiler then return end

	jit_profiler:StartSection(name)
end

function profiler.StopSection()
	local name = table.remove(simple_stack)
	simple_times[name].total = simple_times[name].total + (system.GetTime() - simple_times[name].time)

	if not jit_profiler then return end

	jit_profiler:StopSection()
end

function profiler.GetSimpleSections()
	return simple_times
end

return profiler