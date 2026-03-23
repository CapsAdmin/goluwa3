local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local capsule_shape = CapsuleShape.New

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

local function with_ccd(config)
	config.CCD = true
	return config
end

local function with_auto_ccd(config)
	config.AutoCCD = true
	return config
end

local function create_world_geometry_ground(name, size)
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local half = (size or 8) * 0.5
	local tri_a = Polygon3D.New()
	tri_a:AddVertex{pos = Vec3(-half, 0, -half), uv = Vec2(0, 0), normal = Vec3(0, 1, 0)}
	tri_a:AddVertex{pos = Vec3(half, 0, -half), uv = Vec2(1, 0), normal = Vec3(0, 1, 0)}
	tri_a:AddVertex{pos = Vec3(-half, 0, half), uv = Vec2(0, 1), normal = Vec3(0, 1, 0)}
	tri_a:BuildBoundingBox()
	tri_a:Upload()
	ground.model:AddPrimitive(tri_a)
	local tri_b = Polygon3D.New()
	tri_b:AddVertex{pos = Vec3(half, 0, -half), uv = Vec2(1, 0), normal = Vec3(0, 1, 0)}
	tri_b:AddVertex{pos = Vec3(half, 0, half), uv = Vec2(1, 1), normal = Vec3(0, 1, 0)}
	tri_b:AddVertex{pos = Vec3(-half, 0, half), uv = Vec2(0, 1), normal = Vec3(0, 1, 0)}
	tri_b:BuildBoundingBox()
	tri_b:Upload()
	ground.model:AddPrimitive(tri_b)
	ground.model:BuildAABB()
	ground:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New{Model = ground.model},
			MotionType = "static",
			GravityScale = 0,
			WorldGeometry = true,
		}
	)
	return ground
end

T.Test3D("Fast rigid sphere tunnels through thin static box by default without CCD", function()
	local blocker_ent = Entity.New({Name = "rigid_discrete_blocker"})
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
	local sphere_ent = Entity.New({Name = "rigid_discrete_sphere"})
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
	T(position.y)["<"](0)
	blocker_ent:Remove()
	sphere_ent:Remove()
end)

T.Test("Auto CCD activates for fast linear motion", function()
	local body = test_helpers.CreateStubBody{
		MotionType = "dynamic",
		AutoCCD = true,
		AutoCCDThreshold = 0.5,
		HalfExtents = Vec3(0.5, 0.5, 0.5),
		PreviousPosition = Vec3(0, 0, 0),
		Position = Vec3(1, 0, 0),
	}
	T(pair_solver_helpers.ShouldUseCCD(body))["=="](true)
end)

T.Test("Auto CCD stays disabled for short motion", function()
	local body = test_helpers.CreateStubBody{
		MotionType = "dynamic",
		AutoCCD = true,
		AutoCCDThreshold = 0.5,
		HalfExtents = Vec3(0.5, 0.5, 0.5),
		PreviousPosition = Vec3(0, 0, 0),
		Position = Vec3(0.1, 0, 0),
	}
	T(pair_solver_helpers.ShouldUseCCD(body))["=="](false)
end)

T.Test3D("Fast rigid sphere does not tunnel through thin static box with auto CCD", function()
	local blocker_ent = Entity.New({Name = "rigid_auto_ccd_blocker"})
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
	local sphere_ent = Entity.New({Name = "rigid_auto_ccd_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 8, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		with_auto_ccd{
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

T.Test3D("Fast rigid sphere does not tunnel through thin static box when CCD is enabled", function()
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
		with_ccd{
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
		with_ccd{
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

T.Test3D("Fast rigid box does not tunnel through triangle world floor", function()
	local ground = create_world_geometry_ground("rigid_ccd_triangle_box_ground", 8)
	local box_ent = Entity.New({Name = "rigid_ccd_triangle_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 8, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		with_ccd{
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
	T(position.y)[">="](0.45)
	T(box:GetGrounded() or box:GetVelocity().y > -10)["=="](true)
	ground:Remove()
	box_ent:Remove()
end)

T.Test3D("Fast rigid capsule does not tunnel through triangle world floor", function()
	local ground = create_world_geometry_ground("rigid_ccd_triangle_capsule_ground", 8)
	local capsule_ent = Entity.New({Name = "rigid_ccd_triangle_capsule"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 8, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		with_ccd{
			Shape = capsule_shape(0.5, 2.0),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	capsule:SetVelocity(Vec3(0, -320, 0))
	simulate_physics(1, 1 / 10)
	local position = capsule_ent.transform:GetPosition()
	T(position.y)[">="](1.0)
	T(capsule:GetGrounded() or capsule:GetVelocity().y > -10)["=="](true)
	ground:Remove()
	capsule_ent:Remove()
end)

T.Test3D("Fast rigid bodies do not tunnel through other moving rigid bodies", function()
	local left_ent = Entity.New({Name = "rigid_ccd_dynamic_left"})
	left_ent:AddComponent("transform")
	left_ent.transform:SetPosition(Vec3(-4, 1, 0))
	local left = left_ent:AddComponent(
		"rigid_body",
		with_ccd{
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
		with_ccd{
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
		with_ccd{
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
