-- gpu time of the particle passes: the yard in snow or rain, then the same with nothing falling. No --validate.
-- luajit glw --3d --background lua "import('test/harnesses/particles/perf.lua')"
-- RATE=5 SECONDS=3
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local weather = import("goluwa/render3d/weather.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local View = import("goluwa/render3d/view.lua")
local rate = test_scene.GetNumber("RATE", 5)
local seconds = test_scene.GetNumber("SECONDS", 3)
test_scene.Reset{sun = {elevation = 35, azimuth = 30}, clouds = {}}
test_scene.Ground{size = 120, material = test_scene.Matte(0.35)}
test_scene.Room{pos = Vec3(0, 0, 8), size = Vec3(6, 3, 6), material = test_scene.Matte(0.6), openings = {{wall = "-z", x = 0, y = 1, width = 1.6, height = 2}}}
View.New{Priority = 100, Position = Vec3(0, 1.7, -4), Rotation = QuatDeg3(-5, 180, 0), ExposureLock = 14}:Activate()
local modes = {
	{"none", function() weather.SetSnow(0) weather.SetRain(0) end},
	{"snow", function() weather.SetRain(0) weather.SetSnow(rate) end},
	{"rain", function() weather.SetSnow(0) weather.SetRain(rate) end},
	{"both", function() weather.SetRain(rate) weather.SetSnow(rate) end},
}
local names = {"gpu_frame", "particles_simulate", "particles_moments", "particles_accumulate", "translucent_moments", "translucent_accumulate", "volumetric_fog"}
local index = 0
local started = 0
local sums, frames = {}, 0

event.AddListener("Update", "particle_perf", function()
	local now = system.GetElapsedTime()

	if index > 0 and now - started > seconds then
		local line = {}

		for _, name in ipairs(names) do
			line[#line + 1] = string.format("%s %.3f", name, (sums[name] or 0) / math.max(frames, 1))
		end

		print(string.format("%-5s %s", modes[index][1], table.concat(line, "  ")))
	end

	if index == 0 or now - started > seconds then
		index = index + 1

		if not modes[index] then
			system.ShutDown(0)
			return event.destroy_tag
		end

		modes[index][2]()
		started = now
		sums, frames = {}, 0
		return
	end

	if now - started > 1 then
		frames = frames + 1

		for _, name in ipairs(names) do
			sums[name] = (sums[name] or 0) + gpu_timing.GetRawMilliseconds(name)
		end
	end
end)
