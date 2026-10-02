local T = import("test/environment.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sphere_shape = SphereShape.New
local compound_shape = CompoundShape.New

local function add_triangle(poly, a, b, c)
	poly:AddVertex{pos = a, uv = Vec2(0, 0)}
	poly:AddVertex{pos = b, uv = Vec2(1, 0)}
	poly:AddVertex{pos = c, uv = Vec2(0.5, 1)}
end

local function add_box_triangles(poly, center, size)
	local hx = size.x * 0.5
	local hy = size.y * 0.5
	local hz = size.z * 0.5
	local v = {
		center + Vec3(-hx, -hy, -hz),
		center + Vec3(hx, -hy, -hz),
		center + Vec3(hx, hy, -hz),
		center + Vec3(-hx, hy, -hz),
		center + Vec3(-hx, -hy, hz),
		center + Vec3(hx, -hy, hz),
		center + Vec3(hx, hy, hz),
		center + Vec3(-hx, hy, hz),
	}
	local faces = {
		{1, 2, 3},
		{1, 3, 4},
		{5, 7, 6},
		{5, 8, 7},
		{1, 5, 6},
		{1, 6, 2},
		{4, 3, 7},
		{4, 7, 8},
		{1, 4, 8},
		{1, 8, 5},
		{2, 6, 7},
		{2, 7, 3},
	}

	for _, face in ipairs(faces) do
		add_triangle(poly, v[face[1]], v[face[2]], v[face[3]])
	end
end

local function create_split_box_mesh()
	local poly = Polygon3D.New()
	add_box_triangles(poly, Vec3(-1.2, 0, 0), Vec3(1, 1, 2))
	add_box_triangles(poly, Vec3(1.2, 0, 0), Vec3(1, 1, 2))
	poly:BuildBoundingBox()
	return poly
end

T.TestPhysics("Compound mesh builder splits disconnected triangle islands", function()
	local compound = convex_hull.BuildCompoundShapeFromTriangles(create_split_box_mesh())
	T(compound ~= nil)["=="](true)
	T(type(compound.children))["=="]("table")
	T(#compound.children)["=="](2)
	local x_values = {}

	for i, child in ipairs(compound.children) do
		x_values[i] = child.Position.x
		T(child.ConvexHull ~= nil)["=="](true)
		T(#(child.ConvexHull.vertices or {}))[">="](8)
	end

	table.sort(x_values)
	T(x_values[1])["<"](-0.5)
	T(x_values[2])[">"](0.5)
end)

T.TestPhysics("Static compound collider preserves concave gap from generated child hulls", function()
	local ground = test_helpers.CreateFlatGround("compound_gap_ground", 12)
	local compound_desc = convex_hull.BuildCompoundShapeFromTriangles(create_split_box_mesh())
	local support_ent = Entity.New({Name = "compound_gap_support"})
	support_ent:AddComponent("transform")
	support_ent.transform:SetPosition(Vec3(0, 1.1, 0))
	support_ent:AddComponent(
		"rigid_body",
		{
			Shape = compound_shape(compound_desc),
			MotionType = "static",
		}
	)
	local sphere_ent = Entity.New({Name = "compound_gap_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 4, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(0.45),
			Radius = 0.45,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	test_helpers.Simulate(300)
	local position = sphere_ent.transform:GetPosition()
	T(sphere:GetGrounded())["=="](true)
	T(math.abs(position.x))["<"](0.2)
	T(position.y)["<"](1.1)
	T(position.y)[">="](0.42)
	sphere_ent:Remove()
	support_ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Dynamic compound of convex hulls rests on ground", function()
	local ground = test_helpers.CreateFlatGround("compound_convex_drop_ground", 12)
	local compound_desc = convex_hull.BuildCompoundShapeFromTriangles(create_split_box_mesh())
	local ent = Entity.New({Name = "compound_convex_drop"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 2, 0))
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shapes = compound_desc.children,
			Mass = 5,
			AutomaticMass = false,
			Friction = 0.7,
		}
	)
	test_helpers.Simulate(300)
	local position = ent.transform:GetPosition()
	T(#body:GetColliders())["=="](2)
	T(position.y)[">="](0.4)
	T(position.y)["<"](0.6)
	ent:Remove()
	ground:Remove()
end)

T.TestPhysics("Impulses through a child collider use the body center of mass as lever arm", function()
	local motion = import("goluwa/physics/motion.lua")
	local points = {}

	for _, sx in ipairs{-0.15, 0.15} do
		for _, sy in ipairs{-0.15, 0.15} do
			for _, sz in ipairs{-0.15, 0.15} do
				points[#points + 1] = Vec3(sx, sy, sz)
			end
		end
	end

	local hull = convex_hull.Normalize(points)
	local ent = Entity.New({Name = "compound_lever"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 5, 0))
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shapes = {
				{ConvexHull = hull, Position = Vec3(-1, 0, 0)},
				{ConvexHull = hull, Position = Vec3(1, 0, 0)},
			},
			Mass = 5,
			AutomaticMass = false,
		}
	)
	local collider = body:GetColliders()[2]
	local point = Vec3(1, 0, 0) + body:GetPosition()
	local impulse = Vec3(0, 1, 0)
	local _, angular_body = motion.ApplyImpulseToMotion(body, Vec3(), Vec3(), impulse, point)
	local _, angular_collider = motion.ApplyImpulseToMotion(collider, Vec3(), Vec3(), impulse, point)
	T(angular_body:GetLength())[">"](0)
	T((angular_collider - angular_body):GetLength())["<"](0.00001)
	ent:Remove()
end)

T.TestPhysics("Writes through a child collider reach the body", function()
	local ent = Entity.New({Name = "compound_write"})
	ent:AddComponent("transform")
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shapes = {
				{Shape = sphere_shape(0.2), Position = Vec3(-1, 0, 0)},
				{Shape = sphere_shape(0.2), Position = Vec3(1, 0, 0)},
			},
			Mass = 1,
			AutomaticMass = false,
		}
	)
	local collider = body:GetColliders()[2]
	collider.PositionCorrection = 0.25
	T(body.PositionCorrection)["=="](0.25)
	T(rawget(collider, "PositionCorrection"))["=="](nil)
	ent:Remove()
end)

T.TestPhysics("Four-legged compound settles to rest", function()
	local ground = Entity.New({Name = "compound_legs_ground"})
	ground:AddComponent("transform")
	ground.transform:SetPosition(Vec3(0, -0.5, 0))
	ground:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(30, 1, 30)),
			Size = Vec3(30, 1, 30),
			MotionType = "static",
			Friction = 0.9,
		}
	)

	local function box_hull(sx, sy, sz)
		local points = {}

		for _, x in ipairs{-sx / 2, sx / 2} do
			for _, y in ipairs{-sy / 2, sy / 2} do
				for _, z in ipairs{-sz / 2, sz / 2} do
					points[#points + 1] = Vec3(x, y, z)
				end
			end
		end

		return convex_hull.Normalize(points)
	end

	local children = {{ConvexHull = box_hull(1.4, 0.08, 0.4), Position = Vec3(0, 0.3, 0)}}

	for _, x in ipairs{-0.65, 0.65} do
		for _, z in ipairs{-0.15, 0.15} do
			children[#children + 1] = {ConvexHull = box_hull(0.06, 0.6, 0.06), Position = Vec3(x, 0, z)}
		end
	end

	local ent = Entity.New({Name = "compound_legs"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 0.6, 0))
	ent.transform:SetAngles(Deg3(0, 30, 15))
	local body = ent:AddComponent(
		"rigid_body",
		{Shapes = children, Mass = 20, AutomaticMass = false, Friction = 0.7}
	)
	test_helpers.Simulate(300)
	T(body:GetVelocity():GetLength())["<"](0.01)
	T(body:GetAngularVelocity():GetLength())["<"](0.01)
	T(body:GetRotation():VecMul(Vec3(0, 1, 0)).y)[">"](0.99)
	ent:Remove()
	ground:Remove()
end)
