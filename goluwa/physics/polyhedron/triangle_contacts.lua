local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local polyhedron_face_contacts = import("goluwa/physics/polyhedron/face_contacts.lua")
local polyhedron_sat = import("goluwa/physics/polyhedron/sat.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local polyhedron_triangle_contacts = {}
local DEFAULT_EPSILON = 0.00001
local DEFAULT_TRIANGLE_SLOP = 0.05
local DEFAULT_MANIFOLD_MERGE_DISTANCE = 0.08
local DEFAULT_FACE_AXIS_RELATIVE_TOLERANCE = 1.05
local DEFAULT_FACE_AXIS_ABSOLUTE_TOLERANCE = 0.03
local FACE_CONTACT_ALIGNMENT_THRESHOLD = 0.5
local FACE_CONTACT_SCRATCH = {
	contacts = {},
}
local SINGLE_CONTACT_SCRATCH = {
	{},
}
local SUPPORT_CONTACT_SCRATCH = {}
local TRIANGLE_VERTICES_SCRATCH = {}
local TRIANGLE_EDGE_SCRATCH = {}
local TRIANGLE_PRISM_VERTICES_SCRATCH = {}
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

local function fill_triangle_prism_vertices(out, v0, v1, v2, normal, half_thickness)
	out = out or {}
	local offset = normal * half_thickness
	out[1] = v0 + offset
	out[2] = v1 + offset
	out[3] = v2 + offset
	out[4] = v0 - offset
	out[5] = v1 - offset
	out[6] = v2 - offset

	for i = 7, #out do
		out[i] = nil
	end

	return out
end

local function orient_triangle_normal(triangle_normal, center_delta)
	if not triangle_normal then return nil end

	return center_delta:Dot(triangle_normal) >= 0 and
		triangle_normal or
		triangle_normal * -1
end

local function find_best_face_index_for_normal(polyhedron, rotation, normal)
	local best_index = nil
	local best_alignment = -math.huge

	for face_index, face in ipairs(polyhedron.faces or {}) do
		local world_normal = rotation:VecMul(face.normal):GetNormalized()
		local alignment = world_normal:Dot(normal)

		if alignment > best_alignment then
			best_alignment = alignment
			best_index = face_index
		end
	end

	return best_index, best_alignment
end

local function build_face_candidate(collider, polyhedron, triangle_normal, normal)
	local face_index, face_alignment = find_best_face_index_for_normal(polyhedron, collider:GetRotation(), normal)
	local triangle_alignment = triangle_normal and triangle_normal:Dot(normal) or -math.huge

	if
		face_index and
		face_alignment >= FACE_CONTACT_ALIGNMENT_THRESHOLD and
		face_alignment >= triangle_alignment
	then
		return {
			kind = "face",
			reference = "polyhedron",
			face_index = face_index,
		}
	end

	if triangle_alignment >= FACE_CONTACT_ALIGNMENT_THRESHOLD then
		return {
			kind = "face",
			reference = "triangle",
			face_index = 1,
		}
	end

	return nil
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

local function should_try_sat_fallback(collider, v0, v1, v2, options)
	local center = collider.GetPosition and collider:GetPosition() or nil

	if not center then return true end

	local center_separation = triangle_contact_queries.GetPointTriangleSeparation(center, v0, v1, v2, {
		epsilon = options.epsilon or DEFAULT_EPSILON,
	})

	if not center_separation then return true end

	local half_extents = collider.GetHalfExtents and collider:GetHalfExtents() or nil
	local radius = half_extents and half_extents:GetLength() or 1
	local margin = (collider.GetCollisionMargin and collider:GetCollisionMargin() or 0) + (options.triangle_slop or DEFAULT_TRIANGLE_SLOP)
	return center_separation.distance <= radius + margin + 0.1
end

local function find_contact_sat_fallback(collider, polyhedron, v0, v1, v2, options, poly_vertices)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP
	local manifold_merge_distance = options.manifold_merge_distance or DEFAULT_MANIFOLD_MERGE_DISTANCE
	local face_axis_relative_tolerance = options.face_axis_relative_tolerance or DEFAULT_FACE_AXIS_RELATIVE_TOLERANCE
	local face_axis_absolute_tolerance = options.face_axis_absolute_tolerance or DEFAULT_FACE_AXIS_ABSOLUTE_TOLERANCE
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

local function find_penetration(poly_vertices, collider_position, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP

	if not (poly_vertices and poly_vertices[1] and collider_position) then return nil end

	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)
	local center_delta = collider_position - triangle_center
	local margin_overlap = (options.collider_margin or 0) + triangle_slop
	local support_axis_y = math.max(options.min_ground_normal_y or 0, 0.5)
	local triangle_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if not triangle_normal then return nil end

	local query_vertices = fill_triangle_prism_vertices(
		TRIANGLE_PRISM_VERTICES_SCRATCH,
		v0,
		v1,
		v2,
		triangle_normal,
		math.max(
			epsilon * 4,
			math.abs(triangle_normal.y) >= support_axis_y and (margin_overlap * 0.5) or 0
		)
	)
	local penetration = gjk_epa.Penetration(poly_vertices, query_vertices, {
		initial_direction = center_delta,
	})

	if not (
		penetration and
		penetration.intersect and
		penetration.normal and
		penetration.depth and
		penetration.depth > epsilon
	) then
		return nil
	end

	local normal = orient_triangle_normal(penetration.normal, center_delta)

	if not normal then return nil end

	return {
		normal = normal,
		overlap = penetration.depth,
		triangle_normal = triangle_normal,
		triangle_center = triangle_center,
		center_delta = center_delta,
	}
end

function polyhedron_triangle_contacts.FindPenetration(collider, polyhedron, v0, v1, v2, options)
	options = options or {}
	return find_penetration(
		options.poly_vertices or polyhedron_cache.GetPolyhedronWorldVertices(collider, polyhedron),
		options.collider_position or collider:GetPosition(),
		v0,
		v1,
		v2,
		{
			epsilon = options.epsilon,
			triangle_slop = options.triangle_slop,
			collider_margin = options.collider_margin or collider:GetCollisionMargin() or 0,
			min_ground_normal_y = options.min_ground_normal_y or collider:GetMinGroundNormalY(),
		}
	)
end

function polyhedron_triangle_contacts.FindContact(collider, polyhedron, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP
	local manifold_merge_distance = options.manifold_merge_distance or DEFAULT_MANIFOLD_MERGE_DISTANCE
	local poly_vertices = options.poly_vertices or polyhedron_cache.GetPolyhedronWorldVertices(collider, polyhedron)

	if not poly_vertices[1] then return nil end

	local penetration = polyhedron_triangle_contacts.FindPenetration(collider, polyhedron, v0, v1, v2, options)

	if not penetration then
		if not should_try_sat_fallback(collider, v0, v1, v2, options) then return nil end

		return find_contact_sat_fallback(collider, polyhedron, v0, v1, v2, options, poly_vertices)
	end

	local triangle_vertices = fill_triangle_vertices(TRIANGLE_VERTICES_SCRATCH, v0, v1, v2)
	local center_delta = penetration.center_delta
	local normal = penetration.normal
	local overlap = penetration.overlap
	local contacts = nil
	local chosen = nil

	chosen = build_face_candidate(
		collider,
		polyhedron,
		orient_triangle_normal(penetration.triangle_normal, center_delta),
		normal
	)
	contacts = contacts or
		chosen and
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
		)
		or
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
