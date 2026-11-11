local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local polyhedron_face_contacts = import("goluwa/physics/polyhedron/face_contacts.lua")
local polyhedron_sat = import("goluwa/physics/polyhedron/sat.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
-- a builtin LuaJIT cannot record ends the trace so the side traces after it do not inherit the locals of the axis loop
local trace_break = import("goluwa/jit/tracebreak.lua")
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
local EMPTY_OPTIONS = {}
local FIND_PENETRATION_OPTIONS = {}
local FACE_CONTACT_OPTIONS = {
	triangle_slop = 0,
	max_contacts = 4,
	scratch = FACE_CONTACT_SCRATCH,
	out = FACE_CONTACT_SCRATCH.contacts,
}
local SUPPORT_CONTACT_OPTIONS = {
	merge_distance = 0,
	max_contacts = 4,
	scratch = SUPPORT_CONTACT_SCRATCH,
}
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
local BOX_AXIS = Vec3()
local UNIT_X, UNIT_Y, UNIT_Z = Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)

do
	local function face_axis_gap(rotation, unit, cx, cy, cz, half, v0, v1, v2)
		local axis = Quat.SetVecMul(BOX_AXIS, rotation, unit)
		local ax, ay, az = axis.x, axis.y, axis.z
		local center = cx * ax + cy * ay + cz * az
		local p0 = v0.x * ax + v0.y * ay + v0.z * az
		local p1 = v1.x * ax + v1.y * ay + v1.z * az
		local p2 = v2.x * ax + v2.y * ay + v2.z * az
		local low = math.min(p0, p1, p2)
		local high = math.max(p0, p1, p2)
		return math.max(low - (center + half), (center - half) - high)
	end

	function polyhedron_triangle_contacts.IsBoxSeparatedByFaceAxis(box_body, v0, v1, v2, threshold)
		trace_break()
		local center = box_body:GetPosition()
		local half = box_body:GetHalfExtents()
		local rotation = box_body:GetRotation()
		local cx, cy, cz = center.x, center.y, center.z
		return face_axis_gap(rotation, UNIT_X, cx, cy, cz, half.x, v0, v1, v2) > threshold or
			face_axis_gap(rotation, UNIT_Y, cx, cy, cz, half.y, v0, v1, v2) > threshold or
			face_axis_gap(rotation, UNIT_Z, cx, cy, cz, half.z, v0, v1, v2) > threshold
	end
end

local is_separated_by_triangle_prism

do
	local math_sqrt = math.sqrt
	local math_min = math.min
	local math_max = math.max
	local huge = math.huge

	-- the triangle plane and the three planes through its edges along the normal are separating axes that need no gjk; a hull swept by a translation covers its start and end projections
	function is_separated_by_triangle_prism(poly_vertices, v0, v1, v2, threshold, mx, my, mz)
		local ax, ay, az = v0.x, v0.y, v0.z
		local bx, by, bz = v1.x, v1.y, v1.z
		local cx, cy, cz = v2.x, v2.y, v2.z
		local e0x, e0y, e0z = bx - ax, by - ay, bz - az
		local e1x, e1y, e1z = cx - bx, cy - by, cz - bz
		local e2x, e2y, e2z = ax - cx, ay - cy, az - cz
		local nx, ny, nz = e0y * -e2z - e0z * -e2y, e0z * -e2x - e0x * -e2z, e0x * -e2y - e0y * -e2x
		local length = math_sqrt(nx * nx + ny * ny + nz * nz)

		if length < 1e-12 then return false end

		nx, ny, nz = nx / length, ny / length, nz / length
		local m0x, m0y, m0z = e0y * nz - e0z * ny, e0z * nx - e0x * nz, e0x * ny - e0y * nx
		local m1x, m1y, m1z = e1y * nz - e1z * ny, e1z * nx - e1x * nz, e1x * ny - e1y * nx
		local m2x, m2y, m2z = e2y * nz - e2z * ny, e2z * nx - e2x * nz, e2x * ny - e2y * nx
		local l0 = math_sqrt(m0x * m0x + m0y * m0y + m0z * m0z)
		local l1 = math_sqrt(m1x * m1x + m1y * m1y + m1z * m1z)
		local l2 = math_sqrt(m2x * m2x + m2y * m2y + m2z * m2z)

		if l0 < 1e-12 or l1 < 1e-12 or l2 < 1e-12 then return false end

		m0x, m0y, m0z = m0x / l0, m0y / l0, m0z / l0
		m1x, m1y, m1z = m1x / l1, m1y / l1, m1z / l1
		m2x, m2y, m2z = m2x / l2, m2y / l2, m2z / l2
		local plane = nx * ax + ny * ay + nz * az
		local edge0 = m0x * ax + m0y * ay + m0z * az
		local edge1 = m1x * bx + m1y * by + m1z * bz
		local edge2 = m2x * cx + m2y * cy + m2z * cz
		local low, high = huge, -huge
		local out0, out1, out2 = huge, huge, huge

		for i = 1, #poly_vertices do
			local p = poly_vertices[i]
			local px, py, pz = p.x, p.y, p.z
			local d = nx * px + ny * py + nz * pz
			low = math_min(low, d)
			high = math_max(high, d)
			out0 = math_min(out0, m0x * px + m0y * py + m0z * pz - edge0)
			out1 = math_min(out1, m1x * px + m1y * py + m1z * pz - edge1)
			out2 = math_min(out2, m2x * px + m2y * py + m2z * pz - edge2)
		end

		if mx then
			local d = nx * mx + ny * my + nz * mz
			low = math_min(low, low + d)
			high = math_max(high, high + d)
			out0 = math_min(out0, out0 + m0x * mx + m0y * my + m0z * mz)
			out1 = math_min(out1, out1 + m1x * mx + m1y * my + m1z * mz)
			out2 = math_min(out2, out2 + m2x * mx + m2y * my + m2z * mz)
		end

		return low - plane > threshold or
			plane - high > threshold or
			out0 > threshold or
			out1 > threshold or
			out2 > threshold
	end
end

polyhedron_triangle_contacts.IsSeparatedByTrianglePrism = is_separated_by_triangle_prism

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

local function set_prism_vertex(out, index, x, y, z)
	local vertex = out[index]

	if vertex then vertex:Set(x, y, z) else out[index] = Vec3(x, y, z) end
end

local function fill_triangle_prism_vertices(out, v0, v1, v2, normal, half_thickness)
	out = out or {}
	local ox, oy, oz = normal.x * half_thickness, normal.y * half_thickness, normal.z * half_thickness
	set_prism_vertex(out, 1, v0.x + ox, v0.y + oy, v0.z + oz)
	set_prism_vertex(out, 2, v1.x + ox, v1.y + oy, v1.z + oz)
	set_prism_vertex(out, 3, v2.x + ox, v2.y + oy, v2.z + oz)
	set_prism_vertex(out, 4, v0.x - ox, v0.y - oy, v0.z - oz)
	set_prism_vertex(out, 5, v1.x - ox, v1.y - oy, v1.z - oz)
	set_prism_vertex(out, 6, v2.x - ox, v2.y - oy, v2.z - oz)

	for i = 7, #out do
		out[i] = nil
	end

	return out
end

local function orient_triangle_normal(normal, face_normal, center_delta, outward_winding)
	if not normal then return nil end

	if face_normal and outward_winding then
		return normal:Dot(face_normal) >= 0 and normal or face_normal
	end

	return center_delta:Dot(normal) >= 0 and normal or normal * -1
end

local function get_best_face_alignment(polyhedron, rotation, normal)
	local best_alignment = -math.huge

	for _, face in ipairs(polyhedron.faces or {}) do
		best_alignment = math.max(best_alignment, rotation:VecMul(face.normal):GetNormalized():Dot(normal))
	end

	return best_alignment
end

local function build_face_candidate(collider, polyhedron, triangle_normal, normal)
	local face_alignment = get_best_face_alignment(polyhedron, collider:GetRotation(), normal * -1)
	local triangle_alignment = triangle_normal and triangle_normal:Dot(normal) or -math.huge

	if
		face_alignment >= FACE_CONTACT_ALIGNMENT_THRESHOLD and
		face_alignment >= triangle_alignment
	then
		return {
			kind = "face",
			reference = "polyhedron",
		}
	end

	if triangle_alignment >= FACE_CONTACT_ALIGNMENT_THRESHOLD then
		return {
			kind = "face",
			reference = "triangle",
		}
	end

	return nil
end

local FACE_CANDIDATE_SCRATCH = {}

local function build_polyhedron_face_candidate(context)
	local candidate = FACE_CANDIDATE_SCRATCH
	candidate.kind = context.kind
	candidate.reference = context.reference
	return candidate
end

local function get_grounded_margin_overlap(context, axis)
	trace_break()
	return math.abs(axis.y) >= context.support_axis_y and context.margin_overlap or 0
end

local EDGE_CANDIDATE_SCRATCH = {}

local function build_triangle_edge_candidate(context)
	local candidate = EDGE_CANDIDATE_SCRATCH
	candidate.kind = context.kind
	return candidate
end

local SAT_BEST = convex_sat.CreateBestAxisTracker()
local TRIANGLE_FACE_CANDIDATE = {kind = "face", reference = "triangle"}
local FACE_AXIS_OPTIONS = {
	normalize = true,
	build_candidate = build_polyhedron_face_candidate,
	get_margin_overlap = get_grounded_margin_overlap,
}
local TRIANGLE_AXIS_OPTIONS = {}
local EDGE_AXIS_OPTIONS = {
	build_candidate = build_triangle_edge_candidate,
	get_margin_overlap = get_grounded_margin_overlap,
}

local function should_try_sat_fallback(collider, v0, v1, v2, options)
	local center = collider:GetPosition()

	if not center then return true end

	local center_separation = triangle_contact_queries.GetPointTriangleSeparation(center, v0, v1, v2, {
		epsilon = options.epsilon or DEFAULT_EPSILON,
	})

	if not center_separation then return true end

	local half_extents = collider.GetHalfExtents and collider:GetHalfExtents() or nil
	local radius = half_extents and half_extents:GetLength() or 1
	local margin = (
			collider.GetCollisionMargin and
			collider:GetCollisionMargin() or
			0
		) + (
			options.triangle_slop or
			DEFAULT_TRIANGLE_SLOP
		)
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
	local best = SAT_BEST
	convex_sat.ResetBestAxisTracker(best)
	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)
	local center_delta = collider:GetPosition() - triangle_center
	local margin_overlap = (collider:GetCollisionMargin() or 0) + triangle_slop
	local support_axis_y = math.max(collider:GetMinGroundNormalY() or 0, 0.5)
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.margin_overlap = margin_overlap
	POLYHEDRON_FACE_CANDIDATE_CONTEXT.support_axis_y = support_axis_y
	FACE_AXIS_OPTIONS.epsilon = epsilon
	FACE_AXIS_OPTIONS.build_candidate_context = POLYHEDRON_FACE_CANDIDATE_CONTEXT
	FACE_AXIS_OPTIONS.get_margin_overlap_context = POLYHEDRON_FACE_CANDIDATE_CONTEXT

	if
		not polyhedron_sat.TryUpdatePolyhedronFaceAxisCandidates(
			best,
			poly_vertices,
			triangle_vertices,
			polyhedron,
			collider:GetRotation(),
			center_delta,
			FACE_AXIS_OPTIONS
		)
	then
		return nil
	end

	local triangle_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if not triangle_normal then return nil end

	TRIANGLE_AXIS_OPTIONS.epsilon = epsilon
	TRIANGLE_AXIS_OPTIONS.margin_overlap = math.abs(triangle_normal.y) >= support_axis_y and margin_overlap or 0

	if
		not polyhedron_sat.TryUpdateAxisCandidate(
			best,
			poly_vertices,
			triangle_vertices,
			triangle_normal,
			center_delta,
			TRIANGLE_FACE_CANDIDATE,
			TRIANGLE_AXIS_OPTIONS
		)
	then
		return nil
	end

	local triangle_edges = triangle_geometry.GetTriangleEdges(v0, v1, v2, TRIANGLE_EDGE_SCRATCH)
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.margin_overlap = margin_overlap
	POLYHEDRON_EDGE_CANDIDATE_CONTEXT.support_axis_y = support_axis_y
	EDGE_AXIS_OPTIONS.epsilon = epsilon
	EDGE_AXIS_OPTIONS.build_candidate_context = POLYHEDRON_EDGE_CANDIDATE_CONTEXT
	EDGE_AXIS_OPTIONS.get_margin_overlap_context = POLYHEDRON_EDGE_CANDIDATE_CONTEXT

	if
		not polyhedron_sat.TryUpdatePolyhedronTriangleEdgeAxisCandidates(
			best,
			poly_vertices,
			triangle_vertices,
			polyhedron,
			collider:GetRotation(),
			triangle_edges,
			center_delta,
			EDGE_AXIS_OPTIONS
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

	FACE_CONTACT_OPTIONS.triangle_slop = triangle_slop
	local contacts = chosen and
		chosen.kind == "face" and
		polyhedron_face_contacts.BuildPolyhedronTriangleFaceContacts(
			collider,
			polyhedron,
			triangle_vertices,
			chosen,
			normal,
			FACE_CONTACT_OPTIONS
		) or
		nil

	if not contacts or #contacts < 3 then
		SUPPORT_CONTACT_OPTIONS.merge_distance = manifold_merge_distance
		contacts = convex_manifold.BuildAndMergeSupportPairContacts(
			contacts,
			poly_vertices,
			triangle_vertices,
			normal * -1,
			SUPPORT_CONTACT_OPTIONS
		)
	end

	if contacts and contacts[1] then
		return {
			contacts = contacts,
			normal = normal:Copy(),
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
		normal = normal:Copy(),
		overlap = overlap,
		contacts = convex_manifold.BuildSingleContact(SINGLE_CONTACT_SCRATCH, point_a, point_b),
	}
end

local PENETRATION_TRIANGLE_CENTER = Vec3()
local PENETRATION_CENTER_DELTA = Vec3()
local PENETRATION_TRIANGLE_NORMAL = Vec3()
local PENETRATION_EDGE_A = Vec3()
local PENETRATION_EDGE_B = Vec3()

local function find_penetration(poly_vertices, collider_position, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP

	if not (poly_vertices and poly_vertices[1] and collider_position) then
		return nil
	end

	local triangle_center = PENETRATION_TRIANGLE_CENTER
	triangle_center.x = (v0.x + v1.x + v2.x) / 3
	triangle_center.y = (v0.y + v1.y + v2.y) / 3
	triangle_center.z = (v0.z + v1.z + v2.z) / 3
	local center_delta = Vec3.SetSub(PENETRATION_CENTER_DELTA, collider_position, triangle_center)
	local margin_overlap = (options.collider_margin or 0) + triangle_slop
	local support_axis_y = math.max(options.min_ground_normal_y or 0, 0.5)
	local triangle_normal = Vec3.SetCross(
		PENETRATION_TRIANGLE_NORMAL,
		Vec3.SetSub(PENETRATION_EDGE_A, v1, v0),
		Vec3.SetSub(PENETRATION_EDGE_B, v2, v0)
	):Normalize()

	if triangle_normal:GetLength() <= epsilon then return nil end

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
	local penetration = gjk_epa.Penetration(poly_vertices, query_vertices, center_delta)

	if penetration and not penetration.intersect then
		local distance = penetration.distance
		return nil, distance and distance.distance or penetration.gjk.separation
	end

	if
		not (
			penetration and
			penetration.intersect and
			penetration.normal and
			penetration.depth and
			penetration.depth > epsilon
		)
	then
		return nil
	end

	triangle_center = triangle_center:Copy()
	center_delta = center_delta:Copy()
	triangle_normal = triangle_normal:Copy()
	local normal = orient_triangle_normal(penetration.normal, triangle_normal, center_delta, options.outward_winding)

	if not normal then return nil end

	return {
		normal = normal,
		overlap = penetration.depth,
		triangle_normal = triangle_normal,
		triangle_center = triangle_center,
		center_delta = center_delta,
		outward_winding = options.outward_winding,
	}
end

function polyhedron_triangle_contacts.FindPenetration(collider, polyhedron, v0, v1, v2, options)
	options = options or EMPTY_OPTIONS
	FIND_PENETRATION_OPTIONS.epsilon = options.epsilon
	FIND_PENETRATION_OPTIONS.triangle_slop = options.triangle_slop
	FIND_PENETRATION_OPTIONS.collider_margin = options.collider_margin or collider:GetCollisionMargin() or 0
	FIND_PENETRATION_OPTIONS.min_ground_normal_y = options.min_ground_normal_y or collider:GetMinGroundNormalY()
	return find_penetration(
		options.poly_vertices or
			polyhedron_cache.GetPolyhedronWorldVertices(collider, polyhedron),
		options.collider_position or collider:GetPosition(),
		v0,
		v1,
		v2,
		FIND_PENETRATION_OPTIONS
	)
end

function polyhedron_triangle_contacts.FindContact(collider, polyhedron, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or DEFAULT_EPSILON
	local triangle_slop = options.triangle_slop or DEFAULT_TRIANGLE_SLOP
	local manifold_merge_distance = options.manifold_merge_distance or DEFAULT_MANIFOLD_MERGE_DISTANCE
	local poly_vertices = options.poly_vertices or
		polyhedron_cache.GetPolyhedronWorldVertices(collider, polyhedron)

	if not poly_vertices[1] then return nil end

	local separation_threshold = math.max(collider:GetCollisionMargin() or 0, options.collider_margin or 0) + triangle_slop + 0.01

	if is_separated_by_triangle_prism(poly_vertices, v0, v1, v2, separation_threshold) then
		return nil
	end

	if
		collider:GetShapeType() == "box" and
		polyhedron_triangle_contacts.IsBoxSeparatedByFaceAxis(collider, v0, v1, v2, separation_threshold)
	then
		return nil
	end

	local penetration, separation = polyhedron_triangle_contacts.FindPenetration(collider, polyhedron, v0, v1, v2, options)

	if not penetration then
		if separation and separation > separation_threshold then return nil end

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
		orient_triangle_normal(
			penetration.triangle_normal,
			penetration.triangle_normal,
			center_delta,
			penetration.outward_winding
		),
		normal
	)
	FACE_CONTACT_OPTIONS.triangle_slop = triangle_slop
	contacts = contacts or
		chosen and
		chosen.kind == "face" and
		polyhedron_face_contacts.BuildPolyhedronTriangleFaceContacts(
			collider,
			polyhedron,
			triangle_vertices,
			chosen,
			normal,
			FACE_CONTACT_OPTIONS
		)
		or
		nil

	if not contacts or #contacts < 3 then
		SUPPORT_CONTACT_OPTIONS.merge_distance = manifold_merge_distance
		contacts = convex_manifold.BuildAndMergeSupportPairContacts(
			contacts,
			poly_vertices,
			triangle_vertices,
			normal * -1,
			SUPPORT_CONTACT_OPTIONS
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
