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

T.Test3D("Fast rigid sphere does not tunnel through thin static box", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_blocker"})
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
	local sphere_ent = Entity.New({Name = "rigid_ccd_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 8, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(0, -320, 0))
	simulate_physics(1, 1 / 10)
	local position = sphere_ent.transform:GetPosition()
	T(position.y)[">="](1.55)
	T(math.abs(position.x))["<"](0.1)
	blocker_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Fast rigid boxes do not tunnel through thin static world geometry", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_box_blocker"})
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
	local box_ent = Entity.New({Name = "rigid_ccd_fast_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 8, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	box:SetVelocity(Vec3(0, -320, 0))
	simulate_physics(1, 1 / 10)
	local position = box_ent.transform:GetPosition()
	blocker_ent:Remove()
	box_ent:Remove()
	T(position.y)[">="](1.45)
	T(math.abs(position.x))["<"](0.15)
	T(math.abs(position.z))["<"](0.15)
end)

T.Test3D("Fast rigid bodies do not tunnel through other moving rigid bodies", function()
	local left_ent = Entity.New({Name = "rigid_ccd_dynamic_left"})
	left_ent:AddComponent("transform")
	left_ent.transform:SetPosition(Vec3(-4, 1, 0))
	local left = left_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	local right_ent = Entity.New({Name = "rigid_ccd_dynamic_right"})
	right_ent:AddComponent("transform")
	right_ent.transform:SetPosition(Vec3(4, 1, 0))
	local right = right_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	left:SetVelocity(Vec3(140, 0, 0))
	right:SetVelocity(Vec3(-140, 0, 0))
	simulate_physics(1, 1 / 30)
	local left_pos = left_ent.transform:GetPosition()
	local right_pos = right_ent.transform:GetPosition()
	local separation = (right_pos - left_pos):GetLength()
	left_ent:Remove()
	right_ent:Remove()
	T(separation)[">="](0.95)
	T(left_pos.x)["<="](right_pos.x)
end)

T.Test3D("Fast rotating rigid box does not miss a thin static box", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_rotating_box_target"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0.6, 1.6, 0))
	blocker_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(0.3, 0.3, 1)),
			Size = Vec3(0.3, 0.3, 1),
			MotionType = "static",
		}
	)
	local rod_ent = Entity.New({Name = "rigid_ccd_rotating_box_rod"})
	rod_ent:AddComponent("transform")
	rod_ent.transform:SetPosition(Vec3(0, 1, 0))
	local rod = rod_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(0.15, 4, 0.15)),
			Size = Vec3(0.15, 4, 0.15),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxAngularSpeed = 1000,
			Restitution = 0,
		}
	)
	local enter_hits = 0

	rod_ent:AddLocalListener("OnCollisionEnter", function()
		enter_hits = enter_hits + 1
	end)

	rod:SetAngularVelocity(Vec3(0, 0, -16))
	simulate_physics(1, 1 / 10)
	local angles = rod_ent.transform:GetRotation():GetAngles()
	rod_ent:Remove()
	blocker_ent:Remove()
	T(enter_hits)[">"](0)
	T(math.abs(angles.z))["<"](1.45)
end)
