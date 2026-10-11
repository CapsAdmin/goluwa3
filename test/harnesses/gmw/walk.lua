local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local walk = {}
local DURATION = tonumber(os.getenv("GMW_WALK") or "90")
local SPRINT = os.getenv("GMW_SPRINT") == "1"
local usercmd = import("goluwa/network/usercmd.lua")
local UP = Vec3(0, 1, 0)
local CHECK = 0.5

local function forward(yaw)
	return QuatDeg3(0, yaw, 0):GetForward()
end

local ROUTE = {
	{172, 180.5, 206}, {190, 180.5, 206}, {190, 180.5, 295}, {80, 180.5, 295}, {80, 180.5, 120}, {190, 180.5, 120},
	{190, 180.5, 206}, {130, 195, 206}, {85, 195, 280}, {185, 195, 280}, {185, 195, 130}, {85, 195, 130},
	{130, 165, 206}, {85, 165, 280}, {185, 165, 280}, {185, 165, 130}, {85, 165, 130}, {172, 180.5, 206},
}
local FLY = os.getenv("GMW_MODE") == "fly"
local FLY_SPEED = tonumber(os.getenv("GMW_SPEED") or "6")

local emitter_stats = {calls = 0, rebuilds = 0, time = 0, rebuild_time = 0, max = 0}
do
	if os.getenv("GMW_EMITTERS") then
		local ddgi = import("goluwa/render3d/ddgi.lua")
		local old = ddgi.GetEmitters
		local last_version
		local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
		local ls, lt, lb = scene_bvh.soup_version, scene_bvh.top_version, scene_bvh.emissive_blocks
		emitter_stats.soup_changed, emitter_stats.top_changed, emitter_stats.blocks_changed = 0, 0, 0
		ddgi.GetEmitters = function(...)
			local t = system.GetTime()
			local e = old(...)
			local dt = system.GetTime() - t
			emitter_stats.calls = emitter_stats.calls + 1
			emitter_stats.time = emitter_stats.time + dt

			if e.version ~= last_version then
				last_version = e.version
				emitter_stats.rebuilds = emitter_stats.rebuilds + 1
				if scene_bvh.soup_version ~= ls then emitter_stats.soup_changed = emitter_stats.soup_changed + 1 end
				if scene_bvh.top_version ~= lt then emitter_stats.top_changed = emitter_stats.top_changed + 1 end
				if scene_bvh.emissive_blocks ~= lb then emitter_stats.blocks_changed = emitter_stats.blocks_changed + 1 end
				ls, lt, lb = scene_bvh.soup_version, scene_bvh.top_version, scene_bvh.emissive_blocks
				emitter_stats.rebuild_time = emitter_stats.rebuild_time + dt
				emitter_stats.max = math.max(emitter_stats.max, dt)
				emitter_stats.count = e.count
			end

			return e
		end
	end
end

function walk.Start(rig)
	STAT_LOG = true STAT_LOGN = 0
	print("STATS_AT_START hide", STAT_HIDE, "write", STAT_WRITE, "same", STAT_SAME, "diff", STAT_DIFF)
	local pos = rig.transform:GetPosition()
	print(string.format("WALK start at %.1f %.1f %.1f", pos.x, pos.y, pos.z))
	local yaw = 0
	local frame_times, prev = {}, system.GetTime()
	local gpu_sums, gpu_prev, gpu_n = {}, {}, {}
	local segment = {}
	local worst = {}
	local began = system.GetTime()
	local heap_prev, alloc = collectgarbage("count"), 0
	local visited = {}
	local last_check, check_pos = began, pos:Copy()
	local next_turn = began + 8
	local turns, stuck_turns = 0, 0
	local total_dist = 0
	local last_pos = pos:Copy()

	local function cell(p)
		return math.floor(p.x / 4) .. "," .. math.floor(p.z / 4)
	end

	local target_index = 2
	local fly_view = QuatDeg3(0, 0, 0)
	local fwd90 = forward(90)
	print(string.format("forward(90) = %.2f %.2f %.2f", fwd90.x, fwd90.y, fwd90.z))

	if FLY then
		rig.player_movement:SetFlySpeed(FLY_SPEED)
		rig.player_movement:SetFlySpeedRamp(0)
	end

	local failed = {}
	local jump_until = 0

	local function choose(from, avoid)
		local chest = from + UP * 0.2
		local best, best_score

		for k = 0, 23 do
			local ny = k * 15
			local h = raycast.CastClosest(chest, forward(ny), 25)
			local clear = h and h.distance or 25
			local score = clear

			if not visited[cell(from + forward(ny) * 10)] then score = score + 15 end

			for _, f in ipairs(failed) do
				local dx, dz = f.x - from.x, f.z - from.z

				if dx * dx + dz * dz < 64 and math.abs((ny - f.yaw + 180) % 360 - 180) < 60 then
					score = score - 60
				end
			end

			if not best_score or score > best_score then best, best_score = ny, score end
		end

		return best
	end

	event.AddListener("CreateMove", "gmw_walk", function(owner, cmd)
		cmd.mode = FLY and "fly" or "walk"
		cmd.forward = 1
		cmd.side = 0
		cmd.buttons = bit.bor(cmd.buttons, usercmd.BUTTON.ACTIVE, SPRINT and usercmd.BUTTON.SPRINT or 0, system.GetTime() < jump_until and usercmd.BUTTON.JUMP or 0)
		cmd.view:CopyFrom(FLY and fly_view or QuatDeg3(0, yaw, 0))
	end)

	if os.getenv("GMW_WALKPROF") then PROF.Start("gmw_walk", {shutdown = false, trace_recorder = false}) end

	event.AddListener("Update", "gmw_walk", function()
		local now = system.GetTime()
		local dt = now - prev
		prev = now
		local p = rig.transform:GetPosition()
		total_dist = total_dist + math.sqrt((p.x - last_pos.x) ^ 2 + (p.z - last_pos.z) ^ 2)
		last_pos:Set(p.x, p.y, p.z)
		visited[cell(p)] = true

		if FLY then
			local t = ROUTE[target_index]
			local dx, dy, dz = t[1] - p.x, t[2] - p.y, t[3] - p.z
			local horizontal = math.sqrt(dx * dx + dz * dz)

			if dx * dx + dy * dy + dz * dz < 4 then
				target_index = target_index + 1
			end

			if not ROUTE[target_index] then
				walk.route_done = true
			else
				local yaw_deg = math.deg(math.atan2(-dx, -dz))
				local pitch_deg = math.deg(math.atan2(dy, horizontal))
				fly_view = QuatDeg3(pitch_deg, yaw_deg, 0)
			end
		end

		if now - began > DURATION or walk.route_done then
			event.RemoveListener("Update", "gmw_walk")
			event.RemoveListener("CreateMove", "gmw_walk")
			if os.getenv("GMW_WALKPROF") then PROF.Stop() PROF.Summary("storage/logs/jit_profile_gmw_walk.glwp", {top_n = 45}) end
			local cells = 0
			for _ in pairs(visited) do cells = cells + 1 end
			print(string.format("WALK distance %.0f m, %d distinct 4m cells, %d turns (%d stuck)", total_dist, cells, turns, stuck_turns))
			walk.Report(frame_times, gpu_sums, gpu_n, worst, alloc, now - began)
			system.ShutDown(0)
			return
		end

		if now - last_check >= CHECK then
			local moved = math.sqrt((p.x - check_pos.x) ^ 2 + (p.z - check_pos.z) ^ 2)

			if moved < 0.4 * CHECK * 3 then
				stuck_turns = stuck_turns + 1
				failed[#failed + 1] = {x = p.x, z = p.z, yaw = yaw}
				yaw = choose(p)
				jump_until = now + 0.7
				next_turn = now + 8
			end

			last_check, check_pos = now, p:Copy()
		end

		if now > next_turn then
			turns = turns + 1
			yaw = choose(p)
			next_turn = now + 8
		end

		frame_times[#frame_times + 1] = dt
		local sec = math.floor((now - began) / 5)
		segment[sec] = segment[sec] or {n = 0, t = 0, max = 0}
		segment[sec].n = segment[sec].n + 1
		segment[sec].t = segment[sec].t + dt
		segment[sec].max = math.max(segment[sec].max, dt)
		segment[sec].x, segment[sec].y, segment[sec].z = p.x, p.y, p.z
		walk.segment = segment

		if dt > 0.03 then worst[#worst + 1] = {ms = dt * 1000, at = now - began, x = p.x, z = p.z} end

		local heap = collectgarbage("count")
		alloc = alloc + math.max(heap - heap_prev, 0)
		heap_prev = heap
		local names = gpu_timing.GetScopeNames()

		for i = 1, #names do
			local name = names[i]
			local ms = gpu_timing.GetRawMilliseconds(name)

			if gpu_prev[name] ~= ms then
				gpu_prev[name] = ms
				gpu_n[name] = (gpu_n[name] or 0) + 1
				gpu_sums[name] = (gpu_sums[name] or 0) + ms
			end
		end
	end)
end

function walk.Report(frame_times, gpu_sums, gpu_n, worst, alloc, seconds)
	if os.getenv("GMW_EMITTERS") then
		print("STATS hide", STAT_HIDE, "write", STAT_WRITE, "release", STAT_RELEASE, "same", STAT_SAME, "diff", STAT_DIFF)
		print(string.format("EMITTERS calls=%d rebuilds=%d total=%.0fms rebuild_total=%.0fms max_rebuild=%.1fms emitters=%s soup_changed=%d top_changed=%d blocks_changed=%d blocks=%d", emitter_stats.calls, emitter_stats.rebuilds, emitter_stats.time * 1000, emitter_stats.rebuild_time * 1000, emitter_stats.max * 1000, tostring(emitter_stats.count), emitter_stats.soup_changed, emitter_stats.top_changed, emitter_stats.blocks_changed, #import("goluwa/render3d/scene_bvh.lua").emissive_blocks))
	end
	local sorted = table.move(frame_times, 1, #frame_times, 1, {})
	table.sort(sorted)
	local n, sum = #sorted, 0
	for _, v in ipairs(sorted) do sum = sum + v end
	print(string.format("WALK %d frames in %.1fs: avg %.2fms (%.1f fps) p50 %.2f p95 %.2f p99 %.2f max %.2f ms, alloc %.1f MB/s", n, seconds, sum / n * 1000, n / sum, sorted[math.ceil(n * .5)] * 1000, sorted[math.ceil(n * .95)] * 1000, sorted[math.ceil(n * .99)] * 1000, sorted[n] * 1000, alloc / 1024 / seconds))
	local rows = {}
	for k, v in pairs(gpu_sums) do rows[#rows + 1] = {k, v / n, v / gpu_n[k]} end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	for i = 1, math.min(14, #rows) do
		print(string.format("  GPU %-34s %7.3f ms/frame  %7.3f per update", rows[i][1], rows[i][2], rows[i][3]))
	end
	local keys = {}
	for k in pairs(walk.segment) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local s = walk.segment[k]
		print(string.format("  SEG %3ds avg %6.2fms max %6.1fms at (%.0f, %.0f, %.0f)", k * 5, s.t / s.n * 1000, s.max * 1000, s.x, s.y, s.z))
	end
	table.sort(worst, function(a, b) return a.ms > b.ms end)
	for i = 1, math.min(8, #worst) do
		print(string.format("  SLOW %.1fms at +%.1fs (%.0f, %.0f)", worst[i].ms, worst[i].at, worst[i].x, worst[i].z))
	end
end

return walk
