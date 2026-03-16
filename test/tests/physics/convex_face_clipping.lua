local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")

local function create_identity_body()
	return {
		WorldToLocal = function(_, point)
			return point
		end,
	}
end

T.Test("Convex face clipping reuses scratch polygon buffers for box-style face clipping", function()
	local body = create_identity_body()
	local scratch = {}
	local reference_face = {
		tangent_u_index = 1,
		tangent_v_index = 2,
		tangent_u_extent = 1,
		tangent_v_extent = 1,
	}
	local first = convex_face_clipping.ClipFacePolygonToReference(
		body,
		reference_face,
		{
			Vec3(-2, -0.5, 0),
			Vec3(0.5, -0.5, 0),
			Vec3(0.5, 0.5, 0),
			Vec3(-2, 0.5, 0),
		},
		scratch
	)
	local second = convex_face_clipping.ClipFacePolygonToReference(
		body,
		reference_face,
		{
			Vec3(-0.25, -0.25, 0),
			Vec3(0.25, -0.25, 0),
			Vec3(0.25, 0.25, 0),
			Vec3(-0.25, 0.25, 0),
		},
		scratch
	)
	T(first == second)["=="](true)
	T(#second)["=="](4)
	T(second[1].x)["=="](-0.25)
	T(second[3].y)["=="](0.25)
end)

T.Test("Convex face contact entry building reuses scratch tables and clears stale entries", function()
	local scratch = {}
	local reference_points = {
		Vec3(-1, -1, 0),
		Vec3(1, -1, 0),
		Vec3(1, 1, 0),
		Vec3(-1, 1, 0),
	}
	local reference_face = convex_face_clipping.BuildReferenceFace(reference_points, Vec3(0, 0, 1), nil, nil, scratch)
	local projected_points = reference_face.projected_points
	local entries_first = convex_face_clipping.BuildFaceContactEntries(
		reference_face,
		{
			Vec3(-0.8, -0.8, 0.02),
			Vec3(0.8, -0.8, 0.02),
			Vec3(0.8, 0.8, 0.02),
			Vec3(-0.8, 0.8, 0.02),
		},
		0.08,
		scratch
	)
	local reference_face_second = convex_face_clipping.BuildReferenceFace(reference_points, Vec3(0, 0, 1), nil, nil, scratch)
	local entries_second = convex_face_clipping.BuildFaceContactEntries(
		reference_face_second,
		{
			Vec3(-0.5, -0.5, 0.03),
			Vec3(0.5, -0.5, 0.03),
			Vec3(0.0, 0.5, 0.03),
		},
		0.08,
		scratch
	)
	T(reference_face == reference_face_second)["=="](true)
	T(projected_points == reference_face_second.projected_points)["=="](true)
	T(entries_first == entries_second)["=="](true)
	T(#entries_second)["=="](3)
	T(entries_second[4] == nil)["=="](true)
	T(entries_second[1].separation)["=="](0.03)
end)

T.Test("Convex face contact selection reuses scratch tables and clears chosen state", function()
	local scratch = {}
	local reference_face = {
		tangent_u_index = 1,
		tangent_v_index = 2,
	}
	local entries_first = {
		{separation = 0.05, local_point = Vec3(-1, 0, 0)},
		{separation = 0.04, local_point = Vec3(1, 0, 0)},
		{separation = 0.03, local_point = Vec3(0, -1, 0)},
		{separation = 0.02, local_point = Vec3(0, 1, 0)},
		{separation = 0.01, local_point = Vec3(0.1, 0.1, 0)},
	}
	local selected_first = convex_face_clipping.SelectFaceContactEntries(entries_first, reference_face, 4, scratch)
	local entries_second = {
		{separation = 0.06, local_point = Vec3(-0.5, 0, 0)},
		{separation = 0.05, local_point = Vec3(0.5, 0, 0)},
		{separation = 0.04, local_point = Vec3(0, -0.5, 0)},
		{separation = 0.03, local_point = Vec3(0, 0.5, 0)},
		{separation = 0.02, local_point = Vec3(0.2, 0.2, 0)},
	}
	local selected_second = convex_face_clipping.SelectFaceContactEntries(entries_second, reference_face, 4, scratch)
	T(selected_first == selected_second)["=="](true)
	T(#selected_second)["=="](4)
	T(
		selected_second[1] == entries_second[1] or
			selected_second[1] == entries_second[2] or
			selected_second[1] == entries_second[3] or
			selected_second[1] == entries_second[4] or
			selected_second[1] == entries_second[5]
	)["=="](true)
	T(scratch.chosen[entries_first[1]] == nil)["=="](true)
	T(scratch.chosen[entries_second[5]] == nil)["=="](true)
end)