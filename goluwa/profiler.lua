local JitProfiler = import("goluwa/jit/profiler.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local profiler = library()
local jit_profiler
local summary_on_stop

function profiler.Start(id, config)
	config = config or {}
	local batch = config.shutdown_after_frames ~= nil
	local format = config.format or (batch and "bin" or "html")
	local path = config.path or
		(
			"storage/logs/jit_profile_" .. id .. (
				format == "bin" and
				".glwp" or
				".html"
			)
		)
	local directory = fs.get_parent_directory(path)

	if directory and directory ~= "." then
		assert(fs.create_directory_recursive(directory))
	end

	summary_on_stop = config.summary == true or (config.summary == nil and batch and format == "bin")

	local function begin()
		jit_profiler = JitProfiler.New{
			id = id,
			path = path,
			file_url = "vscode://file" .. fs.get_current_directory() .. "/${path}:${line}:1",
			get_time = system.GetTime,
			format = format,
			sampling_rate = config.sampling_rate or 1,
			flush_interval = config.flush_interval or 1,
			trace_recorder = config.trace_recorder,
			profile_mode = config.profile_mode,
		}

		if config.shutdown_after_frames then
			local stop_at = system.GetFrameNumber() + config.shutdown_after_frames

			event.AddListener("Update", "profiler_auto_stop", function()
				if system.GetFrameNumber() >= stop_at then
					event.RemoveListener("Update", "profiler_auto_stop")
					profiler.Stop()
					system.ShutDown(0)
				end
			end)
		end
	end

	if config.skip_frames then
		local start_at = system.GetFrameNumber() + config.skip_frames

		event.AddListener("Update", "profiler_auto_start", function()
			if system.GetFrameNumber() >= start_at then
				event.RemoveListener("Update", "profiler_auto_start")
				begin()
			end
		end)
	else
		begin()
	end
end

function profiler.Stop()
	if not jit_profiler then return end

	local path = jit_profiler.path
	jit_profiler:Stop()
	jit_profiler = nil
	event.RemoveListener("Update", "profiler_auto_stop")

	if summary_on_stop then return JitProfiler.Summary(path) end
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
