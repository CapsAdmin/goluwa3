local physics_constants = import("goluwa/physics/constants.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local triangle_scalar = import("goluwa/physics/triangle_scalar.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_contact_queries = {}
local SCRATCH_FACE_NORMAL = Vec3()
local polyhedron_triangle_contacts = nil

function triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)
	epsilon = epsilon or physics_constants.EPSILON
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

	return face_normal
end

function triangle_contact_queries.GetPointTriangleSeparation(point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics_constants.EPSILON
	local face_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if face_normal then
		local signed_distance = (point - v0):Dot(face_normal)
		local projected_point = point - face_normal * signed_distance

		if
			triangle_geometry.PointInTriangle(projected_point, v0, v1, v2, face_normal, epsilon)
		then
			local distance = math.abs(signed_distance)
			local normal = nil

			if distance > epsilon then
				normal = signed_distance >= 0 and face_normal or face_normal * -1
			else
				normal = face_normal or options.fallback_normal

				if not normal or normal:GetLength() <= epsilon then
					local fallback_direction = options.fallback_direction
					normal = fallback_direction and
						fallback_direction:GetLength() > epsilon and
						fallback_direction:GetNormalized() or
						physics_constants.UP
				end
			end

			return {
				point = point,
				position = projected_point,
				normal = normal,
				distance = distance,
				face_normal = face_normal,
			}
		end
	end

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
				physics_constants.UP
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
	local epsilon = options.epsilon or physics_constants.EPSILON
	local segment_point, triangle_point, distance, triangle_normal = triangle_geometry.ClosestPointsOnSegmentTriangle(
		start_point,
		end_point,
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = options.fallback_normal or physics_constants.UP,
			face_normal = options.face_normal,
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
	local epsilon = options.epsilon or physics_constants.EPSILON
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
			normal = triangle_normal or options.fallback_normal or physics_constants.UP
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

local PARALLEL_CONTACT_TOLERANCE = 0.001
-- Same result as BuildCapsuleTrianglePair, computed on numbers and only
-- turned into vectors for triangles within max_distance of the capsule
-- segment; farther triangles return nil. This is the per-triangle hot path of
-- walking on a mesh.
function triangle_contact_queries.BuildCapsuleTrianglePairWithin(
	start_point,
	end_point,
	radius,
	center,
	v0,
	v1,
	v2,
	epsilon,
	fallback_normal,
	max_distance
)
	local nx, ny, nz, normal_length_squared = triangle_scalar.TriangleNormalRaw(v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z)
	local normal_length = math.sqrt(normal_length_squared)
	local face_normal = nil

	if normal_length > epsilon then
		SCRATCH_FACE_NORMAL.x = nx / normal_length
		SCRATCH_FACE_NORMAL.y = ny / normal_length
		SCRATCH_FACE_NORMAL.z = nz / normal_length
		face_normal = SCRATCH_FACE_NORMAL
	end

	local distance_squared, sx, sy, sz, tx, ty, tz = triangle_scalar.SegmentToTriangleSq(
		start_point.x,
		start_point.y,
		start_point.z,
		end_point.x,
		end_point.y,
		end_point.z,
		v0.x,
		v0.y,
		v0.z,
		v1.x,
		v1.y,
		v1.z,
		v2.x,
		v2.y,
		v2.z,
		face_normal,
		epsilon
	)
	local distance = math.sqrt(distance_squared)

	if distance > max_distance then return nil end

	-- a capsule running parallel to a surface touches it along a whole
	-- interval and the closest pair lands on an arbitrary end; a contact there
	-- gets a lever arm that spins the body, so use the segment midpoint
	if distance > epsilon then
		local mx = (start_point.x + end_point.x) * 0.5
		local my = (start_point.y + end_point.y) * 0.5
		local mz = (start_point.z + end_point.z) * 0.5
		local mid_squared, qx, qy, qz = triangle_scalar.PointToTriangleSq(mx, my, mz, v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z)
		local mid_distance = math.sqrt(mid_squared)

		if mid_distance <= distance + PARALLEL_CONTACT_TOLERANCE then
			distance = mid_distance
			sx, sy, sz, tx, ty, tz = mx, my, mz, qx, qy, qz
		end
	end

	local normal_x, normal_y, normal_z

	if distance > epsilon then
		normal_x, normal_y, normal_z = (sx - tx) / distance, (sy - ty) / distance, (sz - tz) / distance
	else
		local center_x = center and center.x or (start_point.x + end_point.x) * 0.5
		local center_y = center and center.y or (start_point.y + end_point.y) * 0.5
		local center_z = center and center.z or (start_point.z + end_point.z) * 0.5
		local dx, dy, dz = center_x - tx, center_y - ty, center_z - tz
		local center_distance = math.sqrt(dx * dx + dy * dy + dz * dz)

		if center_distance > epsilon then
			normal_x, normal_y, normal_z = dx / center_distance, dy / center_distance, dz / center_distance
		elseif face_normal then
			normal_x, normal_y, normal_z = face_normal.x, face_normal.y, face_normal.z
		else
			normal_x, normal_y, normal_z = fallback_normal.x, fallback_normal.y, fallback_normal.z
		end
	end

	local face = nil

	if face_normal then
		face = Vec3(face_normal.x, face_normal.y, face_normal.z)
	elseif distance > epsilon then
		face = Vec3(normal_x, normal_y, normal_z)
	else
		face = fallback_normal
	end

	return {
		point = Vec3(sx - normal_x * radius, sy - normal_y * radius, sz - normal_z * radius),
		position = Vec3(tx, ty, tz),
		normal = Vec3(normal_x, normal_y, normal_z),
		distance = distance,
		face_normal = face,
		segment_point = Vec3(sx, sy, sz),
	}
end

function triangle_contact_queries.QueryPointSample(collider, world_point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics_constants.EPSILON
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
