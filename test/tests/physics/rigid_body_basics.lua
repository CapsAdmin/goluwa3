local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local create_flat_ground = test_helpers.CreateFlatGround

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Rigid body smoke test lands on ground mesh", function()
	local ground = create_flat_ground("rigid_body_ground", 4)
	local body_ent = Entity.New({Name = "rigid_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(240)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.45)
	T(position.y)["<="](0.7)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid body ground damping does not slow falling", function()
	local ground = create_flat_ground("rigid_body_damping_ground", 4)
	local body_ent = Entity.New({Name = "rigid_body_ground_damping"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 6,
			AngularDamping = 2,
		}
	)
	simulate_physics(120)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.45)
	T(position.y)["<="](0.7)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid sphere can move along uneven ground", function()
	local ground = Entity.New({Name = "rigid_body_slope_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local tri_a = Polygon3D.New()
	tri_a:AddVertex{pos = Vec3(-4, 2, -4), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	tri_a:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	tri_a:AddVertex{pos = Vec3(-4, 2, 4), uv = Vec2(0, 1), normal = Vec3(0, -1, 0)}
	tri_a:BuildBoundingBox()
	tri_a:Upload()
	ground.model:AddPrimitive(tri_a)
	local tri_b = Polygon3D.New()
	tri_b:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	tri_b:AddVertex{pos = Vec3(4, 0, 4), uv = Vec2(1, 1), normal = Vec3(0, -1, 0)}
	tri_b:AddVertex{pos = Vec3(-4, 2, 4), uv = Vec2(0, 1), normal = Vec3(0, -1, 0)}
	tri_b:BuildBoundingBox()
	tri_b:Upload()
	ground.model:AddPrimitive(tri_b)
	ground.model:BuildAABB()
	local body_ent = Entity.New({Name = "rigid_body_slope"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(-1.5, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(120)
	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.x)[">"](0.5)
	T(position.y)[">="](0.8)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Fast rigid sphere does not tunnel through triangle world floor", function()
	local ground = create_flat_ground("rigid_fast_sphere_ground", 6)
	local body_ent = Entity.New({Name = "rigid_fast_sphere"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	body:SetVelocity(Vec3(0, -60, 0))
	simulate_physics(12)
	local position = body_ent.transform:GetPosition()
	T(position.y)[">="](0.4)
	T(body:GetGrounded() or body:GetVelocity().y > -5)["=="](true)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid spheres separate without exploding", function()
	local ground = create_flat_ground("rigid_pair_ground")
	local sphere_a = Entity.New({Name = "rigid_pair_a"})
	sphere_a:AddComponent("transform")
	sphere_a.transform:SetPosition(Vec3(-0.45, 2.5, 0))
	local body_a = sphere_a:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	local sphere_b = Entity.New({Name = "rigid_pair_b"})
	sphere_b:AddComponent("transform")
	sphere_b.transform:SetPosition(Vec3(0.45, 2.5, 0))
	local body_b = sphere_b:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	simulate_physics(180)
	local pos_a = sphere_a.transform:GetPosition()
	local pos_b = sphere_b.transform:GetPosition()
	local separation = (pos_b - pos_a):GetLength()
	T(body_a:GetGrounded())["=="](true)
	T(body_b:GetGrounded())["=="](true)
	T(separation)[">="](0.95)
	T(math.abs(pos_a.x))["<"](3)
	T(math.abs(pos_b.x))["<"](3)
	sphere_a:Remove()
	sphere_b:Remove()
	ground:Remove()
end)
