local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local demo = {}
local ORIGIN_Y = 1.6
local LAYERS = {
	core = {
		flipbook = "fire",
		count = 10,
		life = {0.6, 0.9},
		spawn = 0.2,
		out_speed = 0.3,
		up_speed = 0.8,
		radius = {0.45, 0.9},
		brightness = 2.2,
		from = {1, 0.85, 0.5},
		to = {1, 0.55, 0.15},
		fade_in = 0.15,
		additive = true,
	},
	flame = {
		flipbook = "fire",
		count = 22,
		life = {1.1, 1.7},
		spawn = 0.45,
		out_speed = 0.9,
		up_speed = 1.4,
		radius = {0.7, 1.5},
		brightness = 0.8,
		from = {1, 0.45, 0.08},
		to = {0.45, 0.06, 0.01},
		fade_in = 0.12,
		additive = true,
	},
	smoke = {
		flipbook = "smoke",
		count = 26,
		life = {3, 4.5},
		spawn = 1.5,
		shell = 0.5,
		lift = 1.4,
		delay = 1,
		out_speed = 0.5,
		up_speed = 1.8,
		radius = {0.9, 2.3},
		from = {0.14, 0.12, 0.1},
		to = {0.32, 0.31, 0.3},
		fade_in = 0.12,
		additive = false,
	},
}
local puffs = {}

local function respawn(p, layer)
	local cos_t = math.randomf(-1, 1)
	local sin_t = math.sqrt(1 - cos_t * cos_t)
	local phi = math.randomf(0, math.pi * 2)
	local dx, dy, dz = sin_t * math.cos(phi), cos_t, sin_t * math.sin(phi)
	local spawn = layer.shell and
		math.randomf(layer.shell, layer.spawn) or
		layer.spawn * math.randomf(0.4, 1)
	p.x, p.y, p.z = dx * spawn, ORIGIN_Y + (layer.lift or 0) + dy * spawn, dz * spawn
	local out = layer.out_speed * math.randomf(0.6, 1.2)
	p.vx, p.vy, p.vz = dx * out, dy * out * 0.5 + layer.up_speed * math.randomf(0.7, 1.2), dz * out
	p.life = math.randomf(layer.life[1], layer.life[2])
	p.delay = layer.delay and math.randomf(0, layer.delay) or 0
	p.size = math.randomf(0.75, 1.15)
	p.roll = math.randomf(0, math.pi * 2)
	p.spin = math.randomf(-0.5, 0.5)
	p.fps = math.randomf(12, 20)
	p.offset = math.random(0, 63)
end

for name, layer in pairs(LAYERS) do
	for i = 1, layer.count do
		local p = {layer = layer, age = 0}
		respawn(p, layer)
		p.age = math.randomf(-p.delay, p.life)
		puffs[#puffs + 1] = p
	end
end

local function step(p, dt, batch, frames)
	local layer = p.layer
	p.age = p.age + dt

	if p.age < 0 then return end

	if p.age > p.life then
		respawn(p, layer)
		p.age = -p.delay
		return
	end

	local t = p.age / p.life
	local drag = 1 - 0.6 * dt
	p.vx, p.vy, p.vz = p.vx * drag, p.vy * drag, p.vz * drag
	p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
	local radius = p.size * math.lerp(math.sqrt(t), layer.radius[1], layer.radius[2])
	local alpha = math.min(t / layer.fade_in, 1) * (1 - math.smoothstep(0.45, 1, t))
	local k = math.sqrt(t)
	local from, to = layer.from, layer.to
	local brightness = layer.brightness or 1
	local r = math.lerp(k, from[1], to[1]) * brightness
	local g = math.lerp(k, from[2], to[2]) * brightness
	local b = math.lerp(k, from[3], to[3]) * brightness
	local frame = (p.offset + math.floor(p.age * p.fps)) % frames
	local roll = p.roll + p.spin * p.age
	batch:Add(p.x, p.y, p.z, radius, r, g, b, alpha, frame, roll)
end

test_scene.Reset{sun = {elevation = test_scene.GetNumber("FIRE_SUN", 3), azimuth = 40}}
test_scene.Ground{size = 60, material = test_scene.Matte(0.4), collision = false}
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local light = Entity.New{
	Name = "fireball_light",
	transform = {Position = Vec3(0, ORIGIN_Y + 0.4, 0)},
	light_point = {Range = 30, OcclusionMap = false, Lumen = 0, Color = Color(1, 0.55, 0.2, 1)},
}
test_scene.GetRoot():AddChild(light)

event.AddListener("Update", "fireball_demo", function(dt)
	dt = math.min(dt, 0.05)
	light.light_point:SetLumen(2500 * (0.85 + 0.15 * math.sin(system.GetElapsedTime() * 23)))
	local smoke_batch, smoke_frames = vfx.GetFlipbookBatch("smoke")
	local fire_batch, fire_frames = vfx.GetFlipbookBatch("fire")

	for i = 1, #puffs do
		local p = puffs[i]

		if p.layer.flipbook == "fire" then
			step(p, dt, fire_batch, fire_frames)
		else
			step(p, dt, smoke_batch, smoke_frames)
		end
	end
end)

demo.puffs = puffs
return demo
