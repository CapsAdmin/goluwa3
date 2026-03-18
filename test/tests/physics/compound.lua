local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local sphere_shape = SphereShape.New
local compound_shape = CompoundShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

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

local function create_split_box_mesh()
	local poly = Polygon3D.New()
	add_box_triangles(poly, Vec3(-1.2, 0, 0), Vec3(1, 1, 2))
	add_box_triangles(poly, Vec3(1.2, 0, 0), Vec3(1, 1, 2))
	poly:BuildBoundingBox()
	return poly
end

T.Test3D("Compound mesh builder splits disconnected triangle islands", function()
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

T.Test3D("Static compound collider preserves concave gap from generated child hulls", function()
	local ground = create_flat_ground("compound_gap_ground", 12)
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
	simulate_physics(300)
	local position = sphere_ent.transform:GetPosition()
	T(sphere:GetGrounded())["=="](true)
	T(math.abs(position.x))["<"](0.2)
	T(position.y)["<"](1.1)
	T(position.y)[">="](0.42)
	sphere_ent:Remove()
	support_ent:Remove()
	ground:Remove()
end)
