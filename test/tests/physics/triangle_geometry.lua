local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")

T.Test("Triangle geometry point-in-triangle accepts interior points on the triangle plane", function()
	local a = Vec3(0, 0, 0)
	local b = Vec3(1, 0, 0)
	local c = Vec3(0, 1, 0)
	local normal = Vec3(0, 0, 1)
	T(triangle_geometry.PointInTriangle(Vec3(0.2, 0.2, 0), a, b, c, normal, 0.00001))["=="](true)
	T(triangle_geometry.PointInTriangle(Vec3(1.1, 0.2, 0), a, b, c, normal, 0.00001))["=="](false)
end)

T.Test("Triangle geometry normal center and edges helpers share triangle basics", function()
	local a = Vec3(0, 0, 0)
	local b = Vec3(3, 0, 0)
	local c = Vec3(0, 3, 0)
	local scratch = {Vec3(9, 9, 9), Vec3(8, 8, 8), Vec3(7, 7, 7), Vec3(6, 6, 6)}
	local normal = triangle_geometry.GetTriangleNormal(a, b, c)
	local center = triangle_geometry.GetTriangleCenter(a, b, c)
	local edges = triangle_geometry.GetTriangleEdges(a, b, c, scratch)
	T(normal.z)["=="](1)
	T(center.x)["=="](1)
	T(center.y)["=="](1)
	T(center.z)["=="](0)
	T(edges == scratch)["=="](true)
	T(edges[1].x)["=="](3)
	T(edges[1].y)["=="](0)
	T(edges[2].x)["=="](-3)
	T(edges[2].y)["=="](3)
	T(edges[3].x)["=="](0)
	T(edges[3].y)["=="](-3)
	T(edges[4] == nil)["=="](true)
end)

T.Test("Triangle geometry segment-triangle closest points detect direct plane intersection", function()
	local segment_point, triangle_point, distance, normal = triangle_geometry.ClosestPointsOnSegmentTriangle(
		Vec3(0.25, 0.25, 1),
		Vec3(0.25, 0.25, -1),
		Vec3(0, 0, 0),
		Vec3(1, 0, 0),
		Vec3(0, 1, 0),
		{
			epsilon = 0.00001,
			fallback_normal = Vec3(0, 0, 1),
		}
	)
	T(distance)["=="](0)
	T(segment_point.x)["=="](0.25)
	T(segment_point.y)["=="](0.25)
	T(segment_point.z)["=="](0)
	T(triangle_point.x)["=="](0.25)
	T(triangle_point.y)["=="](0.25)
	T(triangle_point.z)["=="](0)
	T(normal.z)["=="](1)
end)

T.Test("Triangle geometry segment-triangle closest points fall back for degenerate triangles", function()
	local segment_point, triangle_point, distance, normal = triangle_geometry.ClosestPointsOnSegmentTriangle(
		Vec3(0, 0, 0),
		Vec3(0, 0, 0),
		Vec3(0, 0, 0),
		Vec3(0, 0, 0),
		Vec3(0, 0, 0),
		{
			epsilon = 0.00001,
			fallback_normal = Vec3(0, 1, 0),
		}
	)
	T(segment_point ~= nil)["=="](true)
	T(triangle_point ~= nil)["=="](true)
	T(distance)["=="](0)
	T(normal.y)["=="](1)
end)
