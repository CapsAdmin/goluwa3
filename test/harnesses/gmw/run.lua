local commands = import("goluwa/cli/commands.lua")
local units = import("goluwa/source_engine/units.lua")
local timer = import("goluwa/timer.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MAP = os.getenv("GMW_MAP") or "gm_construct_m3_401"
local LOADPROF = os.getenv("GMW_LOADPROF")
local WALKPROF = os.getenv("GMW_WALKPROF")
local SPEED = tonumber(os.getenv("GMW_SPEED") or "5")
local EYE = 1.7
-- source units x,y,z,yaw,pitch ; lobby spawn
local sx, sy, sz = -10818, -9029.5, 9448
local t0 = system.GetTime()
local timing = {}
local listener_total, listener_window = {}, {}
local function wrap_listeners()
	local render = import("goluwa/render/render.lua")
	for event_type, list in pairs(event.active) do
		for _, config in ipairs(list) do
			if not config.gmw_wrapped then
				config.gmw_wrapped = true
				local cb = config.callback
				local key = tostring(event_type) .. "->" .. tostring(config.id)
				config.callback = function(...)
					local t = system.GetTime()
					local a, b, c, d = cb(...)
					local dt = system.GetTime() - t
					listener_total[key] = (listener_total[key] or 0) + dt
					listener_window[key] = (listener_window[key] or 0) + dt
					return a, b, c, d
				end
			end
		end
	end
	for _, name in ipairs{"BeginFrame", "EndFrame", "SubmitAndWait"} do
		if not render["gmw_" .. name] then
			render["gmw_" .. name] = true
			local old = render[name]
			local key = "render." .. name
			render[name] = function(...)
				local t = system.GetTime()
				local a, b = old(...)
				local dt = system.GetTime() - t
				listener_total[key] = (listener_total[key] or 0) + dt
				listener_window[key] = (listener_window[key] or 0) + dt
				return a, b
			end
		end
	end
end
local function top_listeners(tbl, n)
	local rows = {}
	for k, v in pairs(tbl) do rows[#rows + 1] = {k, v} end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	local parts = {}
	for i = 1, math.min(n, #rows) do parts[#parts + 1] = string.format("%s=%.0fms", rows[i][1], rows[i][2] * 1000) end
	return table.concat(parts, "  ")
end
local LISTENERS = os.getenv("GMW_LISTENERS")
do
	local stage_prof = os.getenv("GMW_STAGEPROF")
	local function stage(tbl, name, label)
		local old = tbl[name]
		tbl[name] = function(...)
			print(string.format("STAGE %-26s start %6.2fs", label, system.GetTime() - t0))
			if stage_prof == label then PROF.Start("gmw_stage", {shutdown = false, trace_recorder = false}) end
			local a, b, c = old(...)
			if stage_prof == label then PROF.Stop() PROF.Summary("storage/logs/jit_profile_gmw_stage.glwp", {top_n = 40}) end
			print(string.format("STAGE %-26s end   %6.2fs", label, system.GetTime() - t0))
			return a, b, c
		end
	end
	stage(import("goluwa/source_engine/bsp.lua"), "Load", "bsp.Load")
	stage(import("goluwa/source_engine/map_scene.lua"), "Translate", "map_scene.Translate")
	local scene = import("goluwa/entities/scene.lua")
	stage(scene, "Deserialize", "scene.Deserialize")
	local sg = import("goluwa/source_engine/static_geometry.lua")
	stage(sg, "Build", "static_geometry.Build")
	stage(sg, "Finalize", "static_geometry.Finalize")
	local last_window = 0
	event.AddListener("Update", "gmw_lis", function()
		if LISTENERS and mode ~= "load" and system.GetTime() - last_window > 15 then
			last_window = system.GetTime()
			print(string.format("  WALKLISTENERS(15s) @ t=%.0f  %s", last_window - t0, top_listeners(listener_window, 9)))
			table.clear(listener_window)
		end
	end)
	local seen_ready
	event.AddListener("Update", "gmw_stage", function()
		if scene_bvh.readied and not seen_ready then
			seen_ready = true
			print(string.format("STAGE %-26s       %6.2fs", "scene_bvh.readied", system.GetTime() - t0))
		end
	end)
end
if os.getenv("GMW_TIMING") then
	local sg = import("goluwa/source_engine/static_geometry.lua")
	for _, name in ipairs{"Build", "EmitBrush", "EmitDisplacement", "ComputeDisplacementNormals", "EmitMesh", "UploadBatch", "AddVertex"} do
		local old = sg[name]
		timing[name] = {0, 0}
		sg[name] = function(...)
			local t = system.GetTime()
			local a, b, c = old(...)
			local r = timing[name]
			r[1] = r[1] + system.GetTime() - t
			r[2] = r[2] + 1
			return a, b, c
		end
	end
end
local view
local mode = "load"
local stable_since, last_log = nil, 0
local prev = system.GetTime()
local load_frames = {}

local function src(x, y, z)
	return units.PositionToEngine(Vec3(x, y, z))
end

event.AddListener("Update", "gmw", function()
	local now = system.GetTime()
	local dt = now - prev
	prev = now

	if mode == "load" then
		load_frames[#load_frames + 1] = dt

		if LISTENERS then wrap_listeners() end

		if now - last_log > 5 then
			last_log = now
			if LISTENERS then
				print("  LISTENERS " .. top_listeners(listener_window, 7))
				table.clear(listener_window)
			end
			print(string.format("t=%.1fs frame=%d ft=%.0fms mem=%.0fMB bvh=%s loading=%s busy=%s", now - t0, system.GetFrameNumber(), dt * 1000, collectgarbage("count") / 1024, tostring(scene_bvh.readied), tostring(scene_loading.IsLoading()), tostring(tasks.IsBusy())))
		end

		if scene_bvh.readied and not scene_loading.IsLoading() and not tasks.IsBusy() then
			stable_since = stable_since or now
			if now - stable_since > 3 then
				local done = stable_since - t0
				print(string.format("LOAD COMPLETE at %.2fs", done)) print("NEAREST", _G.NEAREST_CALLS, _G.NEAREST_BAD)
				if LISTENERS then print("LISTENERS TOTAL " .. top_listeners(listener_total, 25)) end
				for k, v in pairs(timing) do print(string.format("TIMING %-28s %8.2fs  %d calls", k, v[1], v[2])) end
				table.sort(load_frames)
				local over = 0
				local worst = load_frames[#load_frames]
				for _, v in ipairs(load_frames) do if v > 0.1 then over = over + v end end
				print(string.format("LOAD frames=%d worst=%.0fms time-in-frames>100ms=%.1fs", #load_frames, worst * 1000, over))
				if LOADPROF then PROF.Stop() PROF.Summary("storage/logs/jit_profile_gmw_load.glwp", {top_n = 45}) end
				local rig = _G.PLAYER_RIG
				rig.player_movement:SetEyePosition(src(sx, sy, sz))
				local rp = rig.transform:GetPosition()
				print(string.format("PLAYER at %.1f %.1f %.1f", rp.x, rp.y, rp.z))
				mode = "settle"
				stable_since = now
			end
		else
			stable_since = nil
		end
		return
	end

	if mode == "settle" then
		if now - stable_since > (tonumber(os.getenv("GMW_SETTLE") or "20")) then
			mode = "walk"
			import(os.getenv("GMW_DBG") and "test/harnesses/gmw/dbg.lua" or "test/harnesses/gmw/walk.lua").Start(_G.PLAYER_RIG)
		end
	end
end)

if LOADPROF then PROF.Start("gmw_load", {shutdown = false, trace_recorder = false}) end
timer.Delay(0, function()
	commands.RunString("map " .. MAP)
	print(string.format("SetMap returned after %.2fs", system.GetTime() - t0))
end)
