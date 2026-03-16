local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local capsule_shape = CapsuleShape.New
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local create_flat_ground = test_helpers.CreateFlatGround

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Capsule rigid body lands on ground mesh", function()
	local ground = create_flat_ground("capsule_ground", 16)
	local body_ent = Entity.New({Name = "capsule_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(300)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.95)
	T(position.y)["<="](1.05)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test("Capsule shape mass properties include cylindrical section", function()
	local short = capsule_shape(0.5, 1.0)
	local tall = capsule_shape(0.5, 3.0)
	local mock_body = test_helpers.CreateMockBody{
		AutomaticMass = true,
		Density = 1,
		IsDynamic = true,
	}
	local short_mass = select(1, short:GetMassProperties(mock_body))
	local tall_mass = select(1, tall:GetMassProperties(mock_body))
	local short_half = short:GetHalfExtents()
	local tall_half = tall:GetHalfExtents()
	T(tall_mass)[">"](short_mass)
	T(short_half.y)["=="](0.5)
	T(tall_half.y)["=="](1.5)
end)

T.Test3D("Capsule rigid body can rest on static box", function()
	local ground = create_flat_ground("capsule_box_ground", 16)
	local box_ent = Entity.New({Name = "capsule_static_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_on_box"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 4, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(240)
	local position = capsule_ent.transform:GetPosition()
	T(capsule:GetGrounded())["=="](true)
	T(position.y)[">="](2.05)
	T(position.y)["<="](2.55)
	capsule_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.Test3D("Capsule rigid body rolls off rotated static box instead of resting on its AABB", function()
	local ground = create_flat_ground("capsule_rotated_box_ground", 20)
	local ramp_ent = Entity.New({Name = "capsule_rotated_box"})
	ramp_ent:AddComponent("transform")
	ramp_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	ramp_ent.transform:SetAngles(Deg3(0, 0, -35))
	ramp_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4, 1, 4)),
			Size = Vec3(4, 1, 4),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_rotated_box_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.4,
		}
	)
	simulate_physics(240)
	local position = capsule_ent.transform:GetPosition()
	T(math.abs(position.x))[">"](0.45)
	T(position.y)["<"](5.0)
	T(capsule:GetGroundNormal().y)[">"](0.2)
	capsule_ent:Remove()
	ramp_ent:Remove()
	ground:Remove()
end)

T.Test3D("Fast capsule does not tunnel through thin static box", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(6, 0.2, 6)),
			Size = Vec3(6, 0.2, 6),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 8, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(0, -320, 0))
	simulate_physics(1, 1 / 10)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.y)[">="](2.05)
	T(math.abs(position.x))["<"](0.1)
	T(math.abs(position.z))["<"](0.1)
end)

T.Test3D("Fast capsule does not tunnel through static sphere", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_sphere_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.7),
			Radius = 0.7,
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_vs_sphere_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(320, 0, 0))
	simulate_physics(1, 1 / 20)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.x)["<"](-0.6)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)

T.Test3D("Fast sphere does not tunnel through static capsule", function()
	local blocker_ent = Entity.New({Name = "sphere_ccd_capsule_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "sphere_ccd_vs_capsule_body"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.6),
			Radius = 0.6,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(320, 0, 0))
	simulate_physics(1, 1 / 20)
	local position = sphere_ent.transform:GetPosition()
	blocker_ent:Remove()
	sphere_ent:Remove()
	T(position.x)["<"](-0.6)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)

T.Test3D("Fast capsule does not tunnel through static capsule", function()
	local blocker_ent = Entity.New({Name = "capsule_ccd_capsule_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			MotionType = "static",
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_ccd_vs_capsule_body"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(-8, 1.5, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = capsule_shape(0.5, 2.0),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(320, 0, 0))
	simulate_physics(1, 1 / 20)
	local position = capsule_ent.transform:GetPosition()
	blocker_ent:Remove()
	capsule_ent:Remove()
	T(position.x)["<"](-0.8)
	T(math.abs(position.y - 1.5))["<"](0.2)
	T(math.abs(position.z))["<"](0.1)
end)