local support_contacts = {}
local physics = import("goluwa/physics.lua")

function support_contacts.GetCastDistances(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	return cast_up, cast_distance
end

function support_contacts.ForEachPointSweepContact(body, dt, solve_contact, solve_contact_context)
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local support_points = body:GetSupportLocalPoints()
	local owner = body:GetOwner()
	local filter_function = body:GetFilterFunction()
	local cast_origin_offset = physics.Up * cast_up
	local cast_delta = physics.Up * -cast_distance

	for i = 1, #support_points do
		local point = body:GeometryLocalToWorld(support_points[i])
		local hit = physics.Sweep(point + cast_origin_offset, cast_delta, 0, owner, filter_function)

		if hit then
			if solve_contact_context ~= nil then
				solve_contact(solve_contact_context, body, point, hit, dt)
			else
				solve_contact(body, point, hit, dt)
			end
		end
	end
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

	if depth > 0 then
		body:ApplyCorrection(0, normal * depth, support_point, nil, nil, dt)
	end

	if depth < -support_tolerance then return false end

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
	return true
end

function support_contacts.SweepCollider(body, dt)
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local center = body:GetPosition()
	return physics.SweepCollider(
		body,
		center + physics.Up * cast_up,
		physics.Up * -cast_distance,
		body:GetOwner(),
		body:GetFilterFunction(),
		{Rotation = body:GetRotation()}
	)
end

function support_contacts.SweepSphere(body, dt, radius)
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local center = body:GetPosition()
	return physics.Sweep(
		center + physics.Up * cast_up,
		physics.Up * -(cast_distance + radius),
		radius,
		body:GetOwner(),
		body:GetFilterFunction()
	)
end

function support_contacts.SolveShapeSupportContacts(body, shape, dt)
	if not (shape and dt and shape.SolveSupportContacts) then return end

	return shape:SolveSupportContacts(body, dt, support_contacts)
end

return support_contacts
