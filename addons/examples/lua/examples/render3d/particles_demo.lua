local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local weather = import("goluwa/render3d/weather.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Entity = import("goluwa/entities/entity.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local demo = {}
local MODES = {"shelter_map", "scene_depth", "rays"}
local index = 3
test_scene.Reset{sun = {elevation = 6, azimuth = 200}, clouds = {}}
test_scene.Ground{size = 120, material = test_scene.Matte(0.35), collision = false}
test_scene.Room{
	pos = Vec3(6, 0, 8),
	size = Vec3(6, 3, 6),
	material = test_scene.Matte(0.6),
	openings = {{wall = "-z", x = 0, y = 1, width = 1.6, height = 2}},
}
test_scene.Box{
	name = "wall",
	pos = Vec3(0, 1.5, 7),
	size = Vec3(8, 3, 0.4),
	material = test_scene.Matte(0.55),
}
test_scene.Box{
	name = "pillar",
	pos = Vec3(3, 1.5, 2),
	size = Vec3(0.6, 3, 0.6),
	material = test_scene.Matte(0.5),
}
weather.SetRain(1)

local function add_emitter(name, component, position, direction)
	local entity = Entity.New{Name = name}
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	local dir = direction:GetNormalized()
	local axis = Vec3(0, 1, 0):GetCross(dir)
	entity.transform:SetRotation(Quat(axis.x, axis.y, axis.z, 1 + dir.y):Normalize())
	local emitter = entity:AddComponent(component)
	test_scene.GetRoot():AddChild(entity)
	return emitter
end

demo.sparks = add_emitter("sparks", "particle_emitter_gpu", Vec3(0, 0.3, 4), Vec3(0, 1, 0.55))
demo.sparks:SetRate(500)
demo.sparks:SetMaxParticles(1500)
demo.sparks:SetShape("point")
demo.sparks:SetSpread(28)
demo.sparks:SetSpeedMin(3.5)
demo.sparks:SetSpeedMax(7)
demo.sparks:SetLifetimeMin(1)
demo.sparks:SetLifetimeMax(2.5)
demo.sparks:SetSizeStart(0.02)
demo.sparks:SetSizeEnd(0.012)
demo.sparks:SetDrag(0.3)
demo.sparks:SetLit(false)
demo.sparks:SetEmissive(1e5)
demo.sparks:SetColorStart(Color(1, 0.45, 0.12, 1))
demo.sparks:SetColorEnd(Color(1, 0.2, 0.05, 0))
demo.sparks:SetRestitution(0.55)
demo.sparks:SetFriction(0.25)
demo.debris = add_emitter("debris", "particle_emitter_cpu", Vec3(0.5, 0.3, 4), Vec3(0.2, 1, 0.6))
demo.debris:SetMesh("cube")
demo.debris:SetRate(25)
demo.debris:SetMaxParticles(200)
demo.debris:SetSpread(25)
demo.debris:SetSpeedMin(3)
demo.debris:SetSpeedMax(6)
demo.debris:SetLifetimeMin(4)
demo.debris:SetLifetimeMax(6)
demo.debris:SetSizeStart(0.12)
demo.debris:SetSizeEnd(0)
demo.debris:SetSpin(240)
demo.debris:SetDrag(0.05)
demo.debris:SetMaterial(test_scene.Matte(Color(0.3, 0.2, 0.14, 1)))
demo.debris:SetCollision("rays")
demo.debris:SetRestitution(0.4)
demo.debris:SetFriction(0.3)

function demo.SetCollision(mode)
	demo.sparks:SetCollision(mode)
	logf("[particles_demo] sparks collide with: %s\n", mode)
end

commands.Add("particles_demo_collision=string[cycle]", function(mode)
	if mode == "cycle" then
		index = index % #MODES + 1
		mode = MODES[index]
	end

	demo.SetCollision(mode)
end)

commands.Add("particles_demo_rain=number", function(rate)
	weather.SetRain(rate)
end)

demo.SetCollision(MODES[index])
local next_switch = system.GetElapsedTime() + 6

if os.getenv("PARTICLES_DEMO_CYCLE") ~= "0" then
	event.AddListener("Update", "particles_demo", function()
		if system.GetElapsedTime() < next_switch then return end

		next_switch = system.GetElapsedTime() + 6
		index = index % #MODES + 1
		demo.SetCollision(MODES[index])
	end)
end

return demo
