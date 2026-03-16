local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")

T.Test("Convex manifold support vertex collection reuses the provided array", function()
	local out = {Vec3(9, 9, 9), Vec3(8, 8, 8), Vec3(7, 7, 7)}
	local first = convex_manifold.CollectSupportVertices(
		{
			Vec3(1, 0, 0),
			Vec3(1, 1, 0),
			Vec3(-1, 0, 0),
		},
		Vec3(1, 0, 0),
		true,
		0.001,
		out
	)
	local second = convex_manifold.CollectSupportVertices(
		{
			Vec3(-1, 0, 0),
			Vec3(0, 0, 0),
			Vec3(0.5, 0, 0),
		},
		Vec3(1, 0, 0),
		true,
		0.001,
		out
	)
	T(first == out)["=="](true)
	T(second == out)["=="](true)
	T(#second)["=="](1)
	T(second[1].x)["=="](0.5)
	T(second[2] == nil)["=="](true)
end)

T.Test("Convex manifold support pair contacts reuse scratch tables and clear stale entries", function()
	local scratch = {}
	local first = convex_manifold.BuildSupportPairContacts(
		{Vec3(-1, 0, 0), Vec3(1, 0, 0)},
		{Vec3(-1, 0.1, 0), Vec3(1, 0.1, 0)},
		Vec3(0, 1, 0),
		{
			scratch = scratch,
			max_contacts = 4,
			merge_distance = 0.001,
			support_tolerance = 0.001,
		}
	)
	local second = convex_manifold.BuildSupportPairContacts(
		{Vec3(0, 0, 0), Vec3(0.5, 0, 0)},
		{Vec3(0, 0.05, 0)},
		Vec3(0, 1, 0),
		{
			scratch = scratch,
			max_contacts = 4,
			merge_distance = 0.001,
			support_tolerance = 0.001,
		}
	)
	T(first == second)["=="](true)
	T(first == scratch.contacts)["=="](true)
	T(#second)["=="](1)
	T(second[2] == nil)["=="](true)
	T(scratch.support_a[3] == nil)["=="](true)
	T(scratch.support_b[2] == nil)["=="](true)
end)

T.Test("Convex manifold average support point matches averaged extreme support vertices", function()
	local vertices = {
		Vec3(1, 0, 0),
		Vec3(1, 2, 0),
		Vec3(-1, 1, 0),
	}
	local average_max = convex_manifold.AverageSupportPoint(vertices, Vec3(1, 0, 0), true, 0.001)
	local average_min = convex_manifold.AverageSupportPoint(vertices, Vec3(1, 0, 0), false, 0.001)
	T(average_max.x)["=="](1)
	T(average_max.y)["=="](1)
	T(average_min.x)["=="](-1)
	T(average_min.y)["=="](1)
end)