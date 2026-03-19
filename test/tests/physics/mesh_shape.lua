local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function add_triangle(poly, a, b, c)
	poly:AddVertex({pos = a})
	poly:AddVertex({pos = b})
	poly:AddVertex({pos = c})
end

local function create_quad_polygon()
	local poly = Polygon3D.New()
	add_triangle(poly, Vec3(-2, 0, -1), Vec3(2, 0, -1), Vec3(-2, 0, 1))
	add_triangle(poly, Vec3(2, 0, -1), Vec3(2, 0, 1), Vec3(-2, 0, 1))
	poly:BuildBoundingBox()
	return poly
end

T.Test("Mesh shape builds shared triangle acceleration from polygon data", function()
	local poly = create_quad_polygon()
	local shape = MeshShape.New(poly)
	local body = test_helpers.CreateTestRigidBody({Shape = shape})
	local collider = body:GetColliders()[1]
	local polygons = shape:GetMeshPolygons(collider)
	local bounds = collider:GetBroadphaseAABB()
	local triangles, triangle_count = triangle_mesh.GetPolygonTriangles(poly)
	local collision_points = collider:GetCollisionLocalPoints()
	local support_points = collider:GetSupportLocalPoints()
	T(shape:GetTypeName())["=="]("mesh")
	T(#polygons)["=="](1)
	T(triangle_count)["=="](2)
	T(triangles[1] ~= nil)["=="](true)
	T(#collision_points)[">="](6)
	T(#support_points)[">="](4)
	T(bounds.min_x)["=="](-2)
	T(bounds.max_x)["=="](2)
	T(bounds.min_y)["=="](0)
	T(bounds.max_y)["=="](0)
	T(bounds.min_z)["=="](-1)
	T(bounds.max_z)["=="](1)
end)

T.Test("Rigid bodies accept triangle mesh shape definitions", function()
	local poly = create_quad_polygon()
	local body = test_helpers.CreateTestRigidBody{
		Shape = {
			TriangleMesh = poly,
		},
	}
	local shape = body:GetPhysicsShape()
	T(body:GetShapeType())["=="]("mesh")
	T(shape ~= nil)["=="](true)
	T(shape:GetTypeName())["=="]("mesh")
	T(#shape:GetMeshPolygons(body:GetColliders()[1]))["=="](1)
	T(body:GetBroadphaseAABB().min_x)["=="](-2)
	T(body:GetBroadphaseAABB().max_z)["=="](1)
end)

T.Test("Mesh shape can resolve polygon primitives from owner models", function()
	local poly = create_quad_polygon()
	local body = test_helpers.CreateTestRigidBody{
		Shape = MeshShape.New(),
		Owner = {
			IsValid = function()
				return true
			end,
			transform = {
				position = Vec3(),
				rotation = nil,
				GetPosition = function(self)
					return self.position
				end,
				GetRotation = function(self)
					return self.rotation
				end,
			},
			model = {
				Primitives = {
					{polygon3d = poly},
				},
			},
		},
	}
	local shape = body:GetPhysicsShape()
	local polygons = shape:GetMeshPolygons(body:GetColliders()[1])
	T(body:GetShapeType())["=="]("mesh")
	T(#polygons)["=="](1)
	T(polygons[1])["=="](poly)
	T(shape:GetHalfExtents(body:GetColliders()[1]).x)["=="](2)
	T(shape:GetHalfExtents(body:GetColliders()[1]).z)["=="](1)
end)
