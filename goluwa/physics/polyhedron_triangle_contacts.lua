local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron_cache.lua")
local polyhedron_face_contacts = import("goluwa/physics/polyhedron_face_contacts.lua")
local polyhedron_sat = import("goluwa/physics/polyhedron_sat.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local polyhedron_triangle_contacts = {}
local DEFAULT_EPSILON = 0.00001
local DEFAULT_TRIANGLE_SLOP = 0.05
local DEFAULT_MANIFOLD_MERGE_DISTANCE = 0.08
local DEFAULT_FACE_AXIS_RELATIVE_TOLERANCE = 1.05
local DEFAULT_FACE_AXIS_ABSOLUTE_TOLERANCE = 0.03
local FACE_CONTACT_SCRATCH = {
	contacts = {},
}
local SINGLE_CONTACT_SCRATCH = {
	{},
}
local SUPPORT_CONTACT_SCRATCH = {}
local TRIANGLE_VERTICES_SCRATCH = {}
local TRIANGLE_EDGE_SCRATCH = {}
local POLYHEDRON_FACE_CANDIDATE_CONTEXT = {
	reference = "polyhedron",
	kind = "face",
	margin_overlap = 0,
	support_axis_y = 0,
}
local POLYHEDRON_EDGE_CANDIDATE_CONTEXT = {
	kind = "edge",
	margin_overlap = 0,
	support_axis_y = 0,
}

local function fill_triangle_vertices(out, v0, v1, v2)
	out = out or {}
	out[1] = v0
	out[2] = v1
	out[3] = v2

	for i = 4, #out do
		out[i] = nil
	end

	return out
end

local function build_polyhedron_face_candidate(context, face_index)
	return {
		kind = context.kind,
		reference = context.reference,
		face_index = face_index,
	}
end

local function get_grounded_margin_overlap(context, axis)
	return math.abs(axis.y) >= context.support_axis_y and context.margin_overlap or 0
end

local function build_triangle_edge_candidate(context)
	return {
		kind = context.kind,
	}
end

function polyhedron_triangle_contacts.FindContact(collider, polyhedron, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP
	local manifold_merge_distance = options.manifold_merge_distance or DEFAULT_MANIFOLD_MERGE_DISTANCE
	local face_axis_relative_tolerance = options.face_axis_relative_tolerance or DEFAULT_FACE_AXIS_RELATIVE_TOLERANCE
	local face_axis_absolute_tolerance = options.face_axis_absolute_tolerance or DEFAULT_FACE_AXIS_ABSOLUTE_TOLERANCE
	local poly_vertices = polyhedron_cache.GetPolyhedronWorldVertices(collider, polyhedron)

	if not poly_vertices[1] then return nil end

	local triangle_vertices = fill_triangle_vertices(TRIANGLE_VERTICES_SCRATCH, v0, v1, v2)
	local best = convex_sat.CreateBestAxisTracker()
	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)
	local center_delta = collider:GetPosition() - triangle_center
	local margin_overlap = (collider:GetCollisionMargin() or 0) + triangle_slop
	local support_axis_y = math.max(collider:GetMinGroundNormalY() or 0, 0.5)
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.margin_overlap = margin_overlap
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.support_axis_y = support_axis_y

	if
		not polyhedron_sat.TryUpdatePolyhedronFaceAxisCandidates(
			best,
			poly_vertices,
			triangle_vertices,
			polyhedron,
			collider:GetRotation(),
			center_delta,
			{
				epsilon = epsilon,
				normalize = true,
				build_candidate = build_polyhedron_face_candidate,
				build_candidate_context = POLYHEDRON_FACE_CANDIDATE_CONTEXT,
				get_margin_overlap = get_grounded_margin_overlap,
				get_margin_overlap_context = POLYHEDRON_FACE_CANDIDATE_CONTEXT,
			}
		)
	then
		return nil
	end

	local triangle_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if not triangle_normal then return nil end

	if
		not polyhedron_sat.TryUpdateAxisCandidate(
			best,
			poly_vertices,
			triangle_vertices,
			triangle_normal,
			center_delta,
			{
				kind = "face",
				reference = "triangle",
			},
			{
				epsilon = epsilon,
				margin_overlap = math.abs(triangle_normal.y) >= support_axis_y and margin_overlap or 0,
			}
		)
	then
		return nil
	end

	local triangle_edges = triangle_geometry.GetTriangleEdges(v0, v1, v2, TRIANGLE_EDGE_SCRATCH)
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.margin_overlap = margin_overlap
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.support_axis_y = support_axis_y

	if
		not polyhedron_sat.TryUpdatePolyhedronTriangleEdgeAxisCandidates(
			best,
			poly_vertices,
			triangle_vertices,
			polyhedron,
			collider:GetRotation(),
			triangle_edges,
			center_delta,
			{
				epsilon = epsilon,
				build_candidate = build_triangle_edge_candidate,
				build_candidate_context = POLYHEDRON_EDGE_CANDIDATE_CONTEXT,
				get_margin_overlap = get_grounded_margin_overlap,
				get_margin_overlap_context = POLYHEDRON_EDGE_CANDIDATE_CONTEXT,
			}
		)
	then
		return nil
	end
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.margin_overlap = 0
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.support_axis_y = 0
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.margin_overlap = 0
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.support_axis_y = 0

	local chosen = convex_sat.ChoosePreferredAxis(best, face_axis_relative_tolerance, face_axis_absolute_tolerance)
	local normal = chosen and chosen.normal or nil
	local overlap = chosen and chosen.overlap or nil

	if not (normal and overlap and overlap > epsilon) then return nil end

	local contacts = chosen and
		chosen.kind == "face" and
		polyhedron_face_contacts.BuildPolyhedronTriangleFaceContacts(
			collider,
			polyhedron,
			triangle_vertices,
			chosen,
			normal,
			{
				triangle_slop = triangle_slop,
				max_contacts = 4,
				scratch = FACE_CONTACT_SCRATCH,
				out = FACE_CONTACT_SCRATCH.contacts,
			}
		) or
		nil

	if not contacts or #contacts < 3 then
		contacts = convex_manifold.BuildAndMergeSupportPairContacts(
			contacts,
			poly_vertices,
			triangle_vertices,
			normal * -1,
			{
				merge_distance = manifold_merge_distance,
				max_contacts = 4,
				scratch = SUPPORT_CONTACT_SCRATCH,
			}
		)
	end

	if contacts and contacts[1] then
		return {
			contacts = contacts,
			normal = normal,
			overlap = overlap,
		}
	end

	local point_a = convex_manifold.AverageSupportPoint(poly_vertices, normal, true)
	local separation = triangle_contact_queries.GetPointTriangleSeparation(
		point_a or collider:GetPosition(),
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = normal,
		}
	)
	local point_b = separation and separation.position or nil

	if not (point_a and point_b) then return nil end

	return {
		normal = normal,
		overlap = overlap,
		contacts = convex_manifold.BuildSingleContact(SINGLE_CONTACT_SCRATCH, point_a, point_b),
	}
end

return polyhedron_triangle_contacts
