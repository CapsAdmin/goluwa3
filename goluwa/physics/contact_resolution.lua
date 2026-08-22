local physics_constants = import("goluwa/physics/constants.lua")
local impulse_motion = import("goluwa/physics/impulse_motion.lua")
local manifolds = import("goluwa/physics/manifold.lua")
local motion = import("goluwa/physics/motion.lua")
local stats = import("goluwa/physics/stats.lua")
local contact_resolution = {}
local Vec3 = import("goluwa/structs/vec3.lua")
local EPSILON = physics_constants.EPSILON
local TANGENT_VELOCITY = Vec3()
local TANGENT = Vec3()
local CORRECTION = Vec3()
local CORRECTION_SHIFT = Vec3()
local GROUND_OFFSET_A = Vec3()
local GROUND_OFFSET_B = Vec3()
local GROUND_CANDIDATE = Vec3()

function contact_resolution.MarkPairGrounding(body_a, body_b, normal)
	local physics = body_a:GetPhysics()
	local rolling_friction = physics.solver:GetPairRollingFriction(body_a, body_b)

	if -normal.y >= body_a:GetMinGroundNormalY() then
		body_a:SetGrounded(true)
		body_a:SetGroundNormal(-normal)
		body_a:SetGroundRollingFriction(rolling_friction)
		body_a:SetGroundBody(body_b)
		body_a:SetGroundEntity(body_b:GetOwner())
	end

	if normal.y >= body_b:GetMinGroundNormalY() then
		body_b:SetGrounded(true)
		body_b:SetGroundNormal(normal)
		body_b:SetGroundRollingFriction(rolling_friction)
		body_b:SetGroundBody(body_a)
		body_b:SetGroundEntity(body_a:GetOwner())
	end
end

local function accumulate_pair_ground_support(body_a, body_b, normal, point_a, point_b)
	if body_a:GetGrounded() and -normal.y >= body_a:GetMinGroundNormalY() then
		body_a:AccumulateGroundSupportContact(body_a.GroundNormal, point_a)
	end

	if body_b:GetGrounded() and normal.y >= body_b:GetMinGroundNormalY() then
		body_b:AccumulateGroundSupportContact(body_b.GroundNormal, point_b)
	end
end

local function try_mark_body_grounded_from_contacts(self_body, other_body, contacts, self_key, other_key)
	if self_body:GetGrounded() then return end

	local physics = self_body:GetPhysics()
	local rolling_friction = physics.solver:GetPairRollingFriction(self_body, other_body)
	local self_half = self_body:GetHalfExtents()
	local other_half = other_body:GetHalfExtents()
	local self_threshold = self_half.y * 0.25
	local other_threshold = other_half.y * 0.25

	for _, contact in ipairs(contacts or {}) do
		local self_point = contact[self_key]
		local other_point = contact[other_key]

		if self_point and other_point then
			local self_offset = Vec3.SetSub(GROUND_OFFSET_A, self_point, self_body:GetPosition())
			local other_offset = Vec3.SetSub(GROUND_OFFSET_B, other_point, other_body:GetPosition())

			if self_offset.y <= -self_threshold and other_offset.y >= other_threshold then
				local candidate = Vec3.SetSub(GROUND_CANDIDATE, self_point, other_point)

				if candidate:GetLength() <= EPSILON then
					Vec3.SetSub(GROUND_CANDIDATE, self_body:GetPosition(), other_body:GetPosition())
				end

				if other_body:GetPosition().y <= self_body:GetPosition().y then
					self_body:SetGrounded(true)
					self_body:SetGroundNormal(physics_constants.UP)
					self_body:SetGroundRollingFriction(rolling_friction)
					self_body:SetGroundBody(other_body)
					self_body:SetGroundEntity(other_body:GetOwner())
					return
				end

				if candidate:GetLength() > EPSILON then
					candidate:Normalize()

					if candidate.y >= self_body:GetMinGroundNormalY() then
						self_body:SetGrounded(true)
						self_body:SetGroundNormal(candidate)
						self_body:SetGroundRollingFriction(rolling_friction)
						self_body:SetGroundBody(other_body)
						self_body:SetGroundEntity(other_body:GetOwner())
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

	row = table.weak("k")
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

local function get_contact_separation_tolerance(solver)
	return math.max(solver.PENETRATION_SLOP or 0, 0.005) * 4
end

local function pair_breaks_lifted_support(solver, body_a, body_b)
	local velocity_a = body_a.Velocity
	local velocity_b = body_b.Velocity
	local speed_a = velocity_a and velocity_a:GetLength() or 0
	local speed_b = velocity_b and velocity_b:GetLength() or 0
	return math.max(speed_a, speed_b) <= (solver.LIFT_BREAK_SPEED or 0.5)
end

local function get_positional_correction_length(solver, overlap, dt)
	local slop = math.max(solver.PENETRATION_SLOP or 0, 0)
	local factor = math.max(solver.POSITIONAL_CORRECTION_FACTOR or 0, 0)
	local max_correction = math.max(solver.MAX_POSITIONAL_CORRECTION or 0, 0)
	local correction_length = math.max(overlap - slop, 0) * factor

	if dt and dt > 0 then
		local max_depenetration_speed = math.max(solver.MAX_DEPENETRATION_SPEED or 0, 0)

		if max_depenetration_speed > 0 then
			correction_length = math.min(correction_length, max_depenetration_speed * dt)
		end
	end

	if max_correction > 0 then
		correction_length = math.min(correction_length, max_correction)
	end

	return correction_length
end

local EMPTY_OPTIONS = {}

function contact_resolution.ApplyPairImpulse(body_a, body_b, normal, dt, point_a, point_b, options)
	local physics = body_a:GetPhysics()
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b
	options = options or EMPTY_OPTIONS

	if inverse_mass_sum <= 0 then return end

	local state_a, state_b = impulse_motion.CapturePairMotion(body_a, body_b)
	local relative_velocity = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
	local normal_speed = relative_velocity:Dot(normal)

	if normal_speed >= 0 then return end

	local restitution = physics.solver:GetPairRestitution(body_a, body_b)
	local normal_inverse_mass = inverse_mass_sum

	if point_a or point_b then
		normal_inverse_mass = body_a:GetInverseMassAlong(normal, point_a) + body_b:GetInverseMassAlong(normal, point_b)
	end

	if normal_inverse_mass <= EPSILON then return end

	local normal_impulse = -(1 + restitution) * normal_speed / normal_inverse_mass
	impulse_motion.ApplyPairImpulse(state_a, state_b, normal, normal_impulse, point_a, point_b)
	relative_velocity = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
	local normal_dot = relative_velocity:Dot(normal)
	local tangent_velocity = TANGENT_VELOCITY:CopyFrom(relative_velocity):AddScaled(normal, -normal_dot)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed > EPSILON and not options.skip_friction then
		local tangent = TANGENT:CopyFrom(tangent_velocity):Scale(1 / tangent_speed)
		local friction = physics.solver:GetPairFriction(body_a, body_b)
		local friction_scale = options.friction_scale

		if friction_scale ~= nil then
			friction = friction * math.max(friction_scale, 0)
		end

		local tangent_inverse_mass = inverse_mass_sum

		if point_a or point_b then
			tangent_inverse_mass = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)
		end

		if tangent_inverse_mass <= EPSILON then
			tangent_inverse_mass = inverse_mass_sum
		end

		local tangent_impulse = -relative_velocity:Dot(tangent) / tangent_inverse_mass
		local max_friction_impulse = normal_impulse * friction
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))
		impulse_motion.ApplyPairImpulse(state_a, state_b, tangent, tangent_impulse, point_a, point_b)
	end

	impulse_motion.CommitPairMotion(state_a, state_b, dt)
end

function contact_resolution.ResolvePairPenetration(body_a, body_b, normal, overlap, dt, point_a, point_b, contacts, options)
	local physics = body_a:GetPhysics()
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b
	options = options or EMPTY_OPTIONS

	if inverse_mass_sum <= 0 or overlap <= 0 then return false end

	if contacts and #contacts > 0 then
		local solver = physics.solver
		local manifold = get_pair_manifold(solver.PersistentManifolds, body_a, body_b) or {}
		manifold.last_seen_step = solver.StepStamp

		-- the pair handler runs once per solver iteration but the manifold only
		-- needs rebuilding once per substep; the contacts are identical between
		-- iterations of the same substep
		if manifold.last_rebuild_step ~= solver.StepStamp then
			manifolds.RebuildContacts(body_a, body_b, manifold, contacts)
			manifold.last_rebuild_step = solver.StepStamp
			stats:Count("contact_points", #contacts)
		end

		set_pair_manifold(solver.PersistentManifolds, body_a, body_b, manifold)

		if manifold.last_warm_step ~= solver.StepStamp then
			manifolds.WarmStart(body_a, body_b, normal, manifold, dt)
			manifold.last_warm_step = solver.StepStamp
		end

		manifolds.SolveImpulses(body_a, body_b, normal, manifold, dt)
		local correction_length = get_positional_correction_length(solver, overlap, dt)

		if correction_length > EPSILON then
			local lifts_broken = pair_breaks_lifted_support(solver, body_a, body_b)
			local separation_tolerance = lifts_broken and get_contact_separation_tolerance(solver) or math.huge
			local active_count = 0

			for _, contact in ipairs(contacts) do
				if (contact.separation or 0) <= separation_tolerance then
					active_count = active_count + 1
				end
			end

			if active_count == 0 then active_count = #contacts end

			local correction = CORRECTION:CopyFrom(normal):Scale(-(correction_length / active_count))

			for _, contact in ipairs(contacts) do
				if (contact.separation or 0) <= separation_tolerance then
					body_a:ApplyCorrection(0, correction, contact.point_a, body_b, contact.point_b, dt)
				end
			end
		end

		if not options.skip_grounding then
			contact_resolution.MarkPairGrounding(body_a, body_b, normal)
			mark_pair_grounding_from_contacts(body_a, body_b, contacts)

			for _, contact in ipairs(contacts) do
				accumulate_pair_ground_support(body_a, body_b, normal, contact.point_a, contact.point_b)
			end
		end

		physics.collision_pairs:RecordCollisionPair(body_a, body_b, normal, overlap)
		return true
	end

	contact_resolution.ApplyPairImpulse(body_a, body_b, normal, dt, point_a, point_b, options)
	local correction = CORRECTION:CopyFrom(normal):Scale(overlap)

	if inverse_mass_a > 0 then
		motion.ShiftBodyPosition(
			body_a,
			CORRECTION_SHIFT:CopyFrom(correction):Scale(-(inverse_mass_a / inverse_mass_sum))
		)
	end

	if inverse_mass_b > 0 then
		motion.ShiftBodyPosition(
			body_b,
			CORRECTION_SHIFT:CopyFrom(correction):Scale(inverse_mass_b / inverse_mass_sum)
		)
	end

	if not options.skip_grounding then
		contact_resolution.MarkPairGrounding(body_a, body_b, normal)
		accumulate_pair_ground_support(body_a, body_b, normal, point_a, point_b)
	end

	physics.collision_pairs:RecordCollisionPair(body_a, body_b, normal, overlap)
	return true
end

return contact_resolution
