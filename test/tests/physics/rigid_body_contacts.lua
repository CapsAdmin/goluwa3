local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local box_shape = BoxShape.New
local create_flat_ground = test_helpers.CreateFlatGround
local add_triangle = test_helpers.AddTriangle

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Rigid bodies support persistent multi-point contact manifolds", function()
	local left_support = Entity.New({Name = "rigid_manifold_left"})
	left_support:AddComponent("transform")
	left_support.transform:SetPosition(Vec3(-1.6, 1, 0))
	left_support:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 2)),
			Size = Vec3(1, 1, 2),
			MotionType = "static",
		}
	)
	local right_support = Entity.New({Name = "rigid_manifold_right"})
	right_support:AddComponent("transform")
	right_support.transform:SetPosition(Vec3(1.6, 1, 0))
	right_support:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(1, 1, 2)),
			Size = Vec3(1, 1, 2),
			MotionType = "static",
		}
	)
	local plank_ent = Entity.New({Name = "rigid_manifold_plank"})
	plank_ent:AddComponent("transform")
	plank_ent.transform:SetPosition(Vec3(0, 4, 0))
	local plank = plank_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4.5, 0.6, 1.5)),
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

T.Test3D("Rigid body depenetration is clamped and tall stacks remain stable", function()
	local ground = create_flat_ground("rigid_tall_stack_ground", 12)
	local base_ent = Entity.New({Name = "rigid_tall_stack_base"})
	base_ent:AddComponent("transform")
	base_ent.transform:SetPosition(Vec3(0, 1, 0))
	base_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(3, 1, 3)),
			Size = Vec3(3, 1, 3),
			MotionType = "static",
		}
	)
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
				Shape = box_shape(Vec3(1, 1, 1)),
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
			Shape = box_shape(Vec3(5, 1, 5)),
			Size = Vec3(5, 1, 5),
			MotionType = "static",
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
			Shape = box_shape(Vec3(4, 0.9, 4)),
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
			Shape = box_shape(Vec3(5, 1, 5)),
			Size = Vec3(5, 1, 5),
			MotionType = "static",
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
			Shape = box_shape(Vec3(4, 0.8, 4)),
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

T.Test3D("Rigid bodies generate stable multi-point contacts against static triangle world geometry", function()
	local ground = Entity.New({Name = "rigid_world_patch_ground"})
	ground:AddComponent("transform")
	ground:AddComponent("model")

	local function add_world_triangle(a, b, c)
		local tri = Polygon3D.New()
		add_triangle(tri, a, b, c)
		tri:BuildBoundingBox()
		tri:Upload()
		ground.model:AddPrimitive(tri)
	end

	add_world_triangle(Vec3(-2.1, 1, -1), Vec3(-1.1, 1, -1), Vec3(-2.1, 1, 1))
	add_world_triangle(Vec3(-1.1, 1, -1), Vec3(-1.1, 1, 1), Vec3(-2.1, 1, 1))
	add_world_triangle(Vec3(1.1, 1, -1), Vec3(2.1, 1, -1), Vec3(1.1, 1, 1))
	add_world_triangle(Vec3(2.1, 1, -1), Vec3(2.1, 1, 1), Vec3(1.1, 1, 1))
	ground.model:BuildAABB()
	local plank_ent = Entity.New({Name = "rigid_world_patch_plank"})
	plank_ent:AddComponent("transform")
	plank_ent.transform:SetPosition(Vec3(0, 4, 0))
	plank_ent.transform:SetAngles(Deg3(0, 0, 3))
	local plank = plank_ent:AddComponent(
		"rigid_body",
		{
			Shape = box_shape(Vec3(4.5, 0.6, 1.5)),
			Size = Vec3(4.5, 0.6, 1.5),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			Restitution = 0,
		}
	)
	simulate_physics(360)
	local settled_position = plank_ent.transform:GetPosition():Copy()
	local settled_angles = plank_ent.transform:GetRotation():GetAngles()
	simulate_physics(720)
	local final_position = plank_ent.transform:GetPosition()
	local final_angles = plank_ent.transform:GetRotation():GetAngles()
	local drift = (final_position - settled_position):GetLength()
	local pitch_drift = math.abs(final_angles.x - settled_angles.x)
	local roll_drift = math.abs(final_angles.z - settled_angles.z)
	ground:Remove()
	plank_ent:Remove()
	T(plank:GetGrounded())["=="](true)
	T(final_position.y)[">="](1.18)
	T(final_position.y)["<="](1.5)
	T(math.abs(final_position.x))["<"](0.5)
	T(math.abs(final_angles.z))["<"](0.35)
	T(drift)["<"](0.08)
	T(pitch_drift)["<"](0.08)
	T(roll_drift)["<"](0.08)
	T(plank:GetAngularVelocity():GetLength())["<"](0.6)
end)