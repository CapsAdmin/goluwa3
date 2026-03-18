local physics = import("goluwa/physics.lua")
local motion = import("goluwa/physics/motion.lua")
local world_contact_cache = import("goluwa/physics/world_contact/cache.lua")
local world_contact_resolution = {}
local WORLD_TANGENT_WARM_START_SCALE = 0.15
local WORLD_MAX_TANGENT_WARM_SPEED = 0.25

local function project_tangent(tangent, normal)
	if not tangent then return nil end

	tangent = tangent - normal * tangent:Dot(normal)

	if tangent:GetLength() <= physics.EPSILON then return nil end

	return tangent:GetNormalized()
end

local function build_fallback_tangent(normal)
	local axis = math.abs(normal.y) < 0.9 and physics.Up or Vec3(1, 0, 0)
	return project_tangent(axis - normal * axis:Dot(normal), normal)
end

local function build_tangent_basis(normal, preferred_tangent)
	local tangent = project_tangent(preferred_tangent, normal) or build_fallback_tangent(normal)

	if not tangent then return nil, nil end

	local bitangent = tangent:GetCross(normal)

	if bitangent:GetLength() <= physics.EPSILON then
		tangent = build_fallback_tangent(normal)

		if not tangent then return nil, nil end

		bitangent = tangent:GetCross(normal)
	end

	bitangent = bitangent:GetNormalized()
	tangent = normal:GetCross(bitangent):GetNormalized()
	return tangent, bitangent
end

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
	local allow_persistent_tangent = contact and contact.cached
	local tangent = allow_persistent_tangent and
		world_contact_cache.GetCachedTangent(contact, normal) or
		nil
	local previous_tangent_impulse_1 = allow_persistent_tangent and
		(
			contact.tangent_impulse_1 or
			contact.tangent_impulse or
			0
		)
		or
		0
	local previous_tangent_impulse_2 = allow_persistent_tangent and (contact.tangent_impulse_2 or 0) or 0
	local tangent_warmed = false

	if
		tangent and
		(
			math.abs(previous_tangent_impulse_1) > physics.EPSILON or
			math.abs(previous_tangent_impulse_2) > physics.EPSILON
		)
	then
		local tangent_speed = math.abs(point_velocity:Dot(tangent))

		if tangent_speed <= WORLD_MAX_TANGENT_WARM_SPEED then
			local tangent_1, tangent_2 = build_tangent_basis(normal, tangent)

			if tangent_1 and math.abs(previous_tangent_impulse_1) > physics.EPSILON then
				local warm_impulse = tangent_1 * (previous_tangent_impulse_1 * WORLD_TANGENT_WARM_START_SCALE)
				body:ApplyImpulse(warm_impulse, point)
			end

			if tangent_2 and math.abs(previous_tangent_impulse_2) > physics.EPSILON then
				local warm_impulse = tangent_2 * (previous_tangent_impulse_2 * WORLD_TANGENT_WARM_START_SCALE)
				body:ApplyImpulse(warm_impulse, point)
			end

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
			contact.tangent_impulse_1 = 0
			contact.tangent_impulse_2 = 0
			contact.static_friction_active = false
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	local dynamic_friction = math.max(body:GetFriction() or 0, 0)
	local static_friction = math.max(dynamic_friction, physics.solver:GetBodyStaticFriction(body))

	if dynamic_friction <= 0 and static_friction <= 0 then
		if contact then
			contact.tangent_impulse = 0
			contact.tangent_impulse_1 = 0
			contact.tangent_impulse_2 = 0
			contact.static_friction_active = false
			contact.tangent = nil
		end

		if applied_impulse then sync_body_motion_history(body, dt) end

		return
	end

	tangent = tangent_velocity / tangent_speed
	local tangent_1, tangent_2 = build_tangent_basis(normal, tangent)

	if not (tangent_1 and tangent_2) then return end

	local tangent_inverse_mass_1 = body:GetInverseMassAlong(tangent_1, point)
	local tangent_inverse_mass_2 = body:GetInverseMassAlong(tangent_2, point)

	if
		tangent_inverse_mass_1 <= physics.EPSILON or
		tangent_inverse_mass_2 <= physics.EPSILON
	then
		return
	end

	local tangent_impulse_1 = -point_velocity:Dot(tangent_1) / tangent_inverse_mass_1
	local tangent_impulse_2 = -point_velocity:Dot(tangent_2) / tangent_inverse_mass_2
	local static_impulse_limit = math.max(normal_impulse, 0.05) * static_friction
	local desired_tangent_impulse_length = math.sqrt(tangent_impulse_1 * tangent_impulse_1 + tangent_impulse_2 * tangent_impulse_2)
	local use_static_friction = physics.solver:ShouldUseStaticFriction(contact, tangent_speed, desired_tangent_impulse_length, static_impulse_limit)
	local friction_limit = use_static_friction and static_friction or dynamic_friction
	local max_friction_impulse = math.max(normal_impulse, 0.05) * friction_limit

	if allow_persistent_tangent then
		local new_tangent_impulse_1 = previous_tangent_impulse_1 + tangent_impulse_1
		local new_tangent_impulse_2 = previous_tangent_impulse_2 + tangent_impulse_2
		local tangent_impulse_length = math.sqrt(
			new_tangent_impulse_1 * new_tangent_impulse_1 + new_tangent_impulse_2 * new_tangent_impulse_2
		)

		if
			tangent_impulse_length > max_friction_impulse and
			tangent_impulse_length > physics.EPSILON
		then
			local scale = max_friction_impulse / tangent_impulse_length
			new_tangent_impulse_1 = new_tangent_impulse_1 * scale
			new_tangent_impulse_2 = new_tangent_impulse_2 * scale
		end

		tangent_impulse_1 = new_tangent_impulse_1 - previous_tangent_impulse_1
		tangent_impulse_2 = new_tangent_impulse_2 - previous_tangent_impulse_2
		contact.tangent_impulse = new_tangent_impulse_1
		contact.tangent_impulse_1 = new_tangent_impulse_1
		contact.tangent_impulse_2 = new_tangent_impulse_2
		contact.static_friction_active = use_static_friction
		contact.tangent = tangent_1:Copy()
	else
		local tangent_impulse_length = math.sqrt(tangent_impulse_1 * tangent_impulse_1 + tangent_impulse_2 * tangent_impulse_2)

		if
			tangent_impulse_length > max_friction_impulse and
			tangent_impulse_length > physics.EPSILON
		then
			local scale = max_friction_impulse / tangent_impulse_length
			tangent_impulse_1 = tangent_impulse_1 * scale
			tangent_impulse_2 = tangent_impulse_2 * scale
		end

		if contact then contact.static_friction_active = use_static_friction end
	end

	if math.abs(tangent_impulse_1) > physics.EPSILON then
		body:ApplyImpulse(tangent_1 * tangent_impulse_1, point)
		applied_impulse = true
	end

	if math.abs(tangent_impulse_2) > physics.EPSILON then
		body:ApplyImpulse(tangent_2 * tangent_impulse_2, point)
		applied_impulse = true
	elseif contact and tangent_warmed then
		contact.tangent = tangent_1:Copy()
	end

	if applied_impulse then sync_body_motion_history(body, dt) end
end

local function accumulate_ground_contact(body, contact, grounded_normal, grounded_weight)
	if contact.normal.y >= body:GetMinGroundNormalY() then
		grounded_normal = (grounded_normal or physics.Up * 0) + contact.normal * contact.depth
		grounded_weight = grounded_weight + contact.depth
		body:SetGrounded(true)
	end

	physics.collision_pairs:RecordWorldCollision(body, contact.hit, contact.normal, contact.depth)
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
