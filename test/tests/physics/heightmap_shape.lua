local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local HeightmapShape = import("goluwa/physics/shapes/heightmap.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

T.TestPhysics("Heightmap shape enumerates triangles and computes bounds", function()
	local shape = HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(3, 3, function(x, z)
			if x == 0 and z == 0 then return 10 end

			return 0
		end),
		SamplesX = 3,
		SamplesZ = 3,
		Size = Vec2(10, 10),
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

	T(shape.IsHeightmap)["=="](true)
	T(body:GetShapeType())["=="]("mesh")
	T(triangle_count)["=="](8)
	T(bounds.min_x)["=="](-5)
	T(bounds.max_x)["=="](5)
	T(bounds.min_z)["=="](-5)
	T(bounds.max_z)["=="](5)
	T(bounds.min_y)["=="](0)
	T(bounds.max_y)["=="](10)
end)

T.TestPhysics("Heightmap shape only visits cells overlapping the query bounds", function()
	local shape = HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(9, 9, function(x, z)
			return x * 0.5
		end),
		SamplesX = 9,
		SamplesZ = 9,
		Size = Vec2(16, 16),
	}
	local body = test_helpers.CreateTestRigidBody({Shape = shape})
	local collider = body:GetColliders()[1]
	local AABB = import("goluwa/structs/aabb.lua")
	local triangle_count = 0

	shape:ForEachOverlappingTriangle(
		collider,
		AABB(-1, -10, -1, 1, 10, 1),
		function()
			triangle_count = triangle_count + 1
		end,
		{}
	)

	T(triangle_count)["=="](8)
end)

T.TestPhysics("Heightmap shape interpolates heights on its triangles", function()
	local shape = HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(2, 2, function(x, z)
			return x * 4 + z * 2
		end),
		SamplesX = 2,
		SamplesZ = 2,
		Size = Vec2(2, 2),
	}
	T(math.abs(shape:GetHeightAtLocal(-1, -1)))["<"](0.0001)
	T(math.abs(shape:GetHeightAtLocal(1, -1) - 4))["<"](0.0001)
	T(math.abs(shape:GetHeightAtLocal(-1, 1) - 2))["<"](0.0001)
	T(math.abs(shape:GetHeightAtLocal(1, 1) - 6))["<"](0.0001)
	T(math.abs(shape:GetHeightAtLocal(0, 0) - 3))["<"](0.0001)
	T(math.abs(shape:GetHeightAtLocal(0.5, -0.5) - 3.5))["<"](0.0001)
end)

T.TestPhysics("Rigid bodies accept heightmap shape definitions", function()
	local body = test_helpers.CreateTestRigidBody{
		Shape = {
			Heightmap = {
				Samples = HeightmapShape.SamplesFromFunction(2, 2, function()
					return 2
				end),
				SamplesX = 2,
				SamplesZ = 2,
				Size = Vec2(8, 8),
			},
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

T.TestPhysics("Heightmap shapes can be traced like static meshes", function()
	local shape = HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(2, 2, function()
			return 2
		end),
		SamplesX = 2,
		SamplesZ = 2,
		Size = Vec2(8, 8),
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

T.TestPhysics("Heightmap traces hit sloped cells at the interpolated height", function()
	local shape = HeightmapShape.New{
		Samples = HeightmapShape.SamplesFromFunction(5, 5, function(x, z)
			return math.sin(x * 0.7) * 2 + z * 0.5
		end),
		SamplesX = 5,
		SamplesZ = 5,
		Size = Vec2(8, 8),
	}
	local body = test_helpers.CreateTestRigidBody({Shape = shape})
	local collider = body:GetColliders()[1]

	for _, probe in ipairs{{-3.2, 1.7}, {0.4, -2.9}, {2.6, 3.1}, {-1.1, -1.1}} do
		local hit = shape:TraceAgainstBody(collider, Vec3(probe[1], 50, probe[2]), Vec3(0, -1, 0), 100)
		T(hit ~= nil)["=="](true)
		T(math.abs(hit.position.y - shape:GetHeightAtLocal(probe[1], probe[2])))["<"](0.001)
	end
end)
