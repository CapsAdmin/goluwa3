-- runtime performance of esther or IA/Quarry at fixed views: wall frame time (avg/p50/p95/p99), how much of it the cpu is blocked
-- on the gpu, cpu recording time per scope, gpu time per group and scope. one process, the views one after the other, and
-- in each view the variants of MP_SWEEP one after the other.
-- env: MP_MAP (esther|quarry), MP_PV ("pvar=value ..." set for the whole run), MP_VIEWS (comma separated indexes, all),
-- MP_SWEEP ("name=pvar:value,pvar:value;name2=...": the variants, run as base, the variants, base again; the pvars of a
-- variant go back to what they were before it), MP_SHOT (a directory: one picture per view and variant, time frozen and
-- exposure locked to MP_EV, MP_FREEZE=1 holds the time still instead of advancing it from the start of each job, which also
-- stops the plants where the wind has them, MP_SHIFT=seconds takes a second picture, name_b.png, with the wind's clock
-- that much later), MP_SECONDS (measured seconds per job, 4), MP_SETTLE (seconds a job is held before measuring, 3),
-- MP_MOVE (m/s the camera flies forward while measuring, 0), MP_EXTRA (a lua file imported before the map loads, it may
-- set the globals MP_RESET() and MP_REPORT(frames) to wrap things), MP_PROF (a profile tag), MP_TOP (gpu scopes printed,
-- 10), MP_CPU_TOP (cpu scopes printed, 8), MP_TRACE (frame time per second while loading)
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local render = import("goluwa/render/render.lua")
local map = os.getenv("MP_MAP") or "esther"
local seconds = tonumber(os.getenv("MP_SECONDS") or "") or 4
local settle = tonumber(os.getenv("MP_SETTLE") or "") or 3
local top = tonumber(os.getenv("MP_TOP") or "") or 10
local cpu_top = tonumber(os.getenv("MP_CPU_TOP") or "") or 8
local move_speed = tonumber(os.getenv("MP_MOVE") or "") or 0
local shot_dir = os.getenv("MP_SHOT")
local deg = math.pi / 180
local MAPS = {
	esther = {
		command = "map esther",
		sun = Quat(-0.486132, 0.157912, -0.157912, 0.844869),
		after_ready = 3,
		ev = 8,
		views = {
			{"cave", Vec3(-0.606175, -19.356127, 12.605980), Ang3(-0.530039, -0.699206, 0)},
			{"view 2a", Vec3(-1.940760, -37.943398, 50.408764), Ang3(0.290500, 0.646271, 0)},
			{"view 4b", Vec3(14.241719, -0.511441, -30.688238), Ang3(-1.547330, 2.100331, 0.000048)},
		},
	},
	quarry = {
		command = "map IA/Quarry",
		sun = Quat(-0.319946, -0.058354, -0.019748, 0.945431),
		after_ready = tonumber(os.getenv("MP_AFTER") or "") or 25,
		ev = 12,
		views = {
			{"floor", Vec3(1484.279419, 172.515839, -1118.615967), Ang3(-0.491435, 1.164634, 0)},
			{"overview", Vec3(1380, 215, -1080), Ang3(-20 * deg, -10 * deg, 0)},
			{"warehouse", Vec3(1395, 170, -1105), Ang3(-5 * deg, -20 * deg, 0)},
		},
	},
}
local cfg = MAPS[map]
local views = {}
if os.getenv("MP_VIEWS") then
	for i in os.getenv("MP_VIEWS"):gmatch("%d+") do views[#views + 1] = cfg.views[tonumber(i)] end
else
	views = cfg.views
end

local function parse_value(v)
	local value = tonumber(v)
	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end
	return value
end

for k, v in (os.getenv("MP_PV") or ""):gmatch("(%S+)=(%S+)") do pvars.SetSession(k, parse_value(v)) end

local variants = {{name = "base", pvars = {}}}
if os.getenv("MP_SWEEP") then
	for entry in os.getenv("MP_SWEEP"):gmatch("[^;]+") do
		local name, list = entry:match("^%s*([^=]+)=(.*)$")
		local variant = {name = name, pvars = {}}
		for key, v in list:gmatch("([^:,]+):([^,]+)") do variant.pvars[#variant.pvars + 1] = {key, parse_value(v)} end
		variants[#variants + 1] = variant
	end
	variants[#variants + 1] = {name = "base again", pvars = {}}
end

local jobs = {}
for v = 1, #views do
	for _, variant in ipairs(variants) do jobs[#jobs + 1] = {view = v, variant = variant} end
end

local cpu, stack, blocked, calls = {}, {}, {}, {}
local old_begin, old_end = gpu_timing.BeginScope, gpu_timing.EndScope
local measuring = false
gpu_timing.BeginScope = function(cmd, name)
	if measuring then stack[#stack + 1] = {name, system.GetTime()} end
	return old_begin(cmd, name)
end
gpu_timing.EndScope = function(cmd, name)
	if measuring then
		local t = stack[#stack]
		stack[#stack] = nil
		if t then cpu[t[1]] = (cpu[t[1]] or 0) + system.GetTime() - t[2] end
	end
	return old_end(cmd, name)
end
local function wrap(tbl, name, label)
	local v = tbl[name]
	tbl[name] = function(...)
		if not measuring then return v(...) end
		local t = system.GetTime()
		return (function(...)
			blocked[label] = (blocked[label] or 0) + system.GetTime() - t
			calls[label] = (calls[label] or 0) + 1
			return ...
		end)(v(...))
	end
end
local hooked = false
local function hook()
	if hooked or not render.target or not render.target.in_flight_fences then return end
	hooked = true
	wrap(getmetatable(render.target.in_flight_fences[1]).__index, "Wait", "fence_wait")
	local sc = render.target.swapchain or render.target.swap_chain
	local sci = getmetatable(sc).__index
	wrap(sci, "GetNextImage", "acquire")
	wrap(sci, "Present", "present")
	wrap(render, "SubmitAndWait", "submit_and_wait")
end

if os.getenv("MP_EXTRA") then import(os.getenv("MP_EXTRA")) end
if shot_dir then os.execute("mkdir -p " .. shot_dir) end
commands.RunString(cfg.command)
local ready_at, last_time, good, settled_at = nil, system.GetTime(), 0, nil
local index, job_start, state, capture_start, quiet = 0, nil, "wait", nil, 0
local active_view, current_view, restore
local times = {}
local heap_prev, alloc
local trace_n, trace_sum = 0, 0
local frame_count = 0
local shot_shift, shot_wait, shot_path, shot_finish = 0, 0, nil, nil
event.AddListener("RTSceneReady", "mp_ready", function() ready_at = system.GetTime() end)
event.AddListener("Update", "mp_cycle", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now
	hook()
	if dt < 0.15 then good = good + 1 else good = 0 end
	if os.getenv("MP_TRACE") then
		trace_n, trace_sum = trace_n + 1, trace_sum + dt
		if trace_sum > 1 then
			print(string.format("MP trace t=%.1f state=%s frames=%d avg %.1f ms", now - (ready_at or now), state, trace_n, trace_sum / trace_n * 1000))
			trace_n, trace_sum = 0, 0
		end
	end
	if state == "wait" then
		if ready_at and not scene_loading.IsLoading() and good > 60 and now - ready_at > cfg.after_ready then
			weather.SetSunRotation(cfg.sun)
			state = "next"
		end
		return
	end
	if state == "next" then
		index = index + 1
		if index > #jobs then system.ShutDown(0) end
		local job = jobs[index]
		local v = views[job.view]
		if current_view ~= job.view then
			if active_view then active_view:Remove() end
			active_view = View.New{Priority = 100 + job.view, Position = v[2], Rotation = Quat():SetAngles(v[3]), FOV = 1.5707963267949, ExposureLock = shot_dir and (tonumber(os.getenv("MP_EV") or "") or cfg.ev) or nil}
			active_view:Activate()
			current_view = job.view
		else
			active_view:SetPosition(v[2])
		end
		restore = {}
		for _, entry in ipairs(job.variant.pvars) do
			restore[#restore + 1] = {entry[1], pvars.Get(entry[1])}
			pvars.SetSession(entry[1], entry[2])
		end
		job_start = now
		quiet = 0
		frame_count = 0
		state = "settle"
		return
	end
	if shot_dir then
		frame_count = frame_count + 1
		system.SetElapsedTime(os.getenv("MP_FREEZE") and 1000 + shot_shift or 1000 + frame_count / 60)
	end
	if state == "settle" then
		if dt < 0.06 then quiet = quiet + 1 else quiet = 0 end
		if now - job_start > settle and quiet > 150 then
			state = "measure"
			capture_start = now
			table.clear(times) table.clear(cpu) table.clear(blocked) table.clear(calls)
			heap_prev, alloc = collectgarbage("count"), 0
			measuring = true
			if _G.MP_RESET then _G.MP_RESET() end
			gpu_timing.BeginCapture()
			if os.getenv("MP_PROF") then PROF.Start(os.getenv("MP_PROF"), {shutdown = false, trace_recorder = false}) end
		end
		return
	end
	if state == "shot" then return end

	if state == "shot_wait" then
		shot_wait = shot_wait - 1

		if shot_wait <= 0 then
			state = "shot"
			Screenshot(function(texture)
				texture:SaveWithoutAlpha(shot_path:gsub("%.png$", "_b.png"))
				shot_shift = 0
				shot_finish()
			end)
		end

		return
	end
	if move_speed > 0 then active_view:SetPosition(active_view:GetPosition() + active_view:GetRotation():GetForward() * move_speed * dt) end
	times[#times + 1] = dt
	local heap = collectgarbage("count")
	alloc = alloc + math.max(heap - heap_prev, 0)
	heap_prev = heap
	if now - capture_start > seconds then
		measuring = false
		if os.getenv("MP_PROF") then
			PROF.Stop()
			PROF.Summary("storage/logs/jit_profile_" .. os.getenv("MP_PROF") .. ".glwp", {top_n = 40})
		end
		local r = gpu_timing.EndCapture()
		local job = jobs[index]
		local n = #times
		local total = 0
		for i = 1, n do total = total + times[i] end
		table.sort(times)
		local slow = 0
		for i = 1, n do if times[i] > 0.033 then slow = slow + 1 end end
		local wait = (blocked.acquire or 0) + (blocked.fence_wait or 0) + (blocked.submit_and_wait or 0)
		print(string.format("MP %s [%s] <%s> wall avg %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f ms, %d of %d frames over 33 ms gpu_frame %.2f  blocked %.2f (acquire %.2f fence %.2f swait %.2f present %.2f) => cpu busy %.2f  alloc %.1f MB/s",
			map, views[job.view][1], job.variant.name, total / n * 1000, times[math.ceil(n * 0.5)] * 1000, times[math.ceil(n * 0.95)] * 1000, times[math.ceil(n * 0.99)] * 1000, times[n] * 1000, slow, n, r.frame_ms,
			wait / n * 1000, (blocked.acquire or 0) / n * 1000, (blocked.fence_wait or 0) / n * 1000, (blocked.submit_and_wait or 0) / n * 1000, (blocked.present or 0) / n * 1000,
			(total - wait) / n * 1000, alloc / 1024 / total))
		local rows = {}
		for k, v in pairs(cpu) do rows[#rows + 1] = {k, v / n * 1000} end
		table.sort(rows, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(#rows, cpu_top) do parts[#parts + 1] = string.format("%s=%.2f", rows[i][1], rows[i][2]) end
		print("MP   cpu record ms/frame: " .. table.concat(parts, "  "))
		parts = {}
		for i = 1, math.min(#r.groups, 8) do parts[#parts + 1] = string.format("%s=%.2f", r.groups[i].label, r.groups[i].ms) end
		print("MP   gpu groups: " .. table.concat(parts, "  "))
		parts = {}
		for i = 1, math.min(#r.scopes, top + 1) do
			local e = r.scopes[i]
			if e.name ~= "gpu_frame" then parts[#parts + 1] = string.format("%s=%.2f", e.name, e.ms) end
		end
		print("MP   gpu scopes: " .. table.concat(parts, "  "))
		if _G.MP_REPORT then _G.MP_REPORT(n) end
		local function finish()
			for i = #restore, 1, -1 do pvars.SetSession(restore[i][1], restore[i][2]) end
			state = "next"
		end
		if shot_dir then
			state = "shot"
			shot_path = string.format("%s/%s_%s_%s.png", shot_dir, map, views[job.view][1]:gsub("%s", "_"), job.variant.name:gsub("%s", "_"))
			shot_finish = finish
			Screenshot(function(texture)
				texture:SaveWithoutAlpha(shot_path)

				if tonumber(os.getenv("MP_SHIFT") or "") then
					-- the same view with the wind's clock moved on (the history has to settle in it), to see how much moves
					shot_shift = tonumber(os.getenv("MP_SHIFT"))
					shot_wait = 90
					state = "shot_wait"
				else
					finish()
				end
			end)
		else
			finish()
		end
	end
end)
