local Entity = import("goluwa/entities/entity.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local vfs = import("goluwa/vfs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local boids = {}
boids.Definitions = {}

function boids.Register(name, info)
	info.Name = name
	info.Behavior = info.Behavior or "ground"
	info.IdleClips = info.IdleClips or {"idle01"}
	info.WalkClip = info.WalkClip or "walk_loop"
	info.MaxClipRate = info.MaxClipRate or 4
	info.AnimSpeed = info.AnimSpeed or 1
	info.TurnRate = info.TurnRate or 8
	info.ScareDistance = info.ScareDistance or 5
	info.Health = info.Health or 5
	info.Mass = info.Mass or 1
	info.Scale = info.Scale or 1
	info.ScaleRandom = info.ScaleRandom or 0
	info.AvoidWater = info.AvoidWater ~= false
	info.ObstacleAvoidance = info.ObstacleAvoidance ~= false
	info.VisibilityDistance = info.VisibilityDistance or 100
	info.Align = info.Align or 0
	info.Cohesion = info.Cohesion or 0
	info.Separation = info.Separation or 1
	info.AttractMin = info.AttractMin or 5
	info.AttractMax = info.AttractMax or 20
	info.FieldOfView = info.FieldOfView or 250
	info.OriginFactor = info.OriginFactor or 0.1
	info.KeepHeight = info.KeepHeight or 1
	info.AvoidLand = info.AvoidLand or 10
	info.RandomAccel = info.RandomAccel or 0
	info.HeightMin = info.HeightMin or 0
	info.HeightMax = info.HeightMax or 1
	boids.Definitions[name] = info
	return info
end

local NATURAL = "Sounds/environment:random_oneshots_natural:"
boids.Register(
	"chicken",
	{
		Model = "Objects/Characters/animals/Birds/chicken/chicken.chr",
		CryClass = "Chickens",
		Sounds = {
			Idle = NATURAL .. "chicken_cluck",
			Scared = NATURAL .. "chicken_run",
			Die = NATURAL .. "chicken_dies",
		},
		SoundLevel = 80,
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
		Sounds = {
			Idle = NATURAL .. "turtle_idle",
			Scared = NATURAL .. "turtle_scared",
			Die = NATURAL .. "turtle_scared",
		},
		SoundLevel = 70,
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
boids.Register(
	"crab",
	{
		Model = "Objects/Characters/animals/crab/crab.chr",
		CryClass = "Crabs",
		Sounds = {
			Idle = NATURAL .. "crab_idle",
			Scared = NATURAL .. "crab_scared",
			Die = NATURAL .. "crab_idle",
		},
		SoundLevel = 60,
		AnimSpeed = 2,
		MinSpeed = 1,
		MaxSpeed = 2,
		AvoidWater = false,
		Size = Vec3(0.5, 0.25, 0.45),
		Center = Vec3(0, 0.13, 0),
		Mass = 2,
	}
)
boids.Register(
	"plover",
	{
		Model = "Objects/Characters/animals/Birds/plover/Plover.chr",
		CryClass = "Plover",
		Sounds = {
			Idle = NATURAL .. "sandpiper_idle",
			Scared = NATURAL .. "sandpiper_scared",
			Die = NATURAL .. "sandpiper_scared",
		},
		SoundLevel = 75,
		AnimSpeed = 0.5,
		MinSpeed = 0.5,
		MaxSpeed = 2.5,
		Size = Vec3(0.16, 0.3, 0.5),
		Center = Vec3(0, 0.3, -0.05),
	}
)
boids.Register(
	"frog",
	{
		Behavior = "frog",
		Model = "Objects/Characters/animals/frog/frog.chr",
		CryClass = "Frogs",
		Sounds = {
			Idle = NATURAL .. "frog_idle",
			Scared = NATURAL .. "frog_scared",
			Die = NATURAL .. "frog_idle",
		},
		SoundLevel = 70,
		WalkClip = "frog_walk_01",
		IdleClips = {"frog_idle_01"},
		MinSpeed = 2,
		MaxSpeed = 4,
		ScareDistance = 3,
		Size = Vec3(0.3, 0.2, 0.5),
		Center = Vec3(0, 0.05, 0.07),
	}
)
boids.Register(
	"bird",
	{
		Behavior = "bird",
		Model = "Objects/Characters/animals/Birds/tern/tern.chr",
		CryClass = "Birds",
		WalkClip = "fly_loop",
		AnimSpeed = 0.17,
		MinSpeed = 2,
		MaxSpeed = 5,
		HeightMin = 20,
		HeightMax = 40,
		KeepHeight = 10,
		Align = 1,
		Cohesion = 0.7,
		Separation = 20,
		AttractMin = 1,
		AttractMax = 7,
		Size = Vec3(1.4, 0.2, 0.65),
		Center = Vec3(0, 0, 0),
	}
)
boids.Register(
	"fish",
	{
		Behavior = "fish",
		Model = "Objects/Characters/animals/fish/reef_fish01.cgf",
		CryClass = "Fish",
		MinSpeed = 1,
		MaxSpeed = 2,
		HeightMin = 0,
		HeightMax = 20,
		RandomAccel = 2,
		Align = 0.7,
		Cohesion = 1,
		Separation = 3,
		AttractMin = 3,
		AttractMax = 20,
		FieldOfView = 100,
		ScareDistance = 10,
		VisibilityDistance = 80,
		Size = Vec3(0.05, 0.2, 0.32),
		Center = Vec3(0, 0, 0.12),
		Health = 1,
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

function boids.Spawn(kind, position, count, radius, settings)
	assert(
		boids.Definitions[kind],
		"unknown boid " .. kind .. ", they are " .. table.concat(boids.GetNames(), ", ")
	)
	return Entity.New{
		Name = kind .. " flock",
		transform = {Position = position},
		boid_flock = {
			Kind = kind,
			Count = count or 10,
			Radius = radius or 10,
			Settings = settings or {},
		},
	}
end

commands.Add("boids_spawn=string,number|nil", function(kind, count)
	local camera = render3d.GetCamera()
	local origin = camera:GetPosition()
	local forward = camera:GetRotation():GetForward()
	local hit = physics.RayCast(origin, forward, 30)
	boids.Spawn(kind, hit and hit.position or origin + forward * 5, count)
end)

do
	local function number(group, key)
		return group and tonumber(group[key])
	end

	function boids.SettingsFromCryProperties(properties)
		local boid = properties.Boid or {}
		local movement = properties.Movement
		local flocking = properties.Flocking
		local options = properties.Options
		local model = boid.object_Model ~= "" and boid.object_Model or nil
		local flocking_enabled = flocking and flocking.bEnableFlocking ~= "0"
		return {
			Model = model and (vfs.FindMixedCasePath((model:gsub("\\", "/"))) or model),
			Scale = number(boid, "Size"),
			ScaleRandom = number(boid, "SizeRandom"),
			MinSpeed = number(movement, "SpeedMin"),
			MaxSpeed = number(movement, "SpeedMax"),
			HeightMin = number(movement, "HeightMin"),
			HeightMax = number(movement, "HeightMax"),
			OriginFactor = number(movement, "FactorOrigin"),
			KeepHeight = number(movement, "FactorHeight"),
			AvoidLand = number(movement, "FactorAvoidLand"),
			RandomAccel = number(movement, "FactorRandomAcceleration"),
			AnimSpeed = number(movement, "MaxAnimSpeed"),
			Align = flocking and (flocking_enabled and number(flocking, "FactorAlign") or 0),
			Cohesion = number(flocking, "FactorCohesion"),
			Separation = number(flocking, "FactorSeparation"),
			AttractMin = number(flocking, "AttractDistMin"),
			AttractMax = number(flocking, "AttractDistMax"),
			FieldOfView = number(flocking, "FieldOfViewAngle"),
			VisibilityDistance = number(options, "VisibilityDist"),
			ObstacleAvoidance = options and options.bObstacleAvoidance and options.bObstacleAvoidance ~= "0",
			AvoidWater = options and options.bAvoidWater and options.bAvoidWater ~= "0",
		}
	end
end

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
					Settings = boids.SettingsFromCryProperties(entity.properties),
				},
			}
		end
	end
end)

return boids
