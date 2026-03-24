local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")

local function build_box_vertices(center, half_extents)
	return {
		Vec3(center.x - half_extents.x, center.y - half_extents.y, center.z - half_extents.z),
		Vec3(center.x + half_extents.x, center.y - half_extents.y, center.z - half_extents.z),
		Vec3(center.x - half_extents.x, center.y + half_extents.y, center.z - half_extents.z),
		Vec3(center.x + half_extents.x, center.y + half_extents.y, center.z - half_extents.z),
		Vec3(center.x - half_extents.x, center.y - half_extents.y, center.z + half_extents.z),
		Vec3(center.x + half_extents.x, center.y - half_extents.y, center.z + half_extents.z),
		Vec3(center.x - half_extents.x, center.y + half_extents.y, center.z + half_extents.z),
		Vec3(center.x + half_extents.x, center.y + half_extents.y, center.z + half_extents.z),
	}
end

T.Test("GJK reports separated boxes as non-intersecting", function()
	local box_a = build_box_vertices(Vec3(-3, 0, 0), Vec3(1, 1, 1))
	local box_b = build_box_vertices(Vec3(3, 0, 0), Vec3(1, 1, 1))
	local result = gjk_epa.Intersect(box_a, box_b)
	T(result ~= nil)["=="](true)
	T(result.intersect)["=="](false)
end)

T.Test("GJK distance returns stable closest points for separated boxes", function()
	local box_a = build_box_vertices(Vec3(-3, 0, 0), Vec3(1, 1, 1))
	local box_b = build_box_vertices(Vec3(3, 0, 0), Vec3(1, 1, 1))
	local result = gjk_epa.Distance(box_a, box_b)
	T(result ~= nil)["=="](true)
	T(result.intersect)["=="](false)
	T(result.distance)[">="](4)
	T(result.distance)["<="](4.001)
	T(result.normal ~= nil)["=="](true)
	T(result.point_a.x)["<="](-1)
	T(result.point_b.x)[">="](1)
	T(math.abs((result.point_b - result.point_a):GetLength() - result.distance))["<"](0.001)
end)

T.Test("EPA returns stable penetration data for overlapping boxes", function()
	local box_a = build_box_vertices(Vec3(0, 0, 0), Vec3(1, 1, 1))
	local box_b = build_box_vertices(Vec3(1.5, 0, 0), Vec3(1, 1, 1))
	local result = gjk_epa.Penetration(box_a, box_b)
	T(result ~= nil)["=="](true)
	T(result.intersect)["=="](true)
	T(result.normal:GetLength())[">"](0.99)
	T(result.depth)[">"](0.2)
	T(result.point_a ~= nil)["=="](true)
	T(result.point_b ~= nil)["=="](true)
	local witness_depth = (result.point_a - result.point_b):Dot(result.normal)
	T(witness_depth)[">"](0.2)
	T(math.abs(witness_depth - result.depth))["<"](0.001)
end)
