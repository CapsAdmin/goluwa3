local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local polyhedron_face_contacts = {}

function polyhedron_face_contacts.GetWorldFace(body, polyhedron, face_index)
	local face = face_index and
		polyhedron_cache.GetPolyhedronWorldFace(body, polyhedron, face_index) or
		nil

	if not (face and face.points and face.points[1]) then return nil end

	return face
end

function polyhedron_face_contacts.GetIncidentWorldFace(body, polyhedron, rotation, reference_normal)
	local face_index = polyhedron_cache.FindIncidentFaceIndex(polyhedron, rotation, reference_normal)

	if not face_index then return nil end

	return polyhedron_face_contacts.GetWorldFace(body, polyhedron, face_index),
	face_index
end

function polyhedron_face_contacts.BuildClippedPairs(reference_points, reference_normal, incident_points, options)
	options = options or {}
	return convex_face_clipping.BuildFaceContactPairs(
		reference_points,
		reference_normal,
		incident_points,
		{
			separation_tolerance = options.separation_tolerance,
			max_contacts = options.max_contacts or 4,
			scratch = options.scratch,
			out = options.out,
			swap = options.swap,
			merge_distance = options.merge_distance,
		}
	)
end

function polyhedron_face_contacts.BuildPolyhedronTriangleFaceContacts(collider, polyhedron, triangle_vertices, chosen, normal, options)
	options = options or {}

	if not (chosen and normal and triangle_vertices and triangle_vertices[1]) then
		return nil
	end

	if normal.y < collider:GetMinGroundNormalY() then return nil end

	local polyhedron_face = polyhedron_face_contacts.GetIncidentWorldFace(collider, polyhedron, collider:GetRotation(), normal)

	if not polyhedron_face then return nil end

	local triangle_area = triangle_geometry.GetTriangleArea(triangle_vertices[1], triangle_vertices[2], triangle_vertices[3])

	if
		triangle_area < triangle_geometry.GetPolygonArea(polyhedron_face.points) * (
			options.area_scale or
			1.25
		)
	then
		return nil
	end

	local reference_points = triangle_vertices
	local reference_normal = normal
	local incident_points = polyhedron_face.points
	local swap = true

	if chosen.reference == "polyhedron" then
		reference_points = polyhedron_face.points
		reference_normal = normal * -1
		incident_points = triangle_vertices
		swap = false
	end

	return polyhedron_face_contacts.BuildClippedPairs(
		reference_points,
		reference_normal,
		incident_points,
		{
			separation_tolerance = (collider:GetCollisionMargin() or 0) + (options.triangle_slop or 0),
			max_contacts = options.max_contacts or 4,
			scratch = options.scratch,
			out = options.out,
			swap = swap,
			merge_distance = options.merge_distance,
		}
	)
end

return polyhedron_face_contacts
