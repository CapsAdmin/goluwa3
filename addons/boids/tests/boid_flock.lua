local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local damage = import("lua/damage.lua")
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
