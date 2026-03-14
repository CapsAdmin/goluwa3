local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/mocks.lua")
local capsule_shape = CapsuleShape.New
local box_shape = BoxShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function create_flat_ground(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	return ground
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
	T(position.y)[">="](2.45)
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