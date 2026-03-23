local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_mock_heightmap(fn)
	return {
		GetSize = function()
			return Vec2(2, 2)
		end,
		GetRawPixelColor = function(_, x, y)
			return fn(math.floor(x), math.floor(y))
		end,
	}
end

T.Test("Heightmap shape enumerates triangles and computes bounds", function()
	local tex = create_mock_heightmap(function(x, y)
		if x == 0 and y == 0 then return 255, 255, 255, 255 end

		return 0, 0, 0, 255
	end)
	local shape = HeightmapShape.New{
		Heightmap = tex,
		Size = Vec2(10, 10),
		Resolution = Vec2(2, 2),
		Height = 10,
	}
	local body = test_helpers.CreateTestRigidBody({Shape = shape})
	local collider = body:GetColliders()[1]
	local bounds = collider:GetBroadphaseAABB()
	local triangle_count = 0

	shape:ForEachOverlappingTriangle(
		collider,
		shape:GetLocalBounds(collider),
		function()
			triangle_count = triangle_count + 1
		end,
		{}
	)

	T(body:GetShapeType())["=="]("mesh")
	T(triangle_count)["=="](16)
	T(bounds.min_x)["=="](-5)
	T(bounds.max_x)["=="](5)
	T(bounds.min_z)["=="](-5)
	T(bounds.max_z)["=="](5)
	T(bounds.min_y)["=="](-2.5)
	T(bounds.max_y)[">="](5)
end)

T.Test("Rigid bodies accept heightmap shape definitions", function()
	local tex = create_mock_heightmap(function()
		return 255, 255, 255, 255
	end)
	local body = test_helpers.CreateTestRigidBody{
		Shape = {
			Heightmap = tex,
			Size = Vec2(8, 8),
			Resolution = Vec2(1, 1),
			Height = 4,
		},
	}
	local shape = body:GetPhysicsShape()
	local bounds = body:GetBroadphaseAABB()
	T(shape ~= nil)["=="](true)
	T(body:GetShapeType())["=="]("mesh")
	T(bounds.min_x)["=="](-4)
	T(bounds.max_x)["=="](4)
	T(bounds.min_y)["=="](2)
	T(bounds.max_y)["=="](2)
end)

T.Test("Heightmap shapes can be traced like static meshes", function()
	local tex = create_mock_heightmap(function()
		return 255, 255, 255, 255
	end)
	local shape = HeightmapShape.New{
		Heightmap = tex,
		Size = Vec2(8, 8),
		Resolution = Vec2(1, 1),
		Height = 4,
	}
	local body = test_helpers.CreateTestRigidBody({Shape = shape})
	local collider = body:GetColliders()[1]
	local hit = shape:TraceAgainstBody(collider, Vec3(0, 8, 0), Vec3(0, -1, 0), 16)
	T(hit ~= nil)["=="](true)
	T(math.abs(hit.position.x))["<"](0.0001)
	T(math.abs(hit.position.y - 2))["<"](0.0001)
	T(math.abs(hit.position.z))["<"](0.0001)
	T(hit.normal.y)[">"](0.999)
	T(hit.triangle_index ~= nil)["=="](true)
end)
