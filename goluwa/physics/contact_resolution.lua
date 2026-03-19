local physics = import("goluwa/physics.lua")
local manifolds = import("goluwa/physics/manifold.lua")
local motion = import("goluwa/physics/motion.lua")
local contact_resolution = {}

function contact_resolution.MarkPairGrounding(body_a, body_b, normal)
	local rolling_friction = physics.solver:GetPairRollingFriction(body_a, body_b)

	if -normal.y >= body_a:GetMinGroundNormalY() then
		body_a:SetGrounded(true)
		body_a:SetGroundNormal(-normal)
		body_a:SetGroundRollingFriction(rolling_friction)
		body_a:SetGroundBody(body_b)
		body_a:SetGroundEntity(body_b.GetOwner and body_b:GetOwner() or nil)
	end

	if normal.y >= body_b:GetMinGroundNormalY() then
		body_b:SetGrounded(true)
		body_b:SetGroundNormal(normal)
		body_b:SetGroundRollingFriction(rolling_friction)
		body_b:SetGroundBody(body_a)
		body_b:SetGroundEntity(body_a.GetOwner and body_a:GetOwner() or nil)
	end
end

local function try_mark_body_grounded_from_contacts(self_body, other_body, contacts, self_key, other_key)
	if self_body:GetGrounded() then return end

	local rolling_friction = physics.solver:GetPairRollingFriction(self_body, other_body)
	local self_half = self_body:GetHalfExtents()
	local other_half = other_body:GetHalfExtents()
	local self_threshold = self_half.y * 0.25
	local other_threshold = other_half.y * 0.25

	for _, contact in ipairs(contacts or {}) do
		local self_point = contact[self_key]
		local other_point = contact[other_key]

		if self_point and other_point then
			local self_offset = self_point - self_body:GetPosition()
			local other_offset = other_point - other_body:GetPosition()

			if self_offset.y <= -self_threshold and other_offset.y >= other_threshold then
				local candidate = self_point - other_point

				if candidate:GetLength() <= physics.EPSILON then
					candidate = self_body:GetPosition() - other_body:GetPosition()
				end

				if other_body:GetPosition().y <= self_body:GetPosition().y then
					self_body:SetGrounded(true)
					self_body:SetGroundNormal(physics.Up)
					self_body:SetGroundRollingFriction(rolling_friction)
					self_body:SetGroundBody(other_body)
					self_body:SetGroundEntity(other_body.GetOwner and other_body:GetOwner() or nil)
					return
				end

				if candidate:GetLength() > physics.EPSILON then
					candidate = candidate:GetNormalized()

					if candidate.y >= self_body:GetMinGroundNormalY() then
						self_body:SetGrounded(true)
						self_body:SetGroundNormal(candidate)
						self_body:SetGroundRollingFriction(rolling_friction)
						self_body:SetGroundBody(other_body)
						self_body:SetGroundEntity(other_body.GetOwner and other_body:GetOwner() or nil)
						return
					end
				end
			end
		end
	end
end

local function mark_pair_grounding_from_contacts(body_a, body_b, contacts)
	try_mark_body_grounded_from_contacts(body_a, body_b, contacts, "point_a", "point_b")
	try_mark_body_grounded_from_contacts(body_b, body_a, contacts, "point_b", "point_a")
end

local function get_or_create_manifold_row(manifolds, body)
	local row = manifolds[body]

	if row then return row end

	row = setmetatable({}, {__mode = "k"})
	manifolds[body] = row
	return row
end

local function get_pair_manifold(manifolds, body_a, body_b)
	local row = manifolds[body_a]
	return row and row[body_b] or nil
end

local function set_pair_manifold(manifolds, body_a, body_b, manifold)
	get_or_create_manifold_row(manifolds, body_a)[body_b] = manifold
	get_or_create_manifold_row(manifolds, body_b)[body_a] = manifold
end

function contact_resolution.ApplyPairImpulse(body_a, body_b, normal, dt, point_a, point_b, options)
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b
	options = options or {}

	if inverse_mass_sum <= 0 then return end

	local velocity_a = body_a:GetVelocity()
	local velocity_b = body_b:GetVelocity()
	local angular_velocity_a = body_a:GetAngularVelocity()
	local angular_velocity_b = body_b:GetAngularVelocity()
	local relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
	local normal_speed = relative_velocity:Dot(normal)

	if normal_speed >= 0 then return end

	local restitution = physics.solver:GetPairRestitution(body_a, body_b)
	local normal_inverse_mass = inverse_mass_sum

	if point_a or point_b then
		normal_inverse_mass = body_a:GetInverseMassAlong(normal, point_a) + body_b:GetInverseMassAlong(normal, point_b)
	end

	if normal_inverse_mass <= physics.EPSILON then return end

	local normal_impulse = -(1 + restitution) * normal_speed / normal_inverse_mass

	if inverse_mass_a > 0 then
		velocity_a = velocity_a - normal * (normal_impulse * inverse_mass_a)

		if point_a then
			angular_velocity_a = angular_velocity_a + body_a:GetAngularVelocityDelta((point_a - body_a:GetPosition()):GetCross(normal * -normal_impulse))
		end
	end

	if inverse_mass_b > 0 then
		velocity_b = velocity_b + normal * (normal_impulse * inverse_mass_b)

		if point_b then
			angular_velocity_b = angular_velocity_b + body_b:GetAngularVelocityDelta((point_b - body_b:GetPosition()):GetCross(normal * normal_impulse))
		end
	end

	relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
	local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed > physics.EPSILON and not options.skip_friction then
		local tangent = tangent_velocity / tangent_speed
		local friction = physics.solver:GetPairFriction(body_a, body_b)
		local tangent_inverse_mass = inverse_mass_sum

		if point_a or point_b then
			tangent_inverse_mass = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)
		end

		if tangent_inverse_mass <= physics.EPSILON then
			tangent_inverse_mass = inverse_mass_sum
		end

		local tangent_impulse = -relative_velocity:Dot(tangent) / tangent_inverse_mass
		local max_friction_impulse = normal_impulse * friction
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))

		if inverse_mass_a > 0 then
			velocity_a = velocity_a - tangent * (tangent_impulse * inverse_mass_a)

			if point_a then
				angular_velocity_a = angular_velocity_a + body_a:GetAngularVelocityDelta((point_a - body_a:GetPosition()):GetCross(tangent * -tangent_impulse))
			end
		end

		if inverse_mass_b > 0 then
			velocity_b = velocity_b + tangent * (tangent_impulse * inverse_mass_b)

			if point_b then
				angular_velocity_b = angular_velocity_b + body_b:GetAngularVelocityDelta((point_b - body_b:GetPosition()):GetCross(tangent * tangent_impulse))
			end
		end
	end

	if inverse_mass_a > 0 then
		motion.SetBodyVelocityFromCurrentPosition(body_a, velocity_a, dt)
		motion.SetBodyAngularVelocityFromCurrentRotation(body_a, angular_velocity_a, dt)
	end

	if inverse_mass_b > 0 then
		motion.SetBodyVelocityFromCurrentPosition(body_b, velocity_b, dt)
		motion.SetBodyAngularVelocityFromCurrentRotation(body_b, angular_velocity_b, dt)
	end
end

function contact_resolution.ResolvePairPenetration(body_a, body_b, normal, overlap, dt, point_a, point_b, contacts, options)
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b
	options = options or {}

	if inverse_mass_sum <= 0 or overlap <= 0 then return false end

	if contacts and #contacts > 0 then
		local solver = physics.solver
		local manifold = get_pair_manifold(solver.PersistentManifolds, body_a, body_b) or {}
		manifold.last_seen_step = solver.StepStamp
		manifolds.RebuildContacts(body_a, body_b, manifold, contacts)
		set_pair_manifold(solver.PersistentManifolds, body_a, body_b, manifold)

		if manifold.last_warm_step ~= solver.StepStamp then
			manifolds.WarmStart(body_a, body_b, normal, manifold, dt)
			manifold.last_warm_step = solver.StepStamp
		end

		manifolds.SolveImpulses(body_a, body_b, normal, manifold, dt)
		local correction = normal * (-overlap / #contacts)

		for _, contact in ipairs(contacts) do
			body_a:ApplyCorrection(0, correction, contact.point_a, body_b, contact.point_b, dt)
		end

		if not options.skip_grounding then
			contact_resolution.MarkPairGrounding(body_a, body_b, normal)
			mark_pair_grounding_from_contacts(body_a, body_b, contacts)
		end

		physics.collision_pairs:RecordCollisionPair(body_a, body_b, normal, overlap)
		return true
	end

	contact_resolution.ApplyPairImpulse(body_a, body_b, normal, dt, point_a, point_b, options)
	local correction = normal * overlap

	if inverse_mass_a > 0 then
		motion.ShiftBodyPosition(body_a, correction * -(inverse_mass_a / inverse_mass_sum))
	end

	if inverse_mass_b > 0 then
		motion.ShiftBodyPosition(body_b, correction * (inverse_mass_b / inverse_mass_sum))
	end

	if not options.skip_grounding then
		contact_resolution.MarkPairGrounding(body_a, body_b, normal)
	end

	physics.collision_pairs:RecordCollisionPair(body_a, body_b, normal, overlap)
	return true
end

return contact_resolution
