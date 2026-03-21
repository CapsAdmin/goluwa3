local physics = import("goluwa/physics.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_contact_queries = {}
local polyhedron_triangle_contacts = nil

function triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)
	epsilon = epsilon or physics.EPSILON
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

	return face_normal
end

function triangle_contact_queries.GetPointTriangleSeparation(point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local face_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)
	local closest_point = triangle_geometry.ClosestPointOnTriangle(point, v0, v1, v2)
	local delta = point - closest_point
	local distance = delta:GetLength()
	local normal = nil

	if distance > epsilon then
		normal = delta / distance
	else
		normal = face_normal or options.fallback_normal

		if not normal or normal:GetLength() <= epsilon then
			local fallback_direction = options.fallback_direction
			normal = fallback_direction and
				fallback_direction:GetLength() > epsilon and
				fallback_direction:GetNormalized() or
				Vec3(0, 1, 0)
		end
	end

	return {
		point = point,
		position = closest_point,
		normal = normal,
		distance = distance,
		face_normal = face_normal,
	}
end

function triangle_contact_queries.BuildSphereTrianglePair(center, radius, v0, v1, v2, options)
	local result = triangle_contact_queries.GetPointTriangleSeparation(center, v0, v1, v2, options)

	if not result.face_normal then return nil end

	return {
		point = center - result.normal * radius,
		position = result.position,
		normal = result.normal,
		distance = result.distance,
		face_normal = result.face_normal,
	}
end

function triangle_contact_queries.GetSegmentTriangleSeparation(start_point, end_point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local segment_point, triangle_point, distance, triangle_normal = triangle_geometry.ClosestPointsOnSegmentTriangle(
		start_point,
		end_point,
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = options.fallback_normal or physics.Up,
		}
	)

	if not (segment_point and triangle_point and distance) then return nil end

	return {
		segment_point = segment_point,
		position = triangle_point,
		distance = distance,
		face_normal = triangle_normal,
	}
end

function triangle_contact_queries.GetCapsuleTriangleSeparation(start_point, end_point, center, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local separation = triangle_contact_queries.GetSegmentTriangleSeparation(start_point, end_point, v0, v1, v2, options)

	if not separation then return nil end

	local segment_point = separation.segment_point
	local triangle_point = separation.position
	local distance = separation.distance
	local triangle_normal = separation.face_normal
	local normal = nil

	if distance > epsilon then
		normal = (segment_point - triangle_point) / distance
	else
		normal = options.zero_distance_normal

		if not normal or normal:GetLength() <= epsilon then
			local center_delta = (center or ((start_point + end_point) * 0.5)) - triangle_point
			local center_distance = center_delta:GetLength()
			normal = center_distance > epsilon and (center_delta / center_distance) or nil
		end

		if not normal or normal:GetLength() <= epsilon then
			normal = triangle_normal or options.fallback_normal or Vec3(0, 1, 0)
		end
	end

	return {
		segment_point = segment_point,
		position = triangle_point,
		normal = normal,
		distance = distance,
		face_normal = triangle_normal,
	}
end

function triangle_contact_queries.BuildCapsuleTrianglePair(start_point, end_point, radius, center, v0, v1, v2, options)
	local result = triangle_contact_queries.GetCapsuleTriangleSeparation(start_point, end_point, center, v0, v1, v2, options)

	if not result then return nil end

	return {
		point = result.segment_point - result.normal * radius,
		position = result.position,
		normal = result.normal,
		distance = result.distance,
		face_normal = result.face_normal,
		segment_point = result.segment_point,
	}
end

function triangle_contact_queries.QueryPointSample(collider, world_point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local face_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if not face_normal then return nil end

	local signed_distance = (world_point - v0):Dot(face_normal)
	local projected_point = world_point - face_normal * signed_distance

	if
		face_normal.y >= collider:GetMinGroundNormalY() and
		triangle_geometry.PointInTriangle(projected_point, v0, v1, v2, face_normal)
	then
		return {
			point = world_point,
			position = projected_point,
			normal = face_normal,
			surface_distance = signed_distance,
			face_normal = face_normal,
		}
	end

	local result = triangle_contact_queries.GetPointTriangleSeparation(world_point, v0, v1, v2, options)
	return {
		point = world_point,
		position = result.position,
		normal = result.normal,
		surface_distance = result.distance,
		face_normal = face_normal,
	}
end

function triangle_contact_queries.QuerySphere(collider, v0, v1, v2, options)
	local shape = collider:GetPhysicsShape()
	local radius = shape and shape.GetRadius and shape:GetRadius() or 0
	local result = triangle_contact_queries.BuildSphereTrianglePair(collider:GetPosition(), radius, v0, v1, v2, options)

	if not result then return nil end

	result.radius = radius
	result.surface_distance = result.distance - radius
	return result
end

function triangle_contact_queries.QueryCapsule(collider, v0, v1, v2, options)
	local shape = capsule_geometry.GetCapsuleShape(collider)

	if not shape then return nil end

	local radius = shape:GetRadius()
	local start_point, end_point = capsule_geometry.GetSegmentWorld(collider)
	local result = triangle_contact_queries.BuildCapsuleTrianglePair(
		start_point,
		end_point,
		radius,
		collider:GetPosition(),
		v0,
		v1,
		v2,
		options
	)

	if not result then return nil end

	result.radius = radius
	result.surface_distance = result.distance - radius
	return result
end

function triangle_contact_queries.QueryPolyhedron(collider, polyhedron, v0, v1, v2, options)
	polyhedron_triangle_contacts = polyhedron_triangle_contacts or
		import("goluwa/physics/polyhedron/triangle_contacts.lua")
	return polyhedron_triangle_contacts.FindContact(collider, polyhedron, v0, v1, v2, options)
end

return triangle_contact_queries
