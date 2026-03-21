local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Quat = import("goluwa/structs/quat.lua")
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

T.Test("Mesh rigid bodies can be traced and preserve mesh hit metadata", function()
	local poly = create_quad_polygon()
	local primitive = {
		polygon3d = poly,
		material = {name = "trace_test_material"},
	}
	local owner = {
		IsValid = function()
			return true
		end,
		transform = {
			position = Vec3(),
			rotation = Quat():Identity(),
			GetPosition = function(self)
				return self.position
			end,
			GetRotation = function(self)
				return self.rotation
			end,
			SetPosition = function(self, value)
				self.position = value
			end,
			SetRotation = function(self, value)
				self.rotation = value
			end,
		},
		model = {
			Primitives = {primitive},
		},
	}
	local body = test_helpers.CreateTestRigidBody{
		Shape = MeshShape.New{Model = owner.model},
		Owner = owner,
	}
	local hit = physics.RayCast(
		Vec3(0, 2, 0),
		Vec3(0, -1, 0),
		10,
		nil,
		function(entity)
			return entity == owner
		end,
		{IgnoreRigidBodies = false, UseRenderMeshes = false}
	)
	T(hit ~= nil)["=="](true)
	T(hit.rigid_body)["=="](body)
	T(hit.entity)["=="](owner)
	T(hit.model)["=="](owner.model)
	T(hit.primitive)["=="](primitive)
	T(hit.primitive_index)["=="](1)
	T(hit.triangle_index ~= nil)["=="](true)
	T(math.abs(hit.position.x))["<"](0.0001)
	T(math.abs(hit.position.y))["<"](0.0001)
	T(math.abs(hit.position.z))["<"](0.0001)
	T(hit.normal.y)[">"](0.999)
	T(hit.face_normal.y)[">"](0.999)
end)

T.Test("Mesh shapes can resolve brush primitives from models", function()
	local owner = {
		IsValid = function()
			return true
		end,
		transform = {
			position = Vec3(),
			rotation = Quat():Identity(),
			GetPosition = function(self)
				return self.position
			end,
			GetRotation = function(self)
				return self.rotation
			end,
		},
		model = {
			Primitives = {
				{
					brush_planes = {
						{normal = Vec3(1, 0, 0), dist = 1},
						{normal = Vec3(-1, 0, 0), dist = 1},
						{normal = Vec3(0, 1, 0), dist = 1},
						{normal = Vec3(0, -1, 0), dist = 1},
						{normal = Vec3(0, 0, 1), dist = 1},
						{normal = Vec3(0, 0, -1), dist = 1},
					},
				},
			},
		},
	}
	local body = test_helpers.CreateTestRigidBody{
		Shape = MeshShape.New{Model = owner.model},
		Owner = owner,
	}
	local shape = body:GetPhysicsShape()
	local entries = shape:GetMeshPolygonEntries(body:GetColliders()[1])
	T(#entries)["=="](1)
	T(entries[1].primitive)["=="](owner.model.Primitives[1])
	T(entries[1].polygon ~= nil)["=="](true)
	T(shape:GetLocalBounds(body:GetColliders()[1]).min_x)["=="](-1)
	T(shape:GetLocalBounds(body:GetColliders()[1]).max_z)["=="](1)
end)

T.Test("World geometry rigid bodies are traced by default world queries", function()
	local poly = create_quad_polygon()
	local primitive = {polygon3d = poly}
	local owner = {
		IsValid = function()
			return true
		end,
		transform = {
			position = Vec3(),
			rotation = Quat():Identity(),
			GetPosition = function(self)
				return self.position
			end,
			GetRotation = function(self)
				return self.rotation
			end,
		},
		model = {
			Primitives = {primitive},
		},
	}
	local body = test_helpers.CreateTestRigidBody{
		Shape = MeshShape.New{Model = owner.model},
		Owner = owner,
	}
	body.WorldGeometry = true
	local hit = physics.RayCast(
		Vec3(0, 2, 0),
		Vec3(0, -1, 0),
		10,
		nil,
		function(entity)
			return entity == owner
		end,
		{UseRenderMeshes = false}
	)
	T(hit ~= nil)["=="](true)
	T(hit.rigid_body)["=="](body)
	T(hit.primitive)["=="](primitive)
	T(hit.normal.y)[">"](0.999)
end)
