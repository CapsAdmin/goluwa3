local Entity = import("goluwa/entities/entity.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local boids = {}
boids.Definitions = {}

function boids.Register(name, info)
	info.Name = name
	info.IdleClips = info.IdleClips or {"idle01"}
	info.WalkClip = info.WalkClip or "walk_loop"
	info.MaxClipRate = info.MaxClipRate or 4
	info.TurnRate = info.TurnRate or 8
	info.ScareDistance = info.ScareDistance or 5
	info.Health = info.Health or 5
	info.Mass = info.Mass or 1
	info.AvoidWater = info.AvoidWater ~= false
	boids.Definitions[name] = info
	return info
end

boids.Register(
	"chicken",
	{
		Model = "Objects/Characters/animals/Birds/chicken/chicken.chr",
		CryClass = "Chickens",
		ClipSpeed = 0.37,
		MinSpeed = 0.8,
		MaxSpeed = 2.5,
		Size = Vec3(0.3, 0.45, 0.7),
		Center = Vec3(0, 0.25, -0.08),
		Mass = 2,
	}
)
boids.Register(
	"turtle",
	{
		Model = "Objects/Characters/animals/turtle/turtle.chr",
		CryClass = "Turtles",
		ClipSpeed = 0.055,
		MinSpeed = 0.1,
		MaxSpeed = 0.15,
		MaxClipRate = 3,
		TurnRate = 1,
		FreezeWhenScared = true,
		Size = Vec3(0.6, 0.3, 0.8),
		Center = Vec3(0, 0.15, 0),
		Health = 20,
		Mass = 5,
	}
)

function boids.GetNames()
	local names = {}

	for name in pairs(boids.Definitions) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

function boids.Spawn(kind, position, count, radius)
	assert(
		boids.Definitions[kind],
		"unknown boid " .. kind .. ", they are " .. table.concat(boids.GetNames(), ", ")
	)
	return Entity.New{
		Name = kind .. " flock",
		transform = {Position = position},
		boid_flock = {Kind = kind, Count = count or 10, Radius = radius or 10},
	}
end

commands.Add("boids_spawn=string,number|nil", function(kind, count)
	local camera = render3d.GetCamera()
	local origin = camera:GetPosition()
	local forward = camera:GetRotation():GetForward()
	local hit = physics.RayCast(origin, forward, 30)
	boids.Spawn(kind, hit and hit.position or origin + forward * 5, count)
end)

event.AddListener("CryEntity", "boids", function(entity)
	for name, info in pairs(boids.Definitions) do
		if info.CryClass == entity.class then
			local boid = entity.properties.Boid or {}
			local options = entity.properties.Options or {}

			if options.bActivate == "0" then return end

			return {
				boid_flock = {
					Kind = name,
					Count = tonumber(boid.nCount) or 10,
					Radius = tonumber(options.Radius) or 10,
				},
			}
		end
	end
end)

return boids
