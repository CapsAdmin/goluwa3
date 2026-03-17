local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron_cache.lua")
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

local function get_edge_direction(polyhedron, edge)
	if edge.direction then return edge.direction end

	local a = edge.a or edge[1]
	local b = edge.b or edge[2]
	return a and b and polyhedron.vertices[a] and polyhedron.vertices[b] and (polyhedron.vertices[b] - polyhedron.vertices[a]) or nil
end

local function build_face_contacts(collider, polyhedron, triangle_vertices, chosen, normal, triangle_slop)
	if
		not (
			chosen and
			chosen.face_index and
			normal and
			triangle_vertices and
			triangle_vertices[1]
		)
	then
		return nil
	end

	if normal.y < collider:GetMinGroundNormalY() then return nil end

	local separation_tolerance = (collider:GetCollisionMargin() or 0) + triangle_slop
	local swap = false
	local reference_points = nil
	local incident_points = nil
	local triangle_area = triangle_geometry.GetTriangleArea(triangle_vertices[1], triangle_vertices[2], triangle_vertices[3])

	if chosen.reference == "polyhedron" then
		local reference_face = polyhedron_cache.GetPolyhedronWorldFace(collider, polyhedron, chosen.face_index)

		if not (reference_face and reference_face.points and reference_face.points[1]) then
			return nil
		end

		local face_area = triangle_geometry.GetPolygonArea(reference_face.points)

		if triangle_area < face_area * 1.25 then return nil end

		reference_points = reference_face.points
		incident_points = triangle_vertices
	elseif chosen.reference == "triangle" then
		local incident_face_index = polyhedron_cache.FindIncidentFaceIndex(collider and polyhedron, collider:GetRotation(), normal)
		local incident_face = incident_face_index and
			polyhedron_cache.GetPolyhedronWorldFace(collider, polyhedron, incident_face_index) or
			nil

		if not (incident_face and incident_face.points and incident_face.points[1]) then
			return nil
		end

		local face_area = triangle_geometry.GetPolygonArea(incident_face.points)

		if triangle_area < face_area * 1.25 then return nil end

		reference_points = triangle_vertices
		incident_points = incident_face.points
		swap = true
	end

	return convex_face_clipping.BuildFaceContactPairs(
		reference_points,
		normal,
		incident_points,
		{
			separation_tolerance = separation_tolerance,
			max_contacts = 4,
			scratch = FACE_CONTACT_SCRATCH,
			out = FACE_CONTACT_SCRATCH.contacts,
			swap = swap,
		}
	)
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

	for face_index, face in ipairs(polyhedron.faces or {}) do
		local axis = collider:GetRotation():VecMul(face.normal):GetNormalized()

		if
			not convex_sat.TryUpdateAxis(
				best,
				poly_vertices,
				triangle_vertices,
				axis,
				center_delta,
				{
					kind = "face",
					reference = "polyhedron",
					face_index = face_index,
				},
				math.abs(axis.y) >= support_axis_y and margin_overlap or 0,
				false,
				epsilon
			)
		then
			return nil
		end
	end

	local triangle_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if triangle_normal:GetLength() <= epsilon then return nil end

	if
		not convex_sat.TryUpdateAxis(
			best,
			poly_vertices,
			triangle_vertices,
			triangle_normal,
			center_delta,
			{
				kind = "face",
				reference = "triangle",
			},
			math.abs(triangle_normal.y) >= support_axis_y and margin_overlap or 0,
			false,
			epsilon
		)
	then
		return nil
	end

	local triangle_edges = triangle_geometry.GetTriangleEdges(v0, v1, v2, TRIANGLE_EDGE_SCRATCH)

	for _, edge in ipairs(polyhedron.edges or {}) do
		local edge_axis = get_edge_direction(polyhedron, edge)

		if edge_axis then
			edge_axis = collider:GetRotation():VecMul(edge_axis)

			for _, triangle_edge in ipairs(triangle_edges) do
				local axis = edge_axis:GetCross(triangle_edge)
				local axis_length = axis:GetLength()

				if axis_length > epsilon then
					local normal = axis / axis_length

					if
						not convex_sat.TryUpdateAxis(
							best,
							poly_vertices,
							triangle_vertices,
							normal,
							center_delta,
							{
								kind = "edge",
							},
							math.abs(normal.y) >= support_axis_y and margin_overlap or 0,
							false,
							epsilon
						)
					then
						return nil
					end
				end
			end
		end
	end

	local chosen = convex_sat.ChoosePreferredAxis(best, face_axis_relative_tolerance, face_axis_absolute_tolerance)
	local normal = chosen and chosen.normal or nil
	local overlap = chosen and chosen.overlap or nil

	if not (normal and overlap and overlap > epsilon) then return nil end

	local contacts = chosen and chosen.kind == "face" and build_face_contacts(collider, polyhedron, triangle_vertices, chosen, normal, triangle_slop) or nil
	local support_contacts = nil

	if not contacts or #contacts < 3 then
		support_contacts = convex_manifold.BuildSupportPairContacts(
			poly_vertices,
			triangle_vertices,
			normal * -1,
			{
				merge_distance = manifold_merge_distance,
				max_contacts = 4,
				scratch = SUPPORT_CONTACT_SCRATCH,
			}
		)

		if not contacts then
			contacts = support_contacts
		elseif support_contacts and support_contacts[1] then
			for _, pair in ipairs(support_contacts) do
				contacts[#contacts + 1] = pair

				if #contacts >= 4 then break end
			end
		end
	end

	if contacts and contacts[1] then
		return {
			contacts = contacts,
			normal = normal,
			overlap = overlap,
		}
	end

	local point_a = convex_manifold.AverageSupportPoint(poly_vertices, normal, true)
	local point_b = triangle_geometry.ClosestPointOnTriangle(point_a or collider:GetPosition(), v0, v1, v2)

	if not (point_a and point_b) then return nil end

	return {
		normal = normal,
		overlap = overlap,
		contacts = convex_manifold.BuildSingleContact(SINGLE_CONTACT_SCRATCH, point_a, point_b),
	}
end

return polyhedron_triangle_contacts