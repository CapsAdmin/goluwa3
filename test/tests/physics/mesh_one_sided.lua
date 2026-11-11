local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local test_helpers = import("test/physics_helpers.lua")

local function create_grid_floor(name, extent, cell, height)
	height = height or function()
		return 0
	end
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	local poly = Polygon3D.New()

	for x = -extent, extent - cell, cell do
		for z = -extent, extent - cell, cell do
			local a = Vec3(x, height(x, z), z)
			local b = Vec3(x, height(x, z + cell), z + cell)
			local c = Vec3(x + cell, height(x + cell, z + cell), z + cell)
			local d = Vec3(x + cell, height(x + cell, z), z)
			test_helpers.AddTriangle(poly, a, b, c)
			test_helpers.AddTriangle(poly, a, c, d)
		end
	end

	poly:BuildBoundingBox()
	local body = test_helpers.AttachWorldGeometryBody(ent, poly)
	body:SetFriction(0.8)
	return ent
end

local function create_hull_body(name, vertices, position, rotation)
	local hull = {vertices = vertices}
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(rotation)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = ConvexShape.New(hull),
			ConvexHull = hull,
			Mass = 10,
			AutomaticMass = false,
			Friction = 0.8,
		}
	)
	return ent, body
end

local function box_vertices(x, y, z)
	local out = {}

	for _, sx in ipairs{-1, 1} do
		for _, sy in ipairs{-1, 1} do
			for _, sz in ipairs{-1, 1} do
				out[#out + 1] = Vec3(sx * x, sy * y, sz * z)
			end
		end
	end

	return out
end

T.TestPhysics("A box sliding across mesh floor seams keeps its height and direction", function()
	local floor = create_grid_floor("one_sided_seam_floor", 8, 0.5)
	local ent, body = create_hull_body(
		"one_sided_slider",
		box_vertices(0.3, 0.1, 0.3),
		Vec3(-5, 0.12, 0.05),
		Quat():Identity()
	)
	test_helpers.SimulateSettled(body, 60)
	body:SetVelocity(Vec3(4, 0, 0))
	local max_rise, max_spin = 0, 0
	local start_y = body:GetPosition().y

	for _ = 1, 120 do
		test_helpers.Simulate(1)
		max_rise = math.max(max_rise, body:GetPosition().y - start_y)
		max_spin = math.max(max_spin, body:GetAngularVelocity():GetLength())
	end

	local drift = math.abs(body:GetPosition().z - 0.05)
	ent:Remove()
	floor:Remove()
	T(max_rise)["<"](0.01)
	T(max_spin)["<"](0.5)
	T(drift)["<"](0.05)
end)
