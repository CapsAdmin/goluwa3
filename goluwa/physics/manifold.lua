local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local motion = import("goluwa/physics/motion.lua")
local manifold = {}
local EPSILON = solver.EPSILON or 0.00001
local WARM_START_SCALE = solver.WARM_START_SCALE or 0.9

local function copy_vec(vec)
	return Vec3(vec.x, vec.y, vec.z)
end

function manifold.RebuildContacts(body_a, body_b, manifold_data, contacts)
	local previous_contacts = manifold_data.contacts or {}
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

	manifold_data.contacts = rebuilt
	return rebuilt
end

function manifold.WarmStart(body_a, body_b, normal, manifold_data, dt)
	local velocity_a = copy_vec(body_a:GetVelocity())
	local velocity_b = copy_vec(body_b:GetVelocity())
	local angular_velocity_a = copy_vec(body_a:GetAngularVelocity())
	local angular_velocity_b = copy_vec(body_b:GetAngularVelocity())
	local did_apply = false

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local normal_impulse = math.max(contact.normal_impulse or 0, 0) * WARM_START_SCALE

		if normal_impulse > EPSILON then
			local point_a = body_a:LocalToWorld(contact.local_point_a)
			local point_b = body_b:LocalToWorld(contact.local_point_b)
			local impulse = normal * normal_impulse
			velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
			velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
			did_apply = true
		end
	end

	if did_apply then
		motion.SetBodyMotionFromCurrentState(body_a, velocity_a, angular_velocity_a, dt)
		motion.SetBodyMotionFromCurrentState(body_b, velocity_b, angular_velocity_b, dt)
	end
end

function manifold.SolveImpulses(body_a, body_b, normal, manifold_data, dt)
	local velocity_a = copy_vec(body_a:GetVelocity())
	local velocity_b = copy_vec(body_b:GetVelocity())
	local angular_velocity_a = copy_vec(body_a:GetAngularVelocity())
	local angular_velocity_b = copy_vec(body_b:GetAngularVelocity())
	local restitution = solver.GetPairRestitution(body_a, body_b)
	local friction = solver.GetPairFriction(body_a, body_b)

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b)
		local relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
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
				velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
				velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
			end
		end

		relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
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
					velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
					velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
				end
			end
		end
	end

	motion.SetBodyMotionFromCurrentState(body_a, velocity_a, angular_velocity_a, dt)
	motion.SetBodyMotionFromCurrentState(body_b, velocity_b, angular_velocity_b, dt)
end

function manifold.PruneOld(manifolds, step_stamp, prune_steps)
	for key, manifold in pairs(manifolds or {}) do
		if not manifold.last_seen_step or manifold.last_seen_step < step_stamp - prune_steps then
			manifolds[key] = nil
		end
	end
end

return manifold