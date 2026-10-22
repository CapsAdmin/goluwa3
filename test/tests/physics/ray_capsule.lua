local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function create_capsule(position)
	return Entity.New{
		transform = {Position = position},
		rigid_body = {Shape = CapsuleShape.New(0.3, 1.4), MotionType = "static"},
	}
end

T.TestPhysics("rays hit the cylinder and both caps of a capsule", function()
	local capsule = create_capsule(Vec3(0, 0.7, -5))
	local side = physics.RayCast(Vec3(0, 0.7, 0), Vec3(0, 0, -1), 100, nil, nil, OPTIONS)
	T(side ~= nil)["=="](true)
	T(side.entity == capsule)["=="](true)
	T(side.distance)["~"](4.7, 1e-4)
	T(side.normal.z)["~"](1, 1e-4)
	local top = physics.RayCast(Vec3(0, 3, -5), Vec3(0, -1, 0), 100, nil, nil, OPTIONS)
	T(top.distance)["~"](3 - 1.4, 1e-4)
	T(top.normal.y)["~"](1, 1e-4)
	local bottom = physics.RayCast(Vec3(0, -3, -5), Vec3(0, 1, 0), 100, nil, nil, OPTIONS)
	T(bottom.distance)["~"](3 - 0, 1e-4)
	local cap = physics.RayCast(Vec3(0, 1.3, 0), Vec3(0, -0.1, -1), 100, nil, nil, OPTIONS)
	T(cap ~= nil)["=="](true)
	capsule:Remove()
end)

T.TestPhysics("rays miss a capsule beside it, beyond the maximum distance and from an ignored entity", function()
	local capsule = create_capsule(Vec3(0, 0.7, -5))
	T(physics.RayCast(Vec3(0.5, 0.7, 0), Vec3(0, 0, -1), 100, nil, nil, OPTIONS) == nil)["=="](true)
	T(physics.RayCast(Vec3(0, 0.7, 0), Vec3(0, 0, -1), 3, nil, nil, OPTIONS) == nil)["=="](true)
	T(physics.RayCast(Vec3(0, 0.7, 0), Vec3(0, 0, -1), 100, capsule, nil, OPTIONS) == nil)["=="](true)
	local wide = physics.RayCast(Vec3(0.5, 0.7, 0), Vec3(0, 0, -1), 100, nil, nil, {IgnoreRigidBodies = false, IgnoreKinematicBodies = false, TraceRadius = 0.3})
	T(wide ~= nil)["=="](true)
	capsule:Remove()
end)

T.TestPhysics("point sweeps of any length hit a thin capsule where they aim", function()
	local capsule = Entity.New{
		transform = {Position = Vec3(0, 1, -6)},
		rigid_body = {Shape = CapsuleShape.New(0.08, 0.6), MotionType = "kinematic"},
	}

	for _, length in ipairs{10, 25, 50, 100} do
		for offset = -0.07, 0.07, 0.035 do
			local hit = physics.Sweep(Vec3(offset, 1, 0), Vec3(0, 0, -length), 0, nil, nil, OPTIONS)
			T(hit ~= nil and hit.entity == capsule)["=="](true)
		end
	end

	T(physics.Sweep(Vec3(0.2, 1, 0), Vec3(0, 0, -50), 0, nil, nil, OPTIONS) == nil)["=="](true)
	capsule:Remove()
end)
