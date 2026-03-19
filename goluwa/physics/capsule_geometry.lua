local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = {}

function capsule_geometry.GetCapsuleShape(shape_or_body)
	if not shape_or_body then return nil end

	if shape_or_body.GetTypeName and shape_or_body:GetTypeName() == "capsule" then
		return shape_or_body
	end

	local shape = shape_or_body.GetPhysicsShape and shape_or_body:GetPhysicsShape() or nil
	return shape and shape.GetTypeName and shape:GetTypeName() == "capsule" and shape or nil
end

function capsule_geometry.GetCylinderHeight(shape_or_body)
	local shape = capsule_geometry.GetCapsuleShape(shape_or_body)

	if not (shape and shape.GetHeight and shape.GetRadius) then return 0 end

	return math.max(0, shape:GetHeight() - shape:GetRadius() * 2)
end

function capsule_geometry.GetCylinderHalfHeight(shape_or_body)
	return capsule_geometry.GetCylinderHeight(shape_or_body) * 0.5
end

function capsule_geometry.GetBottomSphereCenterLocal(shape_or_body)
	return Vec3(0, -capsule_geometry.GetCylinderHalfHeight(shape_or_body), 0)
end

function capsule_geometry.GetTopSphereCenterLocal(shape_or_body)
	return Vec3(0, capsule_geometry.GetCylinderHalfHeight(shape_or_body), 0)
end

function capsule_geometry.GetSegmentWorld(body, position, rotation)
	local shape = capsule_geometry.GetCapsuleShape(body)

	if not shape then return nil, nil, 0 end

	return body:LocalToWorld(capsule_geometry.GetBottomSphereCenterLocal(shape), position, rotation),
	body:LocalToWorld(capsule_geometry.GetTopSphereCenterLocal(shape), position, rotation),
	shape:GetRadius()
end

return capsule_geometry