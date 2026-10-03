local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function add_triangle(poly, a, b, c)
	poly:AddVertex({pos = a})
	poly:AddVertex({pos = b})
	poly:AddVertex({pos = c})
end

local function create_quad_mesh(size)
	size = size or 6
	local poly = Polygon3D.New()
	add_triangle(poly, Vec3(-size, 0, -size), Vec3(size, 0, -size), Vec3(-size, 0, size))
	add_triangle(poly, Vec3(size, 0, -size), Vec3(size, 0, size), Vec3(-size, 0, size))
	poly:BuildBoundingBox()
	return poly
end

T.TestPhysics("Rigid bodies rest on static mesh rigid bodies", function()
	local ground_ent = Entity.New({Name = "rigid_mesh_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	local ground_poly = create_quad_mesh(8)
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New(ground_poly),
			MotionType = "static",
			Friction = 1,
		}
	)
	local box_ent = Entity.New({Name = "rigid_mesh_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0.03, 4.2, -0.02))
	box_ent.transform:SetAngles(Deg3(2, 9, 3))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(2.4, 0.8, 2.4)),
			Size = Vec3(2.4, 0.8, 2.4),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 1,
			Restitution = 0,
		}
	)
	test_helpers.Simulate(360)
	local settled_position = box_ent.transform:GetPosition():Copy()
	local settled_angles = box_ent.transform:GetRotation():GetAngles()
	test_helpers.Simulate(480)
	local final_position = box_ent.transform:GetPosition()
	local final_angles = box_ent.transform:GetRotation():GetAngles()
	local drift = (final_position - settled_position):GetLength()
	local pitch_drift = math.abs(final_angles.x - settled_angles.x)
	local roll_drift = math.abs(final_angles.z - settled_angles.z)
	box_ent:Remove()
	ground_ent:Remove()
	T(box:GetGrounded())["=="](true)
	T(final_position.y)[">="](1.35)
	T(final_position.y)["<="](2.1)
	T(math.abs(final_position.x))["<"](0.3)
	T(math.abs(final_position.z))["<"](0.25)
	T(drift)["<"](0.1)
	T(pitch_drift)["<"](0.08)
	T(roll_drift)["<"](0.08)
	T(box:GetAngularVelocity():GetLength())["<"](0.8)
end)

T.TestPhysics("Static mesh rigid bodies collide with falling spheres", function()
	local ground_ent = Entity.New({Name = "rigid_mesh_sphere_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	local ground_poly = create_quad_mesh(6)
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New(ground_poly),
			MotionType = "static",
			Friction = 1,
		}
	)
	local sphere_ent = Entity.New({Name = "rigid_mesh_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 5, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Radius = 0.75,
			Shape = import("goluwa/physics/shapes/sphere.lua").New(0.75),
			LinearDamping = 0,
			AngularDamping = 0,
			Friction = 0.5,
			Restitution = 0,
		}
	)
	test_helpers.Simulate(240)
	local position = sphere_ent.transform:GetPosition()
	sphere_ent:Remove()
	ground_ent:Remove()
	--T(sphere:GetGrounded())["=="](true) TODO
	T(position.y)[">="](1.70)
	T(position.y)["<="](1.95)
	T(math.abs(position.x))["<"](0.1)
	T(math.abs(position.z))["<"](0.1)
	T(sphere:GetVelocity():GetLength())["<"](0.8)
end)

T.TestPhysics("Capsule driven into a static mesh wall stays in front of it", function()
	local poly = Polygon3D.New()
	add_triangle(poly, Vec3(-8, 0, -8), Vec3(8, 0, -8), Vec3(-8, 0, 8))
	add_triangle(poly, Vec3(8, 0, -8), Vec3(8, 0, 8), Vec3(-8, 0, 8))
	add_triangle(poly, Vec3(3, 0, -8), Vec3(3, 0, 8), Vec3(3, 4, -8))
	add_triangle(poly, Vec3(3, 4, -8), Vec3(3, 0, 8), Vec3(3, 4, 8))
	poly:BuildBoundingBox()
	local world_ent = Entity.New({Name = "capsule_wall_world"})
	world_ent:AddComponent("transform")
	world_ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New(poly),
			MotionType = "static",
			WorldGeometry = true,
			Friction = 0.5,
		}
	)
	local capsule_ent = Entity.New({Name = "capsule_wall_player"})
	capsule_ent:AddComponent("transform")
	capsule_ent.transform:SetPosition(Vec3(0, 0.9, 0))
	local capsule = capsule_ent:AddComponent(
		"rigid_body",
		{
			Shape = import("goluwa/physics/shapes/capsule.lua").New(0.3, 1.2),
			Radius = 0.3,
			Height = 1.2,
			Mass = 80,
			AutomaticMass = false,
			CanSleep = false,
			CCD = true,
			Friction = 0.5,
			Restitution = 0,
		}
	)
	local max_x = -math.huge
	local grounded_flips = 0
	local was_grounded = nil

	for step = 1, 300 do
		local velocity = capsule:GetVelocity()
		capsule:SetVelocity(Vec3(3.8, velocity.y, velocity.z))
		capsule:SetAngularVelocity(Vec3())
		test_helpers.Simulate(1)
		max_x = math.max(max_x, capsule_ent.transform:GetPosition().x)

		if step > 60 then
			if was_grounded ~= nil and capsule:GetGrounded() ~= was_grounded then
				grounded_flips = grounded_flips + 1
			end

			was_grounded = capsule:GetGrounded()
		end
	end

	capsule_ent:Remove()
	world_ent:Remove()
	T(max_x)["<"](3 - 0.3 + 0.05)
	T(grounded_flips)["<"](10)
end)

T.TestPhysics("Boxes dropped onto world geometry land without stalling above it and settle flat", function()
	local ground_ent = Entity.New({Name = "box_landing_ground"})
	ground_ent:AddComponent("transform")
	ground_ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New(create_quad_mesh(30)),
			MotionType = "static",
			WorldGeometry = true,
			Friction = 0.7,
		}
	)
	local rotations = {
		Deg3(0, 0, 0),
		Deg3(8, 0, 5),
		Deg3(30, 40, 10),
		Deg3(60, 10, 75),
		Deg3(120, 200, 33),
		Deg3(45, 45, 45),
	}
	local boxes = {}

	for i, rotation in ipairs(rotations) do
		local ent = Entity.New({Name = "box_landing_box"})
		ent:AddComponent("transform")
		ent.transform:SetPosition(Vec3(i * 3 - 10, 3, 0))
		ent.transform:SetAngles(rotation)
		boxes[i] = {
			ent = ent,
			body = ent:AddComponent(
				"rigid_body",
				{
					Shape = BoxShape.New(Vec3(1, 1, 1)),
					Size = Vec3(1, 1, 1),
					Mass = 1,
					AutomaticMass = false,
					Friction = 0.7,
				}
			),
			slowest_fall = 0,
		}
	end

	for _ = 1, 40 do
		test_helpers.Simulate(1, 1 / 60)

		for _, item in ipairs(boxes) do
			local body = item.body
			local height = body:GetPosition().y

			if height > 1.4 and height < 2.5 and body:GetVelocity().y > -3 then
				item.slowest_fall = item.slowest_fall + 1
			end
		end
	end

	test_helpers.Simulate(240, 1 / 60)
	local results = {}

	for i, item in ipairs(boxes) do
		local body = item.body
		local alignment = 0

		for _, axis in ipairs{body:GetRight(), body:GetUp(), body:GetForward()} do
			alignment = math.max(alignment, math.abs(axis.y))
		end

		results[i] = {
			tilt = math.deg(math.acos(math.min(1, alignment))),
			asleep = not body:GetAwake(),
			stalled = item.slowest_fall,
		}
		item.ent:Remove()
	end

	ground_ent:Remove()

	for _, result in ipairs(results) do
		T(result.stalled)["=="](0)
		T(result.tilt)["<"](2)
		T(result.asleep)["=="](true)
	end
end)
