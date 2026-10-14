-- frame times of the island example from each of its views, after the scatter bakes have settled (START=6 begins at the sixth,
-- SCATTER_OFF=1 for the baseline). no --validate
-- luajit glw --3d --background lua "./test/harnesses/scatter/island_perf.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local locate = import("test/harnesses/scatter/island_locate.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local pvars = import("goluwa/cli/pvars.lua")
if os.getenv("SCATTER_OFF") then pvars.SetSession("r_feature_scatter", false) end
local island = import("addons/examples/lua/examples/render3d/island_terrain.lua")
local START = tonumber(os.getenv("START") or 2)
local v0 = island.GetView(START)
local view = View.New{Priority = 100, Position = v0.Position, Rotation = v0.Rotation, FOV = v0.FOV}:Activate()
local index, state, state_start, quiet, frames, last = START, "locate", system.GetTime(), nil, {}, nil
locate.Go(view, v0, function() state, state_start = "wait", system.GetTime() end)
local MEASURE = 4
local gpu_prev, gpu_sum = {}, {}
event.AddListener("Update", "island_perf", function()
	local now = system.GetTime()
	if state == "wait" then
		local min = index == START and 25 or 4
		if (scatter.pending_bakes or 1) == 0 and now - state_start > min then quiet = quiet or now else quiet = nil end
		if (quiet and now - quiet > 3) or now - state_start > 40 then state, state_start, frames, last = "measure", now, {}, nil end
	elseif state == "measure" then
		if last then frames[#frames + 1] = now - last end
		for _, name in ipairs(gpu_timing.GetScopeNames()) do
			local ms = gpu_timing.GetRawMilliseconds(name)
			if gpu_prev[name] ~= ms then gpu_prev[name] = ms gpu_sum[name] = (gpu_sum[name] or 0) + ms gpu_sum[name .. "#"] = (gpu_sum[name .. "#"] or 0) + 1 end
		end
		last = now
		if now - state_start >= MEASURE then
			table.sort(frames)
			local sum = 0
			for _, f in ipairs(frames) do sum = sum + f end
			print(string.format("PERF %-22s avg %.2f p50 %.2f p95 %.2f max %.2f ms (%d frames) units %d pool %d", island.views[index].name, sum / #frames * 1000, frames[math.ceil(#frames * 0.5)] * 1000, frames[math.ceil(#frames * 0.95)] * 1000, frames[#frames] * 1000, #frames, scatter.unit_count, scatter.pool_top))
			local rows = {}
			for k, v in pairs(gpu_sum) do if not k:find("#", 1, true) then rows[#rows + 1] = {k, v / gpu_sum[k .. "#"]} end end
			table.sort(rows, function(a, b) return a[2] > b[2] end)
			local parts = {}
			for i = 1, math.min(#rows, 8) do parts[#parts + 1] = string.format("%s=%.2f", rows[i][1], rows[i][2]) end
			print("GPU " .. table.concat(parts, "  "))
			gpu_sum = {}
			index = index + 1
			if not island.views[index] then system.ShutDown(0) return end
			state, quiet = "locate", nil
			locate.Go(view, island.GetView(index), function() state, state_start = "wait", system.GetTime() end)
		end
	end
end)
