-- ocean pass gpu time at a camera looking straight down at shallow water, with each r_water_* pvar turned off in turn.
-- the gpu clock wanders by a few ms inside one process, so a baseline (all on) runs between every two toggles and each
-- is reported against the mean of the baselines around it
-- luajit glw --3d --background lua "./test/harnesses/scatter/water_toggles.lua"
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local pvars = import("goluwa/cli/pvars.lua")
import("goluwa/render3d/weather.lua").SetSunRotation(Quat(-0.404049, 0.330877, 0.159586, 0.837734))
import("addons/examples/lua/examples/render3d/island_terrain.lua")
View.New{Priority = 100, Position = Vec3(2523.054199, 18.466902, 1063.371338), Rotation = Quat():SetAngles(Ang3(-1.560800, -0.762640, 0)), FOV = 1.5707963267949}:Activate()
local names = {"caustics", "shafts", "ripples", "lights", "reflection_trace", "shore_foam", "inscatter", "refraction", "sun_shadows", "shaft_caustics", "ambient_gi"}
local modes = {{"base"}}
for _, n in ipairs(names) do
	modes[#modes + 1] = {n, n}
	modes[#modes + 1] = {"base"}
end
local results = {}
local index, start, mode_start, sum, n, prev = 1, system.GetTime(), nil, 0, 0, nil
local function apply(mode)
	for _, name in ipairs(names) do pvars.SetSession("r_water_" .. name, mode[2] ~= name) end
end
event.AddListener("Update", "water_toggles", function()
	local now = system.GetTime()
	if not mode_start then
		if now - start > 28 and (scatter.pending_bakes or 1) == 0 then mode_start = now apply(modes[1]) end
		return
	end
	if now - mode_start > 1.2 then
		local ms = gpu_timing.GetRawMilliseconds("ocean")
		if ms and ms ~= prev then sum, n, prev = sum + ms, n + 1, ms end
	end
	if now - mode_start > 3.5 then
		results[index] = sum / math.max(n, 1)
		index = index + 1
		if not modes[index] then
			local total = 0
			for i = 1, #modes, 2 do total = total + results[i] end
			print(string.format("WATER base (mean of %d) %.2f ms", (#modes + 1) / 2, total / ((#modes + 1) / 2)))
			for i = 2, #modes, 2 do
				local base = (results[i - 1] + results[i + 1]) / 2
				print(string.format("WATER %-18s off %.2f ms against %.2f: saves %.2f", modes[i][1], results[i], base, base - results[i]))
			end
			system.ShutDown(0)
			return
		end
		apply(modes[index])
		mode_start, sum, n = now, 0, 0
	end
end)
