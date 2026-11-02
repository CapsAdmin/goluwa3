local event = import("goluwa/event.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
test_scene.Reset{sun = {elevation = 35, azimuth = 40}}
test_scene.Ground{size = 60, material = test_scene.Matte(0.4), collision = false}
local puffs = {}
local COUNT = 60
math.randomseed(3)

for i = 1, COUNT do
	puffs[i] = {
		x = math.randomf(-0.8, 0.8),
		z = math.randomf(-0.8, 0.8),
		age = math.randomf(0, 5),
		life = math.randomf(4, 6),
		offset = math.random(0, 63),
		roll = math.randomf(0, 6.28),
		spin = math.randomf(-0.3, 0.3),
		fps = math.randomf(6, 12),
		drift = math.randomf(-0.5, 0.5),
		size = math.randomf(0.7, 1.1),
	}
end

event.AddListener("Update", "smoke_demo", function(dt)
	local batch, frames = vfx.GetFlipbookBatch("smoke")

	for _, p in ipairs(puffs) do
		p.age = p.age + dt

		if p.age > p.life then p.age = 0 end

		local t = p.age / p.life
		local radius = p.size * (0.5 + t * 1.6)
		local alpha = math.min(t * 6, 1) * (1 - t) * 0.9
		local x, y, z = p.x + p.drift * t, 0.8 + t * 3.2, p.z
		local frame = (p.offset + math.floor(p.age * p.fps)) % frames
		batch:Add(x, y, z, radius, 0.45, 0.43, 0.42, alpha, frame, p.roll + p.spin * p.age)
	end
end)
