local module = {}

function module.CreateServices(services)
	local Quat = services.Quat
	local Vec3 = services.Vec3
	local physics = services.physics
	local EPSILON = services.EPSILON
	local get_pair_restitution = services.get_pair_restitution
	local get_pair_friction = services.get_pair_friction
	local get_pair_rolling_friction = services.get_pair_rolling_friction
	local get_persistent_manifolds = services.get_persistent_manifolds
	local get_step_stamp = services.get_step_stamp
	local get_manifolds = services.get_manifolds

	local function integrate_rotation(rotation, angular_velocity, dt)
		if angular_velocity:GetLength() == 0 then return rotation:Copy() end

		local delta = Quat(angular_velocity.x, angular_velocity.y, angular_velocity.z, 0) * rotation
		return Quat(
			rotation.x + 0.5 * dt * delta.x,
			rotation.y + 0.5 * dt * delta.y,
			rotation.z + 0.5 * dt * delta.z,
			rotation.w + 0.5 * dt * delta.w
		):GetNormalized()
	end

	local function shift_body_position(body, delta)
		if
			body.HasSolverMass and
			body:HasSolverMass() and
			delta:GetLength() > 0.01 and
			body.Wake
		then
			body:Wake()
		end

		body.Position = body.Position + delta
		body.PreviousPosition = body.PreviousPosition + delta
	end

	local function set_body_velocity_from_current_position(body, velocity, dt)
		body:SetVelocity(velocity)
		body.PreviousPosition = body.Position - velocity * dt
	end

	local function set_body_angular_velocity_from_current_rotation(body, angular_velocity, dt)
		if body.IsSolverImmovable and body:IsSolverImmovable() then return end

		body.AngularVelocity = angular_velocity:Copy()
		body.PreviousRotation = integrate_rotation(body.Rotation, angular_velocity, -dt)
	end

	local function set_body_motion_from_current_state(body, linear_velocity, angular_velocity, dt)
		if body.IsSolverImmovable and body:IsSolverImmovable() then return end

		set_body_velocity_from_current_position(body, linear_velocity, dt)
		set_body_angular_velocity_from_current_rotation(body, angular_velocity, dt)
	end

	local function mark_pair_grounding(body_a, body_b, normal)
		local rolling_friction = get_pair_rolling_friction(body_a, body_b)

		if -normal.y >= body_a.MinGroundNormalY then
			body_a:SetGrounded(true)
			body_a:SetGroundNormal(-normal)
			body_a:SetGroundRollingFriction(rolling_friction)
		end

		if normal.y >= body_b.MinGroundNormalY then
			body_b:SetGrounded(true)
			body_b:SetGroundNormal(normal)
			body_b:SetGroundRollingFriction(rolling_friction)
		end
	end

	local function try_mark_body_grounded_from_contacts(self_body, other_body, contacts, self_key, other_key)
		if self_body:GetGrounded() then return end

		local rolling_friction = get_pair_rolling_friction(self_body, other_body)
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

					if candidate:GetLength() <= EPSILON then
						candidate = self_body:GetPosition() - other_body:GetPosition()
					end

					if other_body:GetPosition().y <= self_body:GetPosition().y then
						self_body:SetGrounded(true)
						self_body:SetGroundNormal(physics.Up)
						self_body:SetGroundRollingFriction(rolling_friction)
						return
					end

					if candidate:GetLength() > EPSILON then
						candidate = candidate:GetNormalized()

						if candidate.y >= self_body.MinGroundNormalY then
							self_body:SetGrounded(true)
							self_body:SetGroundNormal(candidate)
							self_body:SetGroundRollingFriction(rolling_friction)
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

	local function get_pair_cache_key(body_a, body_b)
		return tostring(body_a) .. "|" .. tostring(body_b)
	end

	local function get_point_velocity(body, linear_velocity, angular_velocity, point)
		if not point then return linear_velocity end

		return linear_velocity + angular_velocity:GetCross(point - body:GetPosition())
	end

	local function apply_impulse_to_motion(body, linear_velocity, angular_velocity, impulse, point)
		if body.IsSolverImmovable and body:IsSolverImmovable() then
			return linear_velocity, angular_velocity
		end

		linear_velocity = linear_velocity + impulse * body.InverseMass

		if point then
			angular_velocity = angular_velocity + body:GetAngularVelocityDelta((point - body:GetPosition()):GetCross(impulse))
		end

		return linear_velocity, angular_velocity
	end

	local function apply_pair_impulse(body_a, body_b, normal, dt, point_a, point_b)
		local inverse_mass_a = body_a.InverseMass
		local inverse_mass_b = body_b.InverseMass
		local inverse_mass_sum = inverse_mass_a + inverse_mass_b

		if inverse_mass_sum <= 0 then return end

		local velocity_a = body_a:GetVelocity()
		local velocity_b = body_b:GetVelocity()
		local angular_velocity_a = body_a:GetAngularVelocity()
		local angular_velocity_b = body_b:GetAngularVelocity()
		local relative_velocity = velocity_b - velocity_a
		local normal_speed = relative_velocity:Dot(normal)

		if normal_speed >= 0 then return end

		local restitution = get_pair_restitution(body_a, body_b)
		local normal_impulse = -(1 + restitution) * normal_speed / inverse_mass_sum

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

		relative_velocity = velocity_b - velocity_a
		local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)
		local tangent_speed = tangent_velocity:GetLength()

		if tangent_speed > EPSILON then
			local tangent = tangent_velocity / tangent_speed
			local friction = get_pair_friction(body_a, body_b)
			local tangent_impulse = -relative_velocity:Dot(tangent) / inverse_mass_sum
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
			set_body_velocity_from_current_position(body_a, velocity_a, dt)
			set_body_angular_velocity_from_current_rotation(body_a, angular_velocity_a, dt)
		end

		if inverse_mass_b > 0 then
			set_body_velocity_from_current_position(body_b, velocity_b, dt)
			set_body_angular_velocity_from_current_rotation(body_b, angular_velocity_b, dt)
		end
	end

	local function resolve_pair_penetration(body_a, body_b, normal, overlap, dt, point_a, point_b, contacts)
		local inverse_mass_a = body_a.InverseMass
		local inverse_mass_b = body_b.InverseMass
		local inverse_mass_sum = inverse_mass_a + inverse_mass_b

		if inverse_mass_sum <= 0 or overlap <= 0 then return false end

		if contacts and #contacts > 0 then
			local persistent_manifolds = get_persistent_manifolds()
			local manifold_ops = get_manifolds()
			local key = get_pair_cache_key(body_a, body_b)
			local manifold = persistent_manifolds[key] or {}
			manifold.last_seen_step = get_step_stamp()
			manifold_ops.RebuildContacts(body_a, body_b, manifold, contacts)
			persistent_manifolds[key] = manifold

			if manifold.last_warm_step ~= get_step_stamp() then
				manifold_ops.WarmStart(body_a, body_b, normal, manifold, dt)
				manifold.last_warm_step = get_step_stamp()
			end

			local correction = normal * (-overlap / #contacts)

			for _, contact in ipairs(contacts) do
				body_a:ApplyCorrection(0, correction, contact.point_a, body_b, contact.point_b, dt)
			end

			manifold_ops.SolveImpulses(body_a, body_b, normal, manifold, dt)
			mark_pair_grounding(body_a, body_b, normal)
			mark_pair_grounding_from_contacts(body_a, body_b, contacts)

			if physics.RecordCollisionPair then
				physics.RecordCollisionPair(body_a, body_b, normal, overlap)
			end

			return true
		end

		local correction = normal * overlap

		if inverse_mass_a > 0 then
			shift_body_position(body_a, correction * -(inverse_mass_a / inverse_mass_sum))
		end

		if inverse_mass_b > 0 then
			shift_body_position(body_b, correction * (inverse_mass_b / inverse_mass_sum))
		end

		apply_pair_impulse(body_a, body_b, normal, dt, point_a, point_b)
		mark_pair_grounding(body_a, body_b, normal)

		if physics.RecordCollisionPair then
			physics.RecordCollisionPair(body_a, body_b, normal, overlap)
		end

		return true
	end

	return {
		GetPointVelocity = get_point_velocity,
		ApplyImpulseToMotion = apply_impulse_to_motion,
		SetBodyMotionFromCurrentState = set_body_motion_from_current_state,
		ResolvePairPenetration = resolve_pair_penetration,
		ApplyPairImpulse = apply_pair_impulse,
		MarkPairGrounding = mark_pair_grounding,
	}
end

return module