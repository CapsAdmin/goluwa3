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

T.Test3D("Rigid body materials support richer friction and restitution combination behavior", function()
	do
		local platform_ent = Entity.New({Name = "rigid_material_average_platform"})
		platform_ent:AddComponent("transform")
		platform_ent.transform:SetPosition(Vec3(0, 1, 0))
		platform_ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(Vec3(8, 1, 8)),
				Size = Vec3(8, 1, 8),
				MotionType = "static",
				Restitution = 0,
				RestitutionCombineMode = "average",
			}
		)
		local sphere_ent = Entity.New({Name = "rigid_material_average_sphere"})
		sphere_ent:AddComponent("transform")
		sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
		local sphere = sphere_ent:AddComponent(
			"rigid_body",
			{
				Shape = sphere_shape(0.5),
				Radius = 0.5,
				LinearDamping = 0,
				AngularDamping = 0,
				MaxLinearSpeed = 1000,
				Restitution = 1,
				RestitutionCombineMode = "average",
			}
		)
		sphere:SetVelocity(Vec3(0, -18, 0))
		simulate_physics(18)
		local bounce_velocity = sphere:GetVelocity()
		T(bounce_velocity.y)[">"](4)
		T(bounce_velocity.y)["<"](12)
		sphere_ent:Remove()
		platform_ent:Remove()
	end

	do
		local platform_ent = Entity.New({Name = "rigid_material_max_platform"})
		platform_ent:AddComponent("transform")
		platform_ent.transform:SetPosition(Vec3(0, 1, 0))
		platform_ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(Vec3(10, 1, 10)),
				Size = Vec3(10, 1, 10),
				MotionType = "static",
				Friction = 1,
				FrictionCombineMode = "max",
			}
		)
		local sphere_ent = Entity.New({Name = "rigid_material_max_sphere"})
		sphere_ent:AddComponent("transform")
		sphere_ent.transform:SetPosition(Vec3(0, 3, 0))
		local sphere = sphere_ent:AddComponent(
			"rigid_body",
			{
				Shape = sphere_shape(0.5),
				Radius = 0.5,
				LinearDamping = 0,
				AngularDamping = 0,
				MaxLinearSpeed = 1000,
				Friction = 0.04,
				FrictionCombineMode = "max",
			}
		)
		sphere:SetVelocity(Vec3(10, -8, 0))
		simulate_physics(60)
		local velocity = sphere:GetVelocity()
		local angular = sphere:GetAngularVelocity()
		local rolling_ratio = math.abs(velocity.x) / math.max(math.abs(angular.z) * 0.5, 0.00001)
		T(sphere:GetGrounded())["=="](true)
		T(math.abs(velocity.x))[">"](4.0)
		T(math.abs(velocity.x))["<"](9.5)
		T(math.abs(angular.z))[">"](8.0)
		T(rolling_ratio)[">"](0.75)
		T(rolling_ratio)["<"](1.25)
		sphere_ent:Remove()
		platform_ent:Remove()
	end
end)

T.Test3D("Rigid body materials support rolling friction", function()
	local platform_ent = Entity.New({Name = "rigid_material_rolling_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(24, 1, 24)),
			Size = Vec3(24, 1, 24),
			MotionType = "static",
			Friction = 0,
			RollingFriction = 2.5,
			RollingFrictionCombineMode = "max",
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_material_rolling_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			MaxLinearSpeed = 1000,
			Friction = 0,
			RollingFriction = 0,
			RollingFrictionCombineMode = "max",
		}
	)
	simulate_physics(120)
	T(sphere:GetGrounded())["=="](true)
	sphere:SetVelocity(Vec3(10, 0, 0))
	simulate_physics(240)
	local velocity = sphere:GetVelocity()
	local angular = sphere:GetAngularVelocity()
	T(math.abs(velocity.x))["<"](1.0)
	T(math.abs(angular.z))["<"](2.0)
	sphere_ent:Remove()
	platform_ent:Remove()
end)

T.Test("Rigid body materials expose separate static friction combination behavior", function()
	local body_a = test_helpers.CreateStubBody{
		Friction = 0.1,
		StaticFriction = 0.8,
		FrictionCombineMode = "max",
		StaticFrictionCombineMode = "average",
	}
	local body_b = test_helpers.CreateStubBody{
		Friction = 0.6,
		StaticFriction = 1.4,
		FrictionCombineMode = "max",
		StaticFrictionCombineMode = "average",
	}
	local body_c = test_helpers.CreateStubBody{
		Friction = 0.3,
		FrictionCombineMode = "multiply",
	}
	local dynamic_friction = physics.solver:GetPairFriction(body_a, body_b)
	local static_friction = physics.solver:GetPairStaticFriction(body_a, body_b)
	local fallback_static = physics.solver:GetPairStaticFriction(body_a, body_c)
	T(dynamic_friction)["=="](0.6)
	T(static_friction)["=="](1.1)
	T(fallback_static)["=="](0.24)
	T(static_friction)[">"](dynamic_friction)
end)

T.Test3D("Rigid body static friction reduces shallow-slope drift", function()
	local function run_probe(name, static_friction)
		local ramp_ent = Entity.New({Name = name .. "_ramp"})
		ramp_ent:AddComponent("transform")
		ramp_ent.transform:SetPosition(Vec3(0, 1, 0))
		ramp_ent.transform:SetAngles(Deg3(0, 0, -5))
		ramp_ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(Vec3(28, 1, 20)),
				Size = Vec3(28, 1, 20),
				MotionType = "static",
				Friction = 0.02,
				StaticFriction = static_friction,
				FrictionCombineMode = "max",
				StaticFrictionCombineMode = "max",
			}
		)
		local box_ent = Entity.New({Name = name .. "_box"})
		box_ent:AddComponent("transform")
		box_ent.transform:SetPosition(Vec3(0, 3.1, 0))
		local box = box_ent:AddComponent(
			"rigid_body",
			{
				Shape = box_shape(Vec3(1, 1, 1)),
				Size = Vec3(1, 1, 1),
				LinearDamping = 0,
				AngularDamping = 0,
				AirLinearDamping = 0,
				AirAngularDamping = 0,
				MaxLinearSpeed = 1000,
				Friction = 0.02,
				StaticFriction = static_friction,
				FrictionCombineMode = "max",
				StaticFrictionCombineMode = "max",
			}
		)
		simulate_physics(180)
		local settled = box_ent.transform:GetPosition():Copy()
		simulate_physics(240)
		local final_position = box_ent.transform:GetPosition():Copy()
		local drift = (final_position - settled):GetLength()
		local grounded = box:GetGrounded()
		box_ent:Remove()
		ramp_ent:Remove()
		return drift, grounded, final_position, settled
	end

	local low_drift, low_grounded = run_probe("rigid_material_low_static", 0.02)
	local high_drift, high_grounded = run_probe("rigid_material_high_static", 1.25)
	T(low_grounded)["=="](true)
	T(high_grounded)["=="](true)
	T(high_drift)["<"](0.35)
	T(high_drift)["<"](low_drift * 0.6)
end)
