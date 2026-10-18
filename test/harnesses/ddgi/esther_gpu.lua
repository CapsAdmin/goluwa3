-- (EG_DUMP=n also lists the n largest rows the main cull drew, see scene_draw_dump)
-- gpu time per scope and group on the esther map at the cave view, after the scene is ready. env: EG_PV ("pvar=value ..."), EG_SECONDS (measured seconds, 6), EG_TOP (scopes printed, 16)
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
local seconds = tonumber(os.getenv("EG_SECONDS") or "") or 6
for k, v in (os.getenv("EG_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)
	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end
	pvars.SetSession(k, value)
end
commands.RunString("map esther")
local ready_at, last_time, good, settled_at = nil, system.GetTime(), 0, nil
local capturing = false
local masks = {}
event.AddListener("RTSceneReady", "eg_ready", function() ready_at = system.GetTime() end)
event.AddListener("Update", "eg_cycle", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now
	if dt < 0.15 then good = good + 1 else good = 0 end
	if not settled_at then
		if ready_at and not scene_loading.IsLoading() and good > 60 and now - ready_at > 3 then
			weather.SetSunRotation(Quat(-0.486132, 0.157912, -0.157912, 0.844869))
			View.New{Priority = 100, Position = Vec3(-0.606175, -19.356127, 12.605980), Rotation = Quat():SetAngles(Ang3(-0.530039, -0.699206, 0)), FOV = 1.5707963267949}:Activate()
			settled_at = now
		end
		return
	end
	if capturing then local i = gpu_timing.GetInfo("ddgi_trace") if i then masks[i.mask] = (masks[i.mask] or 0) + 1 end end
	if not capturing and now - settled_at > 2 then capturing = true gpu_timing.BeginCapture() end
	if capturing and now - settled_at > 2 + seconds then
		local r = gpu_timing.EndCapture()
		for m, n in pairs(masks) do print(string.format("GPU mask %s x%d", ("%x"):format(m), n)) end
		local inst = import("goluwa/render3d/scene/instances.lua")
		local tl = inst.GetTables()
		local live = 0
		local rows = tl:Get()
		for i = 0, tl.count - 1 do if rows[i].accelerationStructureReference ~= 0 then live = live + 1 end end
		print("GPU live_instances", live, "of", tl.count, "r_rt_distance", pvars.Get and pvars.Get("r_rt_distance"))
		print(string.format("GPU frame %.2f ms (%d frames) instances=%d triangles=%d", r.frame_ms, r.frames, import("goluwa/render3d/scene/instances.lua").GetCount(), import("goluwa/render3d/scene/meshes.lua").GetTriangleCount()))
		for i = 1, math.min(#r.groups, 8) do print(string.format("GPU group %-22s %6.2f ms %5.1f%%", r.groups[i].label, r.groups[i].ms, r.groups[i].share * 100)) end
		for i = 1, math.min(#r.scopes, tonumber(os.getenv("EG_TOP") or "") or 16) do
			local e = r.scopes[i]
			local info = {}
			for k, v in pairs(e.info or {}) do info[#info + 1] = k .. "=" .. (v == math.floor(v) and string.format("%d", v) or string.format("%.2f", v)) end
			table.sort(info)
			print(string.format("GPU %-30s %6.2f ms %5.1f%%  %s", e.name, e.ms, e.share * 100, table.concat(info, " ")))
		end
		if os.getenv("EG_DUMP") then commands.RunString("scene_draw_dump " .. os.getenv("EG_DUMP")) end
		system.ShutDown(0)
	end
end)
