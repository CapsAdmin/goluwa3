local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local benchmark_results = import("goluwa/benchmark_results.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local frame_benchmark = library()
-- the scene counts as settled after this many seconds without a change to the
-- bvh and without a frame longer than SETTLE_MAX_FRAME
local SETTLE_QUIET = 3
local SETTLE_MAX_FRAME = 0.2
local LOAD_TIMEOUT = 600
-- meters a moving phase goes out before it turns around
frame_benchmark.TRAVEL = 30
local percentile_names = {50, 95, 99}
-- draw calls per frame may vary this much between seconds of a still phase before the
-- run is called unstable
local DRAWS_STABLE_SPREAD = 0.25
local WORST_FRAMES = 3
-- the same code in two processes differs by this much (measured: a gpu pass moved
-- 20% between identical runs), so a difference smaller than these shares of a
-- number is not reported. the seconds inside one run vary far less than this
local RUN_TO_RUN_NOISE = {frame = 0.04, tail = 0.08, gpu = 0.05, scope = 0.12}
local stats_current = render_stats.Get().current

local function standard_deviation(values)
	if #values < 2 then return 0 end

	local sum = 0

	for _, value in ipairs(values) do
		sum = sum + value
	end

	local mean = sum / #values
	local variance = 0

	for _, value in ipairs(values) do
		variance = variance + (value - mean) ^ 2
	end

	return math.sqrt(variance / #values)
end

frame_benchmark.default_phases = {
	{name = "static"},
	{name = "rotating 30 deg/s", yaw_speed = 30},
	{name = "rotating 90 deg/s", yaw_speed = 90},
	{name = "moving 10 m/s", speed = 10},
	{name = "moving 20 m/s", speed = 20},
}

local function print_result(...)
	print("[RESULT] " .. string.format(...))
end

local function summarize(frame_times)
	table.sort(frame_times)
	local count = #frame_times
	local total = 0

	for i = 1, count do
		total = total + frame_times[i]
	end

	local summary = {
		frames = count,
		seconds = total,
		average_ms = total / count * 1000,
		fps = count / total,
		max_ms = frame_times[count] * 1000,
	}

	for _, p in ipairs(percentile_names) do
		summary["p" .. p .. "_ms"] = frame_times[math.ceil(count * p / 100)] * 1000
	end

	return summary
end

-- config:
--   name       label for the report
--   load       function that starts loading the scene, e.g. runs a map command
--   view       function returning position (vec3), pitch and yaw in degrees, called once the scene settled
--   fov        vertical field of view in degrees, the current camera's by default
--   phases     list of {name, yaw_speed = deg/s, speed = m/s, travel = m out and back, enter, ready}, defaults to frame_benchmark.default_phases
--              enter(phase) runs when the phase starts, ready() is polled until it returns true before the lead in starts
--   settle_quiet seconds the scene bvh must stay unchanged before the benchmark starts (3)
--   warmup     seconds to run the first phase before measuring (10)
--   lead_in    seconds each phase runs before it is measured (3)
--   measure    seconds each phase is measured for (20)
--   done       function(results) called when every phase was measured, the engine shuts down after
-- one process measures all phases, each one starting from the same view. frame
-- times come from system.GetTime, gpu scopes from gpu_timing
function frame_benchmark.Run(config)
	local phases = config.phases or frame_benchmark.default_phases
	local warmup = config.warmup or 10
	local lead_in = config.lead_in or 3
	local measure = config.measure or 20

	if os.getenv("GOLUWA_DEBUG") == "1" then
		print_result("WARNING: --debug enables the Vulkan validation layers, cpu times are about 3x too high")
	end

	if HOT_RELOAD then
		print_result("WARNING: --hot-reload is on, editing a goluwa file during the run can crash it")
	end

	-- the draw call counters only run with render.stats, the overlay itself is not wanted
	render.stats = true
	render.stats_overlay = false
	local results = {name = config.name, phases = {}}
	local saved = benchmark_results.New(config.name)
	-- one second of frames at a time, the spread between those seconds is the noise of a phase
	local chunk_time, chunk_frames, chunk_draws = 0, 0, 0
	local chunk_ms, chunk_draw_averages = {}, {}
	local worst = {}
	local last_draw_calls = 0
	local total_draws = 0
	local start = system.GetTime()
	local mode = "load"
	local mode_start = start
	local last = start
	local last_version, version_since
	local view, start_position, start_pitch, start_yaw
	local phase_start
	local phase_index = 1
	local frame_times = {}
	local gpu_previous, gpu_updates, gpu_sums = {}, {}, {}
	local allocated_kb, last_heap_kb
	local entered_index = 0

	local function begin_phase(now, next_mode)
		phase_start = now
		mode = next_mode
		mode_start = now

		if entered_index ~= phase_index then
			entered_index = phase_index

			if phases[phase_index].enter then phases[phase_index].enter(phases[phase_index]) end
		end
	end

	local function finish_phase(now)
		local phase = phases[phase_index]
		local summary = summarize(frame_times)
		summary.name = phase.name
		summary.allocated_mb_per_second = allocated_kb / 1024 / summary.seconds
		summary.gpu = {}
		local shadows = 0

		for name, sum in pairs(gpu_sums) do
			summary.gpu[name] = {
				ms_per_frame = sum / summary.frames,
				ms_per_update = sum / gpu_updates[name],
				updates_per_frame = gpu_updates[name] / summary.frames,
			}

			if name:find("^shadow_") then shadows = shadows + sum / summary.frames end
		end

		local gpu_frame = summary.gpu.gpu_frame and summary.gpu.gpu_frame.ms_per_frame or 0
		summary.gpu_total_ms = gpu_frame + shadows
		summary.noise_ms = standard_deviation(chunk_ms)
		summary.draws_per_frame = total_draws / summary.frames
		results.phases[#results.phases + 1] = summary
		print_result(
			"%s: %d frames, avg %.2f ms (%.1f fps), p50 %.2f p95 %.2f p99 %.2f max %.2f ms, allocating %.1f MB/s",
			phase.name,
			summary.frames,
			summary.average_ms,
			summary.fps,
			summary.p50_ms,
			summary.p95_ms,
			summary.p99_ms,
			summary.max_ms,
			summary.allocated_mb_per_second
		)
		print_result(
			"  gpu %s: frame %.3f + shadows %.3f = %.3f ms",
			gpu_timing.IsSerialized() and "serialized" or "overlapping",
			gpu_frame,
			shadows,
			summary.gpu_total_ms
		)
		local sorted = {}

		for name, gpu in pairs(summary.gpu) do
			if name ~= "gpu_frame" and not name:find("^shadow_") then
				sorted[#sorted + 1] = {name, gpu}
			end
		end

		table.sort(sorted, function(a, b)
			return a[2].ms_per_frame > b[2].ms_per_frame
		end)

		for i = 1, math.min(#sorted, 8) do
			print_result(
				"  gpu %-30s %7.3f ms/frame  %7.3f ms per update  %.2f updates/frame",
				sorted[i][1],
				sorted[i][2].ms_per_frame,
				sorted[i][2].ms_per_update,
				sorted[i][2].updates_per_frame
			)
		end

		print_result("  draw calls per frame %.0f, frame time varies %.2f ms between seconds", summary.draws_per_frame, summary.noise_ms)

		if summary.max_ms > 2 * summary.p50_ms and summary.max_ms > 20 then
			local parts = {}

			table.sort(worst, function(a, b)
				return a.ms > b.ms
			end)

			for i = 1, math.min(#worst, WORST_FRAMES) do
				parts[i] = string.format("%.1f ms at +%.1f s", worst[i].ms, worst[i].at)
			end

			print_result("  slowest frames: %s", table.concat(parts, ", "))
		end

		local lowest, highest = math.huge, 0

		for _, draws in ipairs(chunk_draw_averages) do
			lowest = math.min(lowest, draws)
			highest = math.max(highest, draws)
		end

		-- turning or moving changes what is in view, only a still camera should draw the same all the time
		local still = not phase.yaw_speed and not phase.speed

		if still and highest > 0 and (highest - lowest) / highest > DRAWS_STABLE_SPREAD then
			print_result(
				"  WARNING draw calls per frame went from %.0f to %.0f within the phase, the scene state changed while measuring",
				lowest,
				highest
			)
		end

		saved:Add(phase.name .. "/avg_ms", summary.average_ms, math.max(summary.noise_ms, RUN_TO_RUN_NOISE.frame * summary.average_ms), "ms")
		saved:Add(phase.name .. "/p95_ms", summary.p95_ms, math.max(2 * summary.noise_ms, RUN_TO_RUN_NOISE.tail * summary.p95_ms), "ms")
		saved:Add(phase.name .. "/gpu_total_ms", summary.gpu_total_ms, RUN_TO_RUN_NOISE.gpu * summary.gpu_total_ms, "ms")
		saved:AddFingerprint(phase.name .. "/draws_per_frame", summary.draws_per_frame)

		for _, gpu in ipairs(sorted) do
			if gpu[2].ms_per_frame >= 0.2 then
				saved:Add(phase.name .. "/gpu/" .. gpu[1], gpu[2].ms_per_frame, RUN_TO_RUN_NOISE.scope * gpu[2].ms_per_frame, "ms")
			end
		end

		phase_index = phase_index + 1

		if not phases[phase_index] then
			event.RemoveListener("Update", "frame_benchmark")
			saved:Finish()

			if config.done then config.done(results) end

			system.ShutDown(0)
			return
		end

		begin_phase(now, "lead_in")
	end

	event.AddListener("Update", "frame_benchmark", function()
		local now = system.GetTime()
		local dt = now - last
		last = now

		if mode == "load" then
			if now - start > LOAD_TIMEOUT then
				print_result("gave up waiting for the scene to load")
				system.ShutDown(1)
				return
			end

			if not scene_bvh.readied or scene_loading.IsLoading() then return end

			if scene_bvh.version ~= last_version then
				last_version = scene_bvh.version
				version_since = now
			end

			if now - version_since >= (config.settle_quiet or SETTLE_QUIET) and dt < SETTLE_MAX_FRAME then
				start_position, start_pitch, start_yaw = config.view()
				view = View.New{
					Priority = 100,
					Position = start_position,
					Rotation = QuatDeg3(start_pitch, start_yaw, 0),
					FOV = config.fov and math.rad(config.fov) or nil,
				}:Activate()
				results.load_seconds = now - start
				results.blocks = #scene_bvh.blocks
				results.triangles = scene_bvh.triangle_count
				print_result(
					"%s settled after %.0f s: %d blocks, %d triangles",
					config.name,
					results.load_seconds,
					results.blocks,
					results.triangles
				)
				begin_phase(now, "warmup")
			end

			return
		end

		local phase = phases[phase_index]
		local phase_time = now - phase_start
		local yaw = start_yaw + (phase.yaw_speed or 0) * phase_time
		local distance = (phase.speed or 0) * phase_time
		local travel = phase.travel or frame_benchmark.TRAVEL
		-- there and back again, so a long run stays in the same part of the scene
		distance = distance % (2 * travel)

		if distance > travel then distance = 2 * travel - distance end

		view:SetPosition(start_position + QuatDeg3(0, start_yaw, 0):GetForward() * distance)
		view:SetRotation(QuatDeg3(start_pitch, yaw, 0))

		if mode == "warmup" then
			if now - mode_start >= warmup then
				begin_phase(now, "lead_in")
			end

			return
		end

		if mode == "lead_in" then
			-- the lead in starts counting once the phase says it is ready
			if phase.ready and not phase.ready() then
				mode_start = now
				return
			end

			if now - mode_start >= lead_in then
				mode = "measure"
				mode_start = now
				frame_times = {}
				gpu_previous, gpu_updates, gpu_sums = {}, {}, {}
				allocated_kb = 0
				last_heap_kb = collectgarbage("count")
				chunk_time, chunk_frames, chunk_draws = 0, 0, 0
				chunk_ms, chunk_draw_averages, worst = {}, {}, {}
				total_draws = 0
				last_draw_calls = stats_current.draw_calls or 0
			end

			return
		end

		frame_times[#frame_times + 1] = dt
		-- the heap only grows by allocating, a drop is the collector running
		local heap_kb = collectgarbage("count")
		allocated_kb = allocated_kb + math.max(heap_kb - last_heap_kb, 0)
		last_heap_kb = heap_kb
		-- the counter restarts every second, a smaller value is that restart
		local draw_calls = stats_current.draw_calls or 0
		local draws = draw_calls >= last_draw_calls and draw_calls - last_draw_calls or draw_calls
		last_draw_calls = draw_calls
		total_draws = total_draws + draws
		chunk_time = chunk_time + dt
		chunk_frames = chunk_frames + 1
		chunk_draws = chunk_draws + draws

		if chunk_time >= 1 then
			chunk_ms[#chunk_ms + 1] = chunk_time / chunk_frames * 1000
			chunk_draw_averages[#chunk_draw_averages + 1] = chunk_draws / chunk_frames
			chunk_time, chunk_frames, chunk_draws = 0, 0, 0
		end

		if dt * 1000 > 20 then
			worst[#worst + 1] = {ms = dt * 1000, at = now - mode_start}
		end
		local names = gpu_timing.GetScopeNames()

		for i = 1, #names do
			local name = names[i]
			local ms = gpu_timing.GetRawMilliseconds(name)

			-- a scope only has a new reading when its value changed, scopes such
			-- as shadow cascades are not re-recorded every frame
			if gpu_previous[name] ~= ms then
				gpu_previous[name] = ms
				gpu_updates[name] = (gpu_updates[name] or 0) + 1
				gpu_sums[name] = (gpu_sums[name] or 0) + ms
			end
		end

		if now - mode_start >= measure then finish_phase(now) end
	end)

	config.load()
end

return frame_benchmark
