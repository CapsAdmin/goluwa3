local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local box_shape = BoxShape.New
local create_flat_ground = test_helpers.CreateFlatGround

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Rigid sphere can rest on rigid box", function()
	local ground = create_flat_ground("rigid_box_ground")
	local box_ent = Entity.New({Name = "rigid_box"})
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
	local sphere_ent = Entity.New({Name = "rigid_sphere_on_box"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 3, 0))
	local sphere = sphere_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	simulate_physics(180)
	local position = sphere_ent.transform:GetPosition()
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">="](1.95)
	T(position.y)["<="](2.1)
	sphere_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid sphere does not perch unrealistically on box edge", function()
	local ground = create_flat_ground("rigid_edge_ground")
	local box_ent = Entity.New({Name = "rigid_edge_box"})
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
	local sphere_ent = Entity.New({Name = "rigid_edge_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(1.55, 3, 0))
	local sphere = sphere_ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		Radius = 0.5,
	})
	simulate_physics(240)
	local position = sphere_ent.transform:GetPosition()
	T(math.abs(position.x))[">"](1.2)
	T(position.y)["<"](1.8)
	sphere_ent:Remove()
	box_ent:Remove()
	ground:Remove()
end)

T.Test3D("Rigid box can rest on static box", function()
	local ground = create_flat_ground("rigid_box_stack_ground")
	local base_ent = Entity.New({Name = "rigid_box_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			MotionType = "static",
		}
	)
	local top_ent = Entity.New({Name = "rigid_box_top"})
	top_ent:AddComponent("transform")
	top_ent.transform:SetPosition(Vec3(0, 3.5, 0))
	local top = top_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 1)),
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
	box_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(2, 1, 2)),
			Size = Vec3(2, 1, 2),
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_rest_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0.1, 3, 0.05))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
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
	ramp_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4, 1, 4)),
			Size = Vec3(4, 1, 4),
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_sphere_rotated_box"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 5, 0))
	sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.5),
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