local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
local fluid = import("goluwa/physics/fluid.lua")
local boids = import("lua/boids.lua")
import("lua/components/boid_flock.lua")
boids.Register(
	"test_boid",
	{
		Model = "",
		ClipSpeed = 0.4,
		MinSpeed = 0.8,
		MaxSpeed = 2.5,
		Size = Vec3(0.3, 0.4, 0.6),
		Center = Vec3(0, 0.2, 0),
	}
)

local function create_box(position, size)
	return Entity.New{
		transform = {Position = position, Scale = size},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
		},
	}
end

local function run(flock, seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
		flock:OnUpdate(1 / 60)
	end
end

local function spawn(count, radius)
	create_box(Vec3(0, -0.5, 0), Vec3(60, 1, 60))
	physics.UpdateFixed(1 / 60)
	local flock = boids.Spawn("test_boid", Vec3(0, 0, 0), count, radius).boid_flock
	run(flock, 0.1)
	return flock
end

T.TestPhysics("boids spawn on the ground", function()
	local flock = spawn(8, 4)
	T(#flock.boids)["=="](8)

	for _, boid in ipairs(flock.boids) do
		T(math.abs(boid.y))["<"](0.01)
		T(Vec3(boid.x, 0, boid.z):GetLength())["<="](4.01)
	end
end)

T.TestPhysics("boids run from a nearby actor", function()
	local flock = spawn(8, 2)
	local before = 0

	for _, boid in ipairs(flock.boids) do
		before = before + Vec3(boid.x, 0, boid.z):GetLength()
	end

	Entity.New{transform = {Position = Vec3(0, 0, 0)}, health = {}}
	run(flock, 2)
	local after = 0

	for _, boid in ipairs(flock.boids) do
		after = after + Vec3(boid.x, 0, boid.z):GetLength()
	end

	T(after / #flock.boids)[">"](before / #flock.boids + 1)
end)

T.TestPhysics("boids do not walk through walls", function()
	local flock = spawn(8, 1.5)
	create_box(Vec3(2, 0.5, 0), Vec3(0.3, 1, 30))
	Entity.New{transform = {Position = Vec3(-3, 0, 0)}, health = {}}
	run(flock, 5)

	for _, boid in ipairs(flock.boids) do
		T(boid.x)["<"](2)
	end
end)

T.TestPhysics("a killed boid leaves the flock as a physics body", function()
	local flock = spawn(3, 2)
	local entity = flock.boids[1].Owner
	damage.Deal(entity, {Damage = 100, Position = entity.transform:GetPosition()})
	run(flock, 0.1)
	T(#flock.boids)["=="](2)
	T(entity.rigid_body:GetMotionType())["=="]("dynamic")
end)

T.TestPhysics("birds fly within their height band around the flock", function()
	create_box(Vec3(0, -0.5, 0), Vec3(200, 1, 200))
	physics.UpdateFixed(1 / 60)
	local flock = boids.Spawn("bird", Vec3(0, 0, 0), 10, 10, {Model = ""}).boid_flock
	run(flock, 20)
	T(#flock.boids)["=="](10)

	for _, boid in ipairs(flock.boids) do
		T(boid.y)[">"](5)
		T(boid.y)["<"](60)
		T(Vec3(boid.x, 0, boid.z):GetLength())["<"](80)
		T(boid.speed)[">="](2)
	end
end)

T.TestPhysics("fish stay under the water surface and above the bottom", function()
	create_box(Vec3(0, -10.5, 0), Vec3(200, 1, 200))
	fluid.SetOceanLevel(0)
	physics.UpdateFixed(1 / 60)
	local flock = boids.Spawn("fish", Vec3(0, -5, 0), 12, 5, {Model = ""}).boid_flock
	run(flock, 10)
	fluid.SetOceanLevel(nil)
	T(#flock.boids)["=="](12)

	for _, boid in ipairs(flock.boids) do
		T(boid.y)["<"](0)
		T(boid.y)[">"](-10)
	end
end)

T.TestPhysics("frogs hop and land on the ground", function()
	create_box(Vec3(0, -0.5, 0), Vec3(60, 1, 60))
	physics.UpdateFixed(1 / 60)
	local flock = boids.Spawn("frog", Vec3(0, 0, 0), 5, 2, {Model = ""}).boid_flock
	run(flock, 0.1)
	local start = {}

	for i, boid in ipairs(flock.boids) do
		start[i] = Vec3(boid.x, 0, boid.z)
	end

	Entity.New{transform = {Position = Vec3(0, 0, 0)}, health = {}}
	run(flock, 3)
	local moved = 0

	for i, boid in ipairs(flock.boids) do
		if boid.on_ground then T(math.abs(boid.y))["<"](0.01) end

		if (Vec3(boid.x, 0, boid.z) - start[i]):GetLength() > 0.5 then
			moved = moved + 1
		end
	end

	T(moved)[">"](0)
end)

T.Test("Crysis flock archetype properties become flock settings", function()
	local settings = boids.SettingsFromCryProperties{
		Boid = {nCount = "20", object_Model = "", Size = "1.2", SizeRandom = "0.2"},
		Movement = {
			SpeedMin = "2.5",
			SpeedMax = "10",
			HeightMin = "5",
			HeightMax = "40",
			MaxAnimSpeed = "0.15",
		},
		Flocking = {
			bEnableFlocking = "0",
			FactorAlign = "20",
			FactorCohesion = "40",
			FieldOfViewAngle = "120",
		},
		Options = {VisibilityDist = "100", bObstacleAvoidance = "0"},
	}
	T(settings.Model)["=="](nil)
	T(settings.Scale)["=="](1.2)
	T(settings.MinSpeed)["=="](2.5)
	T(settings.HeightMax)["=="](40)
	T(settings.AnimSpeed)["=="](0.15)
	T(settings.Align)["=="](0)
	T(settings.Cohesion)["=="](40)
	T(settings.ObstacleAvoidance)["=="](false)
	T(settings.VisibilityDistance)["=="](100)
end)
