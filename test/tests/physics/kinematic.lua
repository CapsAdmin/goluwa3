local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local sphere_shape = SphereShape.New

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

T.Test3D("Kinematic controller implies kinematic motion type", function()
	local ent = Entity.New({Name = "kinematic_motion_type"})
	ent:AddComponent("transform")
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
	})
	local controller = ent:AddComponent("kinematic_controller")
	simulate_physics(1)
	T(body:GetMotionType())["=="]("kinematic")
	T(controller:IsControllingKinematicBody())["=="](true)
	ent:Remove()
end)

T.Test3D("Kinematic controller moves body along flat ground", function()
	local ground = create_flat_ground("kinematic_move_ground", 24)
	local ent = Entity.New({Name = "kinematic_move_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	T(settled.y)[">="](0.49)
	T(settled.y)["<="](0.56)
	controller:SetDesiredVelocity(Vec3(6, 0, 0))
	simulate_physics(120)
	local moved = ent.transform:GetPosition()
	T(moved.x)[">"](2.5)
	T(math.abs(moved.z))["<"](0.5)
	T(moved.y)[">="](0.49)
	T(moved.y)["<="](0.58)
	ent:Remove()
	ground:Remove()
end)

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
	local body = body_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	body_ent:AddComponent("kinematic_controller", {
		Acceleration = 0,
		AirAcceleration = 0,
	})

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
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(1),
			Radius = 1,
			MotionType = "static",
		}
	)
	local body_ent = Entity.New({Name = "kinematic_on_rigid"})
	body_ent:AddComponent("transform")
	body_ent.transform:SetPosition(Vec3(0, 4, 0))
	local body = body_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	body_ent:AddComponent("kinematic_controller", {
		Acceleration = 0,
		AirAcceleration = 0,
	})

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