local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test3D("Physics body lands on ground mesh", function()
	local ground = Entity.New({Name = "physics_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-4, 0, -4), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 4), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local body_ent = Entity.New({Name = "kinematic_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"kinematic_body",
		{
			Radius = 0.5,
			Acceleration = 0,
			AirAcceleration = 0,
			LinearDamping = 0,
		}
	)

	for _ = 1, 180 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.49)
	T(position.y)["<="](0.55)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid body smoke test lands on ground mesh", function()
	local ground = Entity.New({Name = "rigid_body_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-4, 0, -4), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 4), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local body_ent = Entity.New({Name = "rigid_body"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)

	for _ = 1, 240 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](0.45)
	T(position.y)["<="](0.7)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Kinematic body can stand on rigid body", function()
	local ground = Entity.New({Name = "kinematic_rigid_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local ground_poly = Polygon3D.New()
	ground_poly:AddVertex{pos = Vec3(-6, 0, -6), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	ground_poly:AddVertex{pos = Vec3(0, 0, 6), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	ground_poly:AddVertex{pos = Vec3(6, 0, -6), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	ground_poly:BuildBoundingBox()
	ground_poly:Upload()
	ground.model:AddPrimitive(ground_poly)
	ground.model:BuildAABB()
	local platform_ent = Entity.New({Name = "rigid_body_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	local platform_poly = Polygon3D.New()
	platform_poly:CreateSphere(1)
	platform_poly:BuildBoundingBox()
	platform_poly:Upload()
	platform_ent:AddComponent("model")
	platform_ent.model:AddPrimitive(platform_poly)
	platform_ent.model:BuildAABB()
	platform_ent:AddComponent("rigid_body", {
		Shape = "sphere",
		Radius = 1,
		Static = true,
	})
	local body_ent = Entity.New({Name = "kinematic_on_rigid"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent(
		"kinematic_body",
		{
			Radius = 0.5,
			Acceleration = 0,
			AirAcceleration = 0,
			LinearDamping = 0,
		}
	)

	for _ = 1, 240 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.y)[">="](2.3)
	T(position.y)["<="](2.7)
	T(body:GetGroundNormal().y)[">"](0.9)
	body_ent:Remove()
	platform_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid body ground damping does not slow falling", function()
	local ground = Entity.New({Name = "rigid_body_damping_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-4, 0, -4), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 4), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(4, 0, -4), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local body_ent = Entity.New({Name = "rigid_body_ground_damping"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = body_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 6,
			AngularDamping = 2,
		}
	)

	for _ = 1, 120 do
		physics.Update(1 / 120)
	end

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
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)

	for _ = 1, 120 do
		physics.Update(1 / 120)
	end

	local position = body_ent.transform:GetPosition()
	T(body:GetGrounded())["=="](true)
	T(position.x)[">"](0.5)
	T(position.y)[">="](0.8)
	body_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid spheres separate without exploding", function()
	local ground = Entity.New({Name = "rigid_pair_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-8, 0, -8), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 8), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(8, 0, -8), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local sphere_a = Entity.New({Name = "rigid_pair_a"})
	sphere_a:AddComponent("transform")
	sphere_a.transform:SetPosition(Vec3(-0.45, 2.5, 0))
	local body_a = sphere_a:AddComponent("rigid_body", {
		Shape = "sphere",
		Radius = 0.5,
	})
	local sphere_b = Entity.New({Name = "rigid_pair_b"})
	sphere_b:AddComponent("transform")
	sphere_b.transform:SetPosition(Vec3(0.45, 2.5, 0))
	local body_b = sphere_b:AddComponent("rigid_body", {
		Shape = "sphere",
		Radius = 0.5,
	})

	for _ = 1, 180 do
		physics.Update(1 / 120)
	end

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

T.Test3D("Rigid sphere can rest on rigid box", function()
	local ground = Entity.New({Name = "rigid_box_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-8, 0, -8), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 8), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(8, 0, -8), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	local box_ent = Entity.New({Name = "rigid_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(2, 1, 2),
		Static = true,
	})
	local sphere_ent = Entity.New({Name = "rigid_sphere_on_box"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 3, 0))
	local sphere = sphere_ent:AddComponent("rigid_body", {
		Shape = "sphere",
		Radius = 0.5,
	})

	for _ = 1, 180 do
		physics.Update(1 / 120)
	end

	local position = sphere_ent.transform:GetPosition()
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">="](1.95)
	T(position.y)["<="](2.1)
	sphere_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)