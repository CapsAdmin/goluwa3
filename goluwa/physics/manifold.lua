local module = {}

function module.CreateServices(services)
	local Vec3 = services.Vec3
	local EPSILON = services.EPSILON
	local WARM_START_SCALE = services.WARM_START_SCALE
	local get_pair_restitution = services.get_pair_restitution
	local get_pair_friction = services.get_pair_friction
	local apply_impulse_to_motion = services.apply_impulse_to_motion
	local set_body_motion_from_current_state = services.set_body_motion_from_current_state
	local get_point_velocity = services.get_point_velocity

	local function copy_vec(vec)
		return Vec3(vec.x, vec.y, vec.z)
	end

	local function rebuild_contacts(body_a, body_b, manifold, contacts)
		local previous_contacts = manifold.contacts or {}
		local rebuilt = {}

		for _, contact in ipairs(contacts) do
			local local_point_a = body_a:WorldToLocal(contact.point_a)
			local local_point_b = body_b:WorldToLocal(contact.point_b)
			local matched_contact
			local best_distance = 0.25

			for _, previous in ipairs(previous_contacts) do
				local distance = (
						previous.local_point_a - local_point_a
					):GetLength() + (
						previous.local_point_b - local_point_b
					):GetLength()

				if distance < best_distance then
					best_distance = distance
					matched_contact = previous
				end
			end

			rebuilt[#rebuilt + 1] = {
				local_point_a = local_point_a,
				local_point_b = local_point_b,
				normal_impulse = matched_contact and matched_contact.normal_impulse or 0,
			}
		end

		manifold.contacts = rebuilt
		return rebuilt
	end

	local function warm_start(body_a, body_b, normal, manifold, dt)
		local velocity_a = copy_vec(body_a:GetVelocity())
		local velocity_b = copy_vec(body_b:GetVelocity())
		local angular_velocity_a = copy_vec(body_a:GetAngularVelocity())
		local angular_velocity_b = copy_vec(body_b:GetAngularVelocity())
		local did_apply = false

		for _, contact in ipairs(manifold.contacts or {}) do
			local normal_impulse = math.max(contact.normal_impulse or 0, 0) * WARM_START_SCALE

			if normal_impulse > EPSILON then
				local point_a = body_a:LocalToWorld(contact.local_point_a)
				local point_b = body_b:LocalToWorld(contact.local_point_b)
				local impulse = normal * normal_impulse
				velocity_a, angular_velocity_a = apply_impulse_to_motion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
				velocity_b, angular_velocity_b = apply_impulse_to_motion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
				did_apply = true
			end
		end

		if did_apply then
			set_body_motion_from_current_state(body_a, velocity_a, angular_velocity_a, dt)
			set_body_motion_from_current_state(body_b, velocity_b, angular_velocity_b, dt)
		end
	end

	local function solve_impulses(body_a, body_b, normal, manifold, dt)
		local velocity_a = copy_vec(body_a:GetVelocity())
		local velocity_b = copy_vec(body_b:GetVelocity())
		local angular_velocity_a = copy_vec(body_a:GetAngularVelocity())
		local angular_velocity_b = copy_vec(body_b:GetAngularVelocity())
		local restitution = get_pair_restitution(body_a, body_b)
		local friction = get_pair_friction(body_a, body_b)

		for _, contact in ipairs(manifold.contacts or {}) do
			local point_a = body_a:LocalToWorld(contact.local_point_a)
			local point_b = body_b:LocalToWorld(contact.local_point_b)
			local relative_velocity = get_point_velocity(body_b, velocity_b, angular_velocity_b, point_b) - get_point_velocity(body_a, velocity_a, angular_velocity_a, point_a)
			local normal_speed = relative_velocity:Dot(normal)
			local inverse_mass = body_a:GetInverseMassAlong(normal, point_a) + body_b:GetInverseMassAlong(normal, point_b)

			if inverse_mass > EPSILON then
				local applied_restitution = normal_speed < -1 and restitution or 0
				local normal_impulse = -(1 + applied_restitution) * normal_speed / inverse_mass
				local new_impulse = math.max((contact.normal_impulse or 0) + normal_impulse, 0)
				local impulse_delta = new_impulse - (contact.normal_impulse or 0)
				contact.normal_impulse = new_impulse

				if math.abs(impulse_delta) > EPSILON then
					local impulse = normal * impulse_delta
					velocity_a, angular_velocity_a = apply_impulse_to_motion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
					velocity_b, angular_velocity_b = apply_impulse_to_motion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
				end
			end

			relative_velocity = get_point_velocity(body_b, velocity_b, angular_velocity_b, point_b) - get_point_velocity(body_a, velocity_a, angular_velocity_a, point_a)
			local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)
			local tangent_speed = tangent_velocity:GetLength()

			if tangent_speed > EPSILON and friction > 0 then
				local tangent = tangent_velocity / tangent_speed
				local tangent_inverse_mass = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)

				if tangent_inverse_mass > EPSILON then
					local tangent_impulse = -relative_velocity:Dot(tangent) / tangent_inverse_mass
					local max_tangent_impulse = (contact.normal_impulse or 0) * friction
					tangent_impulse = math.max(-max_tangent_impulse, math.min(max_tangent_impulse, tangent_impulse))

					if math.abs(tangent_impulse) > EPSILON then
						local impulse = tangent * tangent_impulse
						velocity_a, angular_velocity_a = apply_impulse_to_motion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
						velocity_b, angular_velocity_b = apply_impulse_to_motion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
					end
				end
			end
		end

		set_body_motion_from_current_state(body_a, velocity_a, angular_velocity_a, dt)
		set_body_motion_from_current_state(body_b, velocity_b, angular_velocity_b, dt)
	end

	local function prune_old(manifolds, step_stamp, prune_steps)
		for key, manifold in pairs(manifolds or {}) do
			if not manifold.last_seen_step or manifold.last_seen_step < step_stamp - prune_steps then
				manifolds[key] = nil
			end
		end
	end

	return {
		RebuildContacts = rebuild_contacts,
		WarmStart = warm_start,
		SolveImpulses = solve_impulses,
		PruneOld = prune_old,
	}
end

return module