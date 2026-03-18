local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local motion = import("goluwa/physics/motion.lua")
local manifold = {}

local WARM_START_SCALE = solver.WARM_START_SCALE or 0.9
local TANGENT_WARM_START_SCALE = solver.TANGENT_WARM_START_SCALE or 0.1
local MAX_TANGENT_WARM_SPEED = solver.MAX_TANGENT_WARM_SPEED or 0.25

local function copy_vec(vec)
	return Vec3(vec.x, vec.y, vec.z)
end

local function get_cached_tangent(contact, normal)
	local tangent = contact.tangent

	if not tangent then return nil end

	tangent = tangent - normal * tangent:Dot(normal)

	if tangent:GetLength() <= physics.EPSILON then return nil end

	return tangent:GetNormalized()
end

local function supports_persistent_tangent(body_a, body_b, manifold_data)
	if #(manifold_data.contacts or {}) ~= 1 then return false end

	local shape_a = body_a.GetShapeType and body_a:GetShapeType() or nil
	local shape_b = body_b.GetShapeType and body_b:GetShapeType() or nil

	if not (shape_a or shape_b) then return true end

	return shape_a == "sphere" or
		shape_a == "capsule" or
		shape_b == "sphere" or
		shape_b == "capsule"
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
			tangent_impulse = matched_contact and matched_contact.tangent_impulse or 0,
			tangent = matched_contact and
				matched_contact.tangent and
				copy_vec(matched_contact.tangent) or
				nil,
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
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b)
		local normal_impulse = math.max(contact.normal_impulse or 0, 0) * WARM_START_SCALE
		local tangent_impulse = (contact.tangent_impulse or 0) * TANGENT_WARM_START_SCALE
		local tangent = get_cached_tangent(contact, normal)

		if normal_impulse > physics.EPSILON then
			local impulse = normal * normal_impulse
			velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
			velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
			did_apply = true
		end

		if allow_persistent_tangent and tangent and math.abs(tangent_impulse) > physics.EPSILON then
			local relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
			local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)

			if tangent_velocity:GetLength() <= MAX_TANGENT_WARM_SPEED then
				local impulse = tangent * tangent_impulse
				velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
				velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
				did_apply = true
			end
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
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b)
		local relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
		local normal_speed = relative_velocity:Dot(normal)
		local inverse_mass = body_a:GetInverseMassAlong(normal, point_a) + body_b:GetInverseMassAlong(normal, point_b)

		if inverse_mass > physics.EPSILON then
			local applied_restitution = normal_speed < -0.33 and restitution or 0
			local normal_impulse = -(1 + applied_restitution) * normal_speed / inverse_mass
			local new_impulse = math.max((contact.normal_impulse or 0) + normal_impulse, 0)
			local impulse_delta = new_impulse - (contact.normal_impulse or 0)
			contact.normal_impulse = new_impulse

			if math.abs(impulse_delta) > physics.EPSILON then
				local impulse = normal * impulse_delta
				velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
				velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
			end
		end

		relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
		local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)
		local tangent_speed = tangent_velocity:GetLength()

		if tangent_speed > physics.EPSILON and friction > 0 then
			local tangent = get_cached_tangent(contact, normal)

			if not tangent or not allow_persistent_tangent then
				tangent = tangent_velocity / tangent_speed
			end

			local tangent_inverse_mass = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)

			if tangent_inverse_mass > physics.EPSILON then
				local tangent_impulse = -relative_velocity:Dot(tangent) / tangent_inverse_mass
				local max_tangent_impulse = (contact.normal_impulse or 0) * friction
				local previous_tangent_impulse = allow_persistent_tangent and (contact.tangent_impulse or 0) or 0
				local new_tangent_impulse = math.max(
					-max_tangent_impulse,
					math.min(max_tangent_impulse, previous_tangent_impulse + tangent_impulse)
				)
				local impulse_delta = new_tangent_impulse - previous_tangent_impulse

				if allow_persistent_tangent then
					contact.tangent_impulse = new_tangent_impulse
					contact.tangent = copy_vec(tangent)
				end

				if math.abs(impulse_delta) > physics.EPSILON then
					local impulse = tangent * impulse_delta
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