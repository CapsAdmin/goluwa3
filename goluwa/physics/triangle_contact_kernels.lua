local physics = import("goluwa/physics.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_contact_kernels = {}

function triangle_contact_kernels.GetTriangleFaceNormal(v0, v1, v2, epsilon)
	epsilon = epsilon or physics.EPSILON
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

	return face_normal
end

function triangle_contact_kernels.GetPointTriangleSeparation(point, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local face_normal = triangle_contact_kernels.GetTriangleFaceNormal(v0, v1, v2, epsilon)
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
			normal = fallback_direction and fallback_direction:GetLength() > epsilon and fallback_direction:GetNormalized() or Vec3(0, 1, 0)
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

function triangle_contact_kernels.BuildSphereTrianglePair(center, radius, v0, v1, v2, options)
	local result = triangle_contact_kernels.GetPointTriangleSeparation(center, v0, v1, v2, options)

	if not result.face_normal then return nil end

	return {
		point = center - result.normal * radius,
		position = result.position,
		normal = result.normal,
		distance = result.distance,
		face_normal = result.face_normal,
	}
end

function triangle_contact_kernels.GetCapsuleTriangleSeparation(start_point, end_point, center, v0, v1, v2, options)
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

function triangle_contact_kernels.BuildCapsuleTrianglePair(start_point, end_point, radius, center, v0, v1, v2, options)
	local result = triangle_contact_kernels.GetCapsuleTriangleSeparation(
		start_point,
		end_point,
		center,
		v0,
		v1,
		v2,
		options
	)

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

return triangle_contact_kernels