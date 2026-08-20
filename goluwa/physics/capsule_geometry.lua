local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = {}
local CAPSULE_LOCAL_SEGMENT_POINTS = {
	bottom = Vec3(0, 0, 0),
	top = Vec3(0, 0, 0),
}

-- owner is a capsule rigid body or a capsule collider
function capsule_geometry.GetCapsuleShape(owner)
	local shape = owner:GetPhysicsShape()
	assert(
		shape and shape:GetTypeName() == "capsule",
		"capsule_geometry requires a capsule, got " .. tostring(shape and shape:GetTypeName())
	)
	return shape
end

function capsule_geometry.GetCylinderHeight(shape)
	return math.max(0, shape:GetHeight() - shape:GetRadius() * 2)
end

function capsule_geometry.GetCylinderHalfHeight(shape)
	return capsule_geometry.GetCylinderHeight(shape) * 0.5
end

function capsule_geometry.GetBottomSphereCenterLocal(shape)
	return Vec3(0, -capsule_geometry.GetCylinderHalfHeight(shape), 0)
end

function capsule_geometry.GetTopSphereCenterLocal(shape)
	return Vec3(0, capsule_geometry.GetCylinderHalfHeight(shape), 0)
end

function capsule_geometry.GetSegmentWorld(owner, position, rotation)
	local shape = capsule_geometry.GetCapsuleShape(owner)
	local half_height = capsule_geometry.GetCylinderHalfHeight(shape)
	local local_points = CAPSULE_LOCAL_SEGMENT_POINTS
	local_points.bottom.y = -half_height
	local_points.top.y = half_height
	return owner:LocalToWorld(local_points.bottom, position, rotation),
	owner:LocalToWorld(local_points.top, position, rotation),
	shape:GetRadius()
end

return capsule_geometry
