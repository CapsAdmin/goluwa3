local physics = import("goluwa/physics.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local polyhedron_triangle_contacts = import("goluwa/physics/polyhedron_triangle_contacts.lua")
local triangle_contact_kernels = import("goluwa/physics/triangle_contact_kernels.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local triangle_contact_queries = {}

function triangle_contact_queries.QueryPointSample(collider, world_point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

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

	local result = triangle_contact_kernels.GetPointTriangleSeparation(world_point, v0, v1, v2, options)
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
	local result = triangle_contact_kernels.BuildSphereTrianglePair(collider:GetPosition(), radius, v0, v1, v2, options)

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
	local result = triangle_contact_kernels.BuildCapsuleTrianglePair(
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
	return polyhedron_triangle_contacts.FindContact(collider, polyhedron, v0, v1, v2, options)
end

return triangle_contact_queries