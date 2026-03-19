local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
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

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

T.Test3D("Rigid bodies rest on static mesh rigid bodies", function()
	local ground_ent = Entity.New({Name = "rigid_mesh_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	local ground_poly = create_quad_mesh(8)
	ground_ent:AddComponent("rigid_body", {
		Shape = MeshShape.New(ground_poly),
		MotionType = "static",
		Friction = 1,
	})
	local box_ent = Entity.New({Name = "rigid_mesh_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0.03, 4.2, -0.02))
	box_ent.transform:SetAngles(Deg3(2, 9, 3))
	local box = box_ent:AddComponent("rigid_body", {
		Shape = BoxShape.New(Vec3(2.4, 0.8, 2.4)),
		Size = Vec3(2.4, 0.8, 2.4),
		LinearDamping = 0,
		AngularDamping = 0,
		Friction = 1,
		Restitution = 0,
	})
	simulate_physics(360)
	local settled_position = box_ent.transform:GetPosition():Copy()
	local settled_angles = box_ent.transform:GetRotation():GetAngles()
	simulate_physics(480)
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
	T(math.abs(final_position.x))["<"](0.25)
	T(math.abs(final_position.z))["<"](0.25)
	T(drift)["<"](0.1)
	T(pitch_drift)["<"](0.08)
	T(roll_drift)["<"](0.08)
	T(box:GetAngularVelocity():GetLength())["<"](0.8)
end)

T.Test3D("Static mesh rigid bodies collide with falling spheres", function()
	local ground_ent = Entity.New({Name = "rigid_mesh_sphere_ground"})
	ground_ent:AddComponent("transform")
	ground_ent.transform:SetPosition(Vec3(0, 1, 0))
	local ground_poly = create_quad_mesh(6)
	ground_ent:AddComponent("rigid_body", {
		Shape = MeshShape.New(ground_poly),
		MotionType = "static",
		Friction = 1,
	})
	local sphere_ent = Entity.New({Name = "rigid_mesh_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 5, 0))
	local sphere = sphere_ent:AddComponent("rigid_body", {
		Radius = 0.75,
		Shape = physics.SphereShape and physics.SphereShape.New and physics.SphereShape.New(0.75) or import("goluwa/physics/shapes/sphere.lua").New(0.75),
		LinearDamping = 0,
		AngularDamping = 0,
		Friction = 0.5,
		Restitution = 0,
	})
	simulate_physics(240)
	local position = sphere_ent.transform:GetPosition()
	sphere_ent:Remove()
	ground_ent:Remove()
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">="](1.70)
	T(position.y)["<="](1.95)
	T(math.abs(position.x))["<"](0.1)
	T(math.abs(position.z))["<"](0.1)
	T(sphere:GetVelocity():GetLength())["<"](0.8)
end)