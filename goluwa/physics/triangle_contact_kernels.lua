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

function triangle_contact_kernels.BuildSphereTrianglePair(center, radius, v0, v1, v2, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local face_normal = triangle_contact_kernels.GetTriangleFaceNormal(v0, v1, v2, epsilon)

	if not face_normal then return nil end

	local closest_point = triangle_geometry.ClosestPointOnTriangle(center, v0, v1, v2)
	local delta = center - closest_point
	local distance = delta:GetLength()
	local normal = distance > epsilon and (delta / distance) or face_normal
	return {
		point = center - normal * radius,
		position = closest_point,
		normal = normal,
		distance = distance,
		face_normal = face_normal,
	}
end

function triangle_contact_kernels.BuildCapsuleTrianglePair(start_point, end_point, radius, center, v0, v1, v2, options)
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

	local normal

	if distance > epsilon then
		normal = (segment_point - triangle_point) / distance
	else
		local center_delta = (center or ((start_point + end_point) * 0.5)) - triangle_point
		local center_distance = center_delta:GetLength()
		normal = center_distance > epsilon and (center_delta / center_distance) or triangle_normal or Vec3(0, 1, 0)
	end

	return {
		point = segment_point - normal * radius,
		position = triangle_point,
		normal = normal,
		distance = distance,
		face_normal = triangle_normal,
		segment_point = segment_point,
	}
end

return triangle_contact_kernels