local physics = import("goluwa/physics.lua")
local motion = import("goluwa/physics/motion.lua")
local world_contact_cache = import("goluwa/physics/world_contact/cache.lua")
local world_contact_resolution = {}
local WORLD_TANGENT_WARM_START_SCALE = 0.15
local WORLD_MAX_TANGENT_WARM_SPEED = 0.25

local function sync_body_motion_history(body, dt)
	dt = dt or body.StepDt or (1 / 60)
	body.PreviousPosition = body.Position - body:GetVelocity() * dt
	body.PreviousRotation = motion.IntegrateRotation(body.Rotation, body:GetAngularVelocity(), -dt)
end

local function get_point_velocity(body, point)
	return body:GetVelocity() + body:GetAngularVelocity():GetCross(point - body:GetPosition())
end

function world_contact_resolution.ApplyStaticContactImpulse(body, point, normal, dt, contact)
	if not (body.HasSolverMass and body:HasSolverMass()) then return end

	local point_velocity = get_point_velocity(body, point)
	local normal_speed = point_velocity:Dot(normal)
	local normal_impulse = 0
	local applied_impulse = false
	local allow_persistent_tangent = contact and contact.cached and normal.y < body:GetMinGroundNormalY()
	local tangent = allow_persistent_tangent and
		world_contact_cache.GetCachedTangent(contact, normal) or
		nil
	local previous_tangent_impulse = allow_persistent_tangent and (contact.tangent_impulse or 0) or 0
	local tangent_warmed = false

	if tangent and math.abs(previous_tangent_impulse) > physics.EPSILON then
		local tangent_speed = math.abs(point_velocity:Dot(tangent))

		if tangent_speed <= WORLD_MAX_TANGENT_WARM_SPEED then
			local warm_impulse = tangent * (previous_tangent_impulse * WORLD_TANGENT_WARM_START_SCALE)
			body:ApplyImpulse(warm_impulse, point)
			point_velocity = get_point_velocity(body, point)
			normal_speed = point_velocity:Dot(normal)
			applied_impulse = true
			tangent_warmed = true
		end
	end

	if normal_speed < -physics.EPSILON then
		local inverse_mass = body:GetInverseMassAlong(normal, point)

		if inverse_mass > physics.EPSILON then
			normal_impulse = -normal_speed / inverse_mass
			body:ApplyImpulse(normal * normal_impulse, point)
			point_velocity = get_point_velocity(body, point)
			applied_impulse = true
		end
	end

	local tangent_velocity = point_velocity - normal * point_velocity:Dot(normal)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed <= physics.EPSILON then
		if contact then
			contact.tangent_impulse = 0
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	local friction = math.max(body:GetFriction() or 0, 0)

	if friction <= 0 then
		if contact then
			contact.tangent_impulse = 0
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	tangent = tangent_velocity / tangent_speed
	local tangent_inverse_mass = body:GetInverseMassAlong(tangent, point)

	if tangent_inverse_mass <= physics.EPSILON then return end

	local tangent_impulse = -point_velocity:Dot(tangent) / tangent_inverse_mass
	local max_friction_impulse = math.max(normal_impulse, 0.05) * friction

	if allow_persistent_tangent then
		local new_tangent_impulse = math.max(
			-max_friction_impulse,
			math.min(max_friction_impulse, previous_tangent_impulse + tangent_impulse)
		)
		tangent_impulse = new_tangent_impulse - previous_tangent_impulse
		contact.tangent_impulse = new_tangent_impulse
		contact.tangent = tangent:Copy()
	else
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))
	end

	if math.abs(tangent_impulse) > physics.EPSILON then
		body:ApplyImpulse(tangent * tangent_impulse, point)
		applied_impulse = true
	elseif contact and tangent_warmed then
		contact.tangent = tangent:Copy()
	end

	if applied_impulse then sync_body_motion_history(body, dt) end
end

local function accumulate_ground_contact(body, contact, grounded_normal, grounded_weight)
	if contact.normal.y >= body:GetMinGroundNormalY() then
		grounded_normal = (grounded_normal or physics.Up * 0) + contact.normal * contact.depth
		grounded_weight = grounded_weight + contact.depth
		body:SetGrounded(true)
	end

	if physics.RecordWorldCollision then
		physics.RecordWorldCollision(body, contact.hit, contact.normal, contact.depth)
	end

	return grounded_normal, grounded_weight
end

function world_contact_resolution.ApplyContactPatch(body, contacts, dt, grounded_normal, grounded_weight)
	local patch_count = #contacts

	if patch_count == 0 then return false, grounded_normal, grounded_weight end

	for i = 1, patch_count do
		local contact = contacts[i]
		body:ApplyCorrection(0, contact.normal * (contact.depth / patch_count), contact.point, nil, nil, dt)
	end

	for i = 1, patch_count do
		local contact = contacts[i]
		world_contact_resolution.ApplyStaticContactImpulse(body, contact.point, contact.normal, dt, contact)
		grounded_normal, grounded_weight = accumulate_ground_contact(body, contact, grounded_normal, grounded_weight)
	end

	return true, grounded_normal, grounded_weight
end

function world_contact_resolution.ContactsFormCoherentPatch(contacts, min_dot)
	min_dot = min_dot or 0.9

	if #contacts <= 1 then return false end

	local reference = contacts[1] and contacts[1].normal

	if not reference then return false end

	for i = 2, #contacts do
		local normal = contacts[i] and contacts[i].normal

		if not (normal and reference:Dot(normal) >= min_dot) then return false end
	end

	return true
end

function world_contact_resolution.ApplyContactSequence(body, contacts, dt, grounded_normal, grounded_weight)
	local solved = false

	for i = 1, #contacts do
		local contact = contacts[i]
		body:ApplyCorrection(0, contact.normal * contact.depth, contact.point, nil, nil, dt)
		world_contact_resolution.ApplyStaticContactImpulse(body, contact.point, contact.normal, dt, contact)
		grounded_normal, grounded_weight = accumulate_ground_contact(body, contact, grounded_normal, grounded_weight)
		solved = true
	end

	return solved, grounded_normal, grounded_weight
end

return world_contact_resolution
