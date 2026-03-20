local physics = import("goluwa/physics.lua")
local support_contacts = {}

function support_contacts.GetCastDistances(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	return cast_up, cast_distance
end

function support_contacts.ApplyWorldSupportContact(body, normal, contact_position, support_radius, hit, dt)
	if not (normal and contact_position) then return false end

	local center = body:GetPosition()
	local target_center = contact_position + normal * (support_radius + body:GetCollisionMargin())
	local correction = target_center - center
	local depth = correction:Dot(normal)

	if depth <= 0 then return false end

	body:ApplyCorrection(0, normal * depth, center - normal * support_radius, nil, nil, dt)

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
	return true
end

function support_contacts.ApplyPointWorldSupportContact(body, normal, contact_position, support_point, hit, dt)
	if not (normal and contact_position and support_point) then return false end

	local margin = body:GetCollisionMargin() or 0
	local target_point = contact_position + normal * margin
	local correction = target_point - support_point
	local depth = correction:Dot(normal)
	local support_tolerance = (body:GetCollisionProbeDistance() or 0) + margin

	if depth > 0 then body:ApplyCorrection(0, normal * depth, support_point, nil, nil, dt) end

	if depth < -support_tolerance then return false end

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
	return true
end

return support_contacts
