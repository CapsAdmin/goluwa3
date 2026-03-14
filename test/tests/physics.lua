local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

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

T.Test3D("Rigid box can rest on static box", function()
	local ground = create_flat_ground("rigid_box_stack_ground")
	local base_ent = Entity.New({Name = "rigid_box_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(2, 1, 2),
		Static = true,
	})
	local top_ent = Entity.New({Name = "rigid_box_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0, 3.5, 0))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(240)
	local position = top_ent.transform:GetPosition()
	T(top:GetGrounded())["=="](true)
	T(position.y)[">="](1.95)
	T(position.y)["<="](2.1)
	T(math.abs(position.x))["<"](0.2)
	top_ent:Remove()
	base_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid resting contact stays stable over time", function()
	local ground = create_flat_ground("rigid_rest_stability_ground")
	local box_ent = Entity.New({Name = "rigid_rest_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	box_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(2, 1, 2),
		Static = true,
	})
	local sphere_ent = Entity.New({Name = "rigid_rest_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0.1, 3, 0.05))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(240)
	local settled = sphere_ent.transform:GetPosition():Copy()
	simulate_physics(480)
	local final_position = sphere_ent.transform:GetPosition()
	local drift = (final_position - settled):GetLength()
	T(sphere:GetGrounded())["=="](true)
	T(final_position.y)[">="](1.94)
	T(final_position.y)["<="](2.1)
	T(drift)["<"](0.15)
	sphere_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid sphere rolls off rotated box instead of resting on its AABB", function()
	local ground = create_flat_ground("rigid_rotated_box_ground", 12)
	local ramp_ent = Entity.New({Name = "rigid_rotated_box"})
	ramp_ent:AddComponent("transform")
	ramp_ent.transform:SetPosition(Vec3(0, 1.5, 0))
	ramp_ent.transform:SetAngles(Deg3(0, 0, -35))
	ramp_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(4, 1, 4),
		Static = true,
	})
	local sphere_ent = Entity.New({Name = "rigid_sphere_rotated_box"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 5, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(180)
	local position = sphere_ent.transform:GetPosition()
	T(math.abs(position.x))[">"](0.5)
	T(position.y)["<"](5.0)
	sphere_ent:Remove()
	ramp_ent:Remove()
	ground:Remove()
end)

T.Test3D("Fast rigid sphere does not tunnel through thin static box", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(6, 0.2, 6),
		Static = true,
	})
	local sphere_ent = Entity.New({Name = "rigid_ccd_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 8, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	sphere:SetVelocity(Vec3(0, -320, 0))
	physics.Update(1 / 10)
	local position = sphere_ent.transform:GetPosition()
	T(position.y)[">="](1.55)
	T(math.abs(position.x))["<"](0.1)
	blocker_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Rigid body collision response supports friction and restitution", function()
	local platform_ent = Entity.New({Name = "rigid_material_platform"})
	platform_ent:AddComponent("transform")
	platform_ent.transform:SetPosition(Vec3(0, 1, 0))
	platform_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(8, 1, 8),
			Static = true,
			Friction = 1,
			Restitution = 0.8,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_material_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Friction = 1,
			Restitution = 0.8,
		}
	)
	sphere:SetVelocity(Vec3(8, -18, 0))
	simulate_physics(24)
	local velocity = sphere:GetVelocity()
	T(velocity.y)[">"](6)
	T(math.abs(velocity.x))["<"](2)
	platform_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Rigid bodies support persistent multi-point contact manifolds", function()
	local left_support = Entity.New({Name = "rigid_manifold_left"})
	left_support:AddComponent("transform")
	left_support.transform:SetPosition(Vec3(-1.6, 1, 0))
	left_support:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(1, 1, 2),
		Static = true,
	})
	local right_support = Entity.New({Name = "rigid_manifold_right"})
	right_support:AddComponent("transform")
	right_support.transform:SetPosition(Vec3(1.6, 1, 0))
	right_support:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(1, 1, 2),
		Static = true,
	})
	local plank_ent = Entity.New({Name = "rigid_manifold_plank"})
	plank_ent:AddComponent("transform")
	plank_ent.transform:SetPosition(Vec3(0, 4, 0))
	local plank = plank_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(4.5, 0.6, 1.5),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	simulate_physics(360)
	local position = plank_ent.transform:GetPosition()
	local angles = plank_ent.transform:GetRotation():GetAngles()
	T(plank:GetGrounded())["=="](true)
	T(position.y)[">="](1.7)
	T(position.y)["<="](2.5)
	T(math.abs(position.x))["<"](0.5)
	T(math.abs(angles.z))["<"](0.35)
	plank_ent:Remove()
	left_support:Remove()
	right_support:Remove()
end)

T.Test3D("Rigid bodies can sleep and wake on contact", function()
	local ground_ent = Entity.New({Name = "rigid_sleep_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(8, 1, 8),
			Static = true,
			Friction = 1,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_sleep_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			LinearDamping = 12,
			AngularDamping = 12,
			Friction = 1,
			SleepDelay = 0.2,
			SleepLinearThreshold = 0.05,
			SleepAngularThreshold = 0.05,
		}
	)
	simulate_physics(240)
	local settled_x = sphere_ent.transform:GetPosition().x
	T(sphere:GetAwake())["=="](false)
	T(sphere:GetVelocity():GetLength())["<"](0.01)
	sphere:SetVelocity(Vec3(4, 0, 0))
	physics.Update(1 / 60)
	local moved_x = sphere_ent.transform:GetPosition().x
	T(sphere:GetAwake())["=="](true)
	T(moved_x)[">"](settled_x + 0.01)
	ground_ent:Remove()
	sphere_ent:Remove()
end)

T.Test3D("Rigid body force and impulse API", function()
	local sphere_ent = Entity.New({Name = "rigid_force_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 0, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			AutomaticMass = false,
			Mass = 2,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	sphere:ApplyImpulse(Vec3(4, 0, 0))
	T(sphere:GetVelocity().x)["=="](2)

	for _ = 1, 30 do
		sphere:ApplyForce(Vec3(0, 12, 0))
		physics.Update(1 / 60)
	end

	local sphere_position = sphere_ent.transform:GetPosition()
	T(sphere:GetVelocity().y)[">"](2.9)
	T(sphere_position.x)[">"](0.9)
	T(sphere_position.y)[">"](0.7)
	local box_ent = Entity.New({Name = "rigid_force_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 0, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(2, 1, 1),
			AutomaticMass = false,
			Mass = 1,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
		}
	)
	box:ApplyAngularImpulse(Vec3(0, 0, 2))

	for _ = 1, 30 do
		box:ApplyForce(Vec3(0, 0, 12), box:GetPosition() + Vec3(1, 0, 0))
		physics.Update(1 / 60)
	end

	local box_angular = box:GetAngularVelocity()
	T(math.abs(box_angular.z))[">"](1.5)
	T(math.abs(box_angular.y))[">"](2.5)
	sphere_ent:Remove()
	box_ent:Remove()
end)

T.Test3D("Rigid bodies support collision layers and collision events", function()
	local function spawn_pair(prefix, config_a, config_b)
		local a = Entity.New({Name = prefix .. "_a"})
		a:AddComponent("transform")
		a.transform:SetPosition(Vec3(-2, 0, 0))
		local body_a = a:AddComponent("rigid_body", config_a)
		local b = Entity.New({Name = prefix .. "_b"})
		b:AddComponent("transform")
		b.transform:SetPosition(Vec3(2, 0, 0))
		local body_b = b:AddComponent("rigid_body", config_b)
		return a, body_a, b, body_b
	end

	local no_hit_a, body_a, no_hit_b, body_b = spawn_pair(
		"rigid_layers_skip",
		{
			Shape = "sphere",
			Radius = 0.5,
			GravityScale = 0,
			Restitution = 1,
			CollisionGroup = 1,
			CollisionMask = 1,
		},
		{
			Shape = "sphere",
			Radius = 0.5,
			GravityScale = 0,
			Restitution = 1,
			CollisionGroup = 2,
			CollisionMask = 2,
		}
	)
	local enter_count = 0

	no_hit_a:AddLocalListener("OnCollisionEnter", function()
		enter_count = enter_count + 1
	end)

	body_a:SetVelocity(Vec3(6, 0, 0))
	body_b:SetVelocity(Vec3(-6, 0, 0))
	simulate_physics(90)
	T(enter_count)["=="](0)
	T(no_hit_a.transform:GetPosition().x)[">"](1.5)
	T(no_hit_b.transform:GetPosition().x)["<"](-1.5)
	no_hit_a:Remove()
	no_hit_b:Remove()
	local hit_b = Entity.New({Name = "rigid_layers_hit_box"})
	hit_b:AddComponent("transform")
	hit_b.transform:SetPosition(Vec3(0, 1, 0))
	local hit_body_b = hit_b:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(4, 1, 4),
			Static = true,
			CollisionGroup = 2,
			CollisionMask = 3,
		}
	)
	local hit_a = Entity.New({Name = "rigid_layers_hit_sphere"})
	hit_a:AddComponent("transform")
	hit_a.transform:SetPosition(Vec3(0, 4, 0))
	local hit_body_a = hit_a:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			CollisionGroup = 1,
			CollisionMask = 3,
		}
	)
	local enter_hits = 0
	local stay_hits = 0
	local exit_hits = 0

	hit_a:AddLocalListener("OnCollisionEnter", function(self, other, info)
		enter_hits = enter_hits + 1
		T(self)["=="](hit_a)
		T(other)["=="](hit_b)
		T(info.other_body)["=="](hit_body_b)
		T(math.abs(info.normal.y))[">"](0.5)
	end)

	hit_a:AddLocalListener("OnCollisionStay", function(self)
		stay_hits = stay_hits + 1
		T(self)["=="](hit_a)
	end)

	hit_a:AddLocalListener("OnCollisionExit", function(self, other)
		exit_hits = exit_hits + 1
		T(self)["=="](hit_a)
		T(other)["=="](hit_b)
	end)

	simulate_physics(240)
	T(enter_hits)[">"](0)
	T(stay_hits)[">"](0)
	hit_body_a:SetCollisionMask(0)
	simulate_physics(2)
	T(exit_hits)[">"](0)
	T(hit_body_a:GetGrounded())["=="](true)
	hit_a:Remove()
	hit_b:Remove()
end)

T.Test3D("Fast rigid boxes do not tunnel through thin static world geometry", function()
	local blocker_ent = Entity.New({Name = "rigid_ccd_box_blocker"})
	blocker_ent:AddComponent("transform")
	blocker_ent.transform:SetPosition(Vec3(0, 1, 0))
	blocker_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(6, 0.2, 6),
		Static = true,
	})
	local box_ent = Entity.New({Name = "rigid_ccd_fast_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 8, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
		}
	)
	box:SetVelocity(Vec3(0, -320, 0))
	physics.Update(1 / 10)
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
			Shape = "sphere",
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
			Shape = "sphere",
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
	physics.Update(1 / 30)
	local left_pos = left_ent.transform:GetPosition()
	local right_pos = right_ent.transform:GetPosition()
	local separation = (right_pos - left_pos):GetLength()
	left_ent:Remove()
	right_ent:Remove()
	T(separation)[">="](0.95)
	T(left_pos.x)["<="](right_pos.x)
end)

T.Test3D("Rigid body depenetration is clamped and tall stacks remain stable", function()
	local ground = create_flat_ground("rigid_tall_stack_ground", 12)
	local base_ent = Entity.New({Name = "rigid_tall_stack_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent:AddComponent("rigid_body", {
		Shape = "box",
		Size = Vec3(3, 1, 3),
		Static = true,
	})
	local boxes = {}
	local stack_count = 20

	for i = 1, stack_count do
		local ent = Entity.New({Name = "rigid_tall_stack_box_" .. i})
		ent:AddComponent("transform")
		ent.transform:SetPosition(Vec3((i % 2 == 0 and 0.03 or -0.03), 1.9 + i * 0.9, 0))
		ent.transform:SetAngles(Deg3(0, 0, i % 2 == 0 and 2 or -2))
		local body = ent:AddComponent(
			"rigid_body",
			{
				Shape = "box",
				Size = Vec3(1, 1, 1),
				LinearDamping = 0,
				AngularDamping = 0,
				Friction = 1,
			}
		)
		boxes[i] = {ent = ent, body = body}
	end

	simulate_physics(960)
	local previous_y = 1.4

	for i, box in ipairs(boxes) do
		local position = box.ent.transform:GetPosition()
		local angles = box.ent.transform:GetRotation():GetAngles()
		T(position.y)[">="](previous_y - 0.05)
		T(position.y)["<"](21.5)
		T(math.abs(position.x))["<"](1.1)
		T(math.abs(position.z))["<"](0.35)
		T(math.abs(angles.z))["<"](0.7)
		T(math.abs(angles.x))["<"](0.25)
		previous_y = position.y
	end

	local top_box = boxes[#boxes]
	T(top_box.body:GetVelocity():GetLength())["<"](3)
	T(top_box.body:GetAngularVelocity():GetLength())["<"](3)
	T(boxes[1].body:GetGrounded())["=="](true)

	for _, box in ipairs(boxes) do
		box.ent:Remove()
	end

	base_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid bodies keep warm-started persistent contact manifolds stable across frames", function()
	local ground = create_flat_ground("rigid_manifold_warm_start_ground", 12)
	local base_ent = Entity.New({Name = "rigid_manifold_warm_start_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent.transform:SetAngles(Deg3(0, 28, 0))
	base_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(5, 1, 5),
			Static = true,
			Friction = 1,
		}
	)
	local top_ent = Entity.New({Name = "rigid_manifold_warm_start_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0.12, 4.1, -0.08))
	top_ent.transform:SetAngles(Deg3(4, -14, 6))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(4, 0.9, 4),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			Restitution = 0,
		}
	)
	simulate_physics(360)
	local settled_position = top_ent.transform:GetPosition():Copy()
	local settled_angles = top_ent.transform:GetRotation():GetAngles()
	simulate_physics(720)
	local final_position = top_ent.transform:GetPosition()
	local final_angles = top_ent.transform:GetRotation():GetAngles()
	local drift = (final_position - settled_position):GetLength()
	local pitch_drift = math.abs(final_angles.x - settled_angles.x)
	local roll_drift = math.abs(final_angles.z - settled_angles.z)
	top_ent:Remove()
	base_ent:Remove()
	ground:Remove()
	T(top:GetGrounded())["=="](true)
	T(final_position.y)[">="](1.8)
	T(final_position.y)["<="](2.35)
	T(math.abs(final_position.x))["<"](0.35)
	T(math.abs(final_position.z))["<"](0.35)
	T(drift)["<"](0.08)
	T(pitch_drift)["<"](0.06)
	T(roll_drift)["<"](0.06)
	T(top:GetAngularVelocity():GetLength())["<"](0.4)
end)

T.Test3D("Rigid rotated boxes generate stable multi-point contact patches", function()
	local ground = create_flat_ground("rigid_rotated_patch_ground", 12)
	local base_ent = Entity.New({Name = "rigid_rotated_patch_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent.transform:SetAngles(Deg3(0, 32, 0))
	base_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(5, 1, 5),
			Static = true,
			Friction = 1,
		}
	)
	local top_ent = Entity.New({Name = "rigid_rotated_patch_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0.1, 4.2, -0.08))
	top_ent.transform:SetAngles(Deg3(5, -18, 7))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(4, 0.8, 4),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			Restitution = 0,
		}
	)
	simulate_physics(480)
	local position = top_ent.transform:GetPosition()
	local angles = top_ent.transform:GetRotation():GetAngles()
	top_ent:Remove()
	base_ent:Remove()
	ground:Remove()
	T(top:GetGrounded())["=="](true)
	T(position.y)[">="](1.75)
	T(position.y)["<="](2.35)
	T(math.abs(position.x))["<"](0.35)
	T(math.abs(position.z))["<"](0.35)
	T(math.abs(angles.x))["<"](0.28)
	T(math.abs(angles.z))["<"](0.28)
	T(top:GetAngularVelocity():GetLength())["<"](1.25)
end)

T.Test3D("Rigid body collisions apply angular impulse from off-center impacts", function()
	local sphere_ent = Entity.New({Name = "rigid_angular_hit_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(-3, 1.45, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = "sphere",
			Radius = 0.5,
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	local box_ent = Entity.New({Name = "rigid_angular_hit_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 1, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = "box",
			Size = Vec3(1.5, 1.5, 1.5),
			GravityScale = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			MaxLinearSpeed = 1000,
			Restitution = 0,
		}
	)
	sphere:SetVelocity(Vec3(40, 0, 0))
	simulate_physics(18, 1 / 120)
	local angular = box:GetAngularVelocity()
	local linear = box:GetVelocity()
	local sphere_position = sphere_ent.transform:GetPosition()
	local box_position = box_ent.transform:GetPosition()
	sphere_ent:Remove()
	box_ent:Remove()
	T(linear.x)[">"](2)
	T(math.abs(angular.z))[">"](1.2)
	T(math.abs(angular.x))["<"](0.75)
	T(math.abs(box_position.y - 1))["<"](0.5)
	T(sphere_position.x)["<"](box_position.x)
end)