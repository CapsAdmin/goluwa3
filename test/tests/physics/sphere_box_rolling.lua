local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

local function run_roll_probe(platform_name, spawn_platform)
	local platform_ent = spawn_platform()
	local sphere_ent = Entity.New({Name = platform_name .. "_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 3, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0.08,
			AngularDamping = 0.35,
			AirLinearDamping = 0.02,
			AirAngularDamping = 0.05,
			Friction = 0.2,
			Restitution = 0.25,
			MaxLinearSpeed = 1000,
			MaxAngularSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(8, -6, 0))
	simulate_physics(240)
	local velocity = sphere:GetVelocity()
	local angular = sphere:GetAngularVelocity()
	local ratio = math.abs(velocity.x) / math.max(math.abs(angular.z) * 0.5, 0.00001)
	local grounded = sphere:GetGrounded()
	sphere_ent:Remove()
	platform_ent:Remove()
	return velocity, angular, ratio, grounded
end

T.Test3D("Sphere rolling on a rigid box keeps linear and angular motion in sync", function()
	local velocity, angular, ratio, grounded = run_roll_probe("box", function()
		local platform_ent = Entity.New({Name = "rigid_box_roll_platform"})
		platform_ent:AddComponent("transform")
		platform_ent.transform:SetPosition(Vec3(0, 0, 0))
		platform_ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(Vec3(24, 1, 24)),
				Size = Vec3(24, 1, 24),
				MotionType = "static",
				Friction = 0.85,
				Restitution = 0,
			}
		)
		return platform_ent
	end)
	T(grounded)["=="](true)
	T(math.abs(velocity.x))[">"](0.25)
	T(math.abs(angular.z))[">"](0.25)
	T(ratio)[">"](0.35)
end)