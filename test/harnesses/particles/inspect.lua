-- reads a particle pool back after some seconds and prints what is in it: how many are visible, where they are
-- relative to the camera, how fast they fall and how bright they are
-- luajit glw --3d --background --validate lua "import('test/harnesses/particles/inspect.lua')"
-- KIND=rain|snow RATE=5 ELEVATION=35 AFTER=4 (seconds) GI=1
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local particles = import("goluwa/render3d/particles.lua")
local precipitation = import("goluwa/render3d/precipitation.lua")
local pvars = import("goluwa/cli/pvars.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local View = import("goluwa/render3d/view.lua")
local kind = test_scene.GetString("KIND", "snow")
local rate = test_scene.GetNumber("RATE", 5)
local after = test_scene.GetNumber("AFTER", 4)

if os.getenv("GI") == "0" then pvars.SetSession("r_pass_ddgi", false) end

test_scene.Reset{sun = {elevation = test_scene.GetNumber("ELEVATION", 35), azimuth = 30}, clouds = {}}
test_scene.Ground{size = 120, material = test_scene.Matte(0.35)}
test_scene.Room{pos = Vec3(0, 0, 8), size = Vec3(6, 3, 6), material = test_scene.Matte(0.6), openings = {{wall = "-z", x = 0, y = 1, width = 1.6, height = 2}}}

if kind == "rain" then weather.SetRain(rate) else weather.SetSnow(rate) end

local view = View.New{Priority = 100, Position = Vec3(0, 1.7, -4), Rotation = QuatDeg3(-5, 180, 0), ExposureLock = 14}:Activate()
local start = system.GetElapsedTime()

event.AddListener("Update", "particle_inspect", function()
	if system.GetElapsedTime() - start < after then return end

	local def = precipitation[kind]
	local count = def.GetCount()
	local records = particles.Download(def)
	local camera = render3d.GetCamera():GetPosition()
	local visible, sum_luma, max_luma, sum_speed, sum_width = 0, 0, 0, 0, 0
	local lo, hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
	local fresh = 0
	local states, landed_lo, landed_hi, below = {[0] = 0, 0, 0}, math.huge, -math.huge, 0
	local sum_rgb = {0, 0, 0}

	for i = 0, count - 1 do
		local p = records[i]

		if p.life > 0 then fresh = fresh + 1 end

		states[p.user[1]] = (states[p.user[1]] or 0) + 1

		if p.user[1] == 1 and p.visibility > 0 then landed_lo, landed_hi = math.min(landed_lo, p.position[1]), math.max(landed_hi, p.position[1]) end

		if p.visibility > 0 and p.position[1] < -0.01 then below = below + 1 end

		if p.visibility > 0 then
			visible = visible + 1
			local luma = 0.2126 * p.radiance[0] + 0.7152 * p.radiance[1] + 0.0722 * p.radiance[2]
			sum_luma = sum_luma + luma
			for c = 1, 3 do sum_rgb[c] = sum_rgb[c] + p.radiance[c - 1] end
			max_luma = math.max(max_luma, luma)
			sum_speed = sum_speed + math.sqrt(p.velocity[0] ^ 2 + p.velocity[1] ^ 2 + p.velocity[2] ^ 2)
			sum_width = sum_width + p.width
			lo[1], hi[1] = math.min(lo[1], p.position[0] - camera.x), math.max(hi[1], p.position[0] - camera.x)
			lo[2], hi[2] = math.min(lo[2], p.position[1] - camera.y), math.max(hi[2], p.position[1] - camera.y)
			lo[3], hi[3] = math.min(lo[3], p.position[2] - camera.z), math.max(hi[3], p.position[2] - camera.z)
		end
	end

	print(string.format("%s: count %d (coverage %.2f), spawned %d, visible %d", kind, count, select(2, def.GetCount()), fresh, visible))
	print(string.format("  radiance luma mean %.4g max %.4g cd/m2, speed %.2f m/s, width %.2f mm", sum_luma / visible, max_luma, sum_speed / visible, sum_width / visible * 1000))
	print(string.format("  radiance rgb mean %.4g %.4g %.4g", sum_rgb[1] / visible, sum_rgb[2] / visible, sum_rgb[3] / visible))
	print(string.format("  offset from camera x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f", lo[1], hi[1], lo[2], hi[2], lo[3], hi[3]))
	print(string.format("  states falling %d landed %d hidden %d, visible landed y %.3f..%.3f, visible below the ground %d", states[0], states[1], states[2], landed_lo, landed_hi, below))
	local p = records[0]
	print(string.format("  particle 0: pos %.2f %.2f %.2f vel %.2f %.2f %.2f age %.2f life %.2f radiance %.1f %.1f %.1f", p.position[0], p.position[1], p.position[2], p.velocity[0], p.velocity[1], p.velocity[2], p.age, p.life, p.radiance[0], p.radiance[1], p.radiance[2]))
	system.ShutDown(0)
	return event.destroy_tag
end)
