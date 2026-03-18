local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local motion = import("goluwa/physics/motion.lua")
local manifold = {}

local function project_tangent(tangent, normal)
	if not tangent then return nil end

	tangent = tangent - normal * tangent:Dot(normal)

	if tangent:GetLength() <= physics.EPSILON then return nil end

	return tangent:GetNormalized()
end

local function get_cached_tangent(contact, normal)
	local tangent = contact.tangent
	return project_tangent(tangent, normal)
end

local function build_fallback_tangent(normal)
	local axis = math.abs(normal.y) < 0.9 and Vec3(0, 1, 0) or Vec3(1, 0, 0)
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
			tangent_impulse_1 = matched_contact and
				(
					matched_contact.tangent_impulse_1 or
					matched_contact.tangent_impulse
				)
				or
				0,
			tangent_impulse_2 = matched_contact and matched_contact.tangent_impulse_2 or 0,
			static_friction_active = matched_contact and matched_contact.static_friction_active == true or false,
			tangent = matched_contact and
				matched_contact.tangent and
				matched_contact.tangent:Copy() or
				nil,
		}
	end

	manifold_data.contacts = rebuilt
	return rebuilt
end

function manifold.WarmStart(body_a, body_b, normal, manifold_data, dt)
	local velocity_a = body_a:GetVelocity():Copy()
	local velocity_b = body_b:GetVelocity():Copy()
	local angular_velocity_a = body_a:GetAngularVelocity():Copy()
	local angular_velocity_b = body_b:GetAngularVelocity():Copy()
	local did_apply = false
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)
	local solver = physics.solver

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b)
		local normal_impulse = math.max(contact.normal_impulse or 0, 0) * solver.WARM_START_SCALE
		local tangent_impulse_1 = (
				contact.tangent_impulse_1 or
				contact.tangent_impulse or
				0
			) * solver.TANGENT_WARM_START_SCALE
		local tangent_impulse_2 = (contact.tangent_impulse_2 or 0) * solver.TANGENT_WARM_START_SCALE
		local tangent, bitangent = build_tangent_basis(normal, get_cached_tangent(contact, normal))

		if normal_impulse > physics.EPSILON then
			local impulse = normal * normal_impulse
			velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
			velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
			did_apply = true
		end

		if
			allow_persistent_tangent and
			tangent and
			(
				math.abs(tangent_impulse_1) > physics.EPSILON or
				math.abs(tangent_impulse_2) > physics.EPSILON
			)
		then
			local relative_velocity = motion.GetPointVelocity(body_b, velocity_b, angular_velocity_b, point_b) - motion.GetPointVelocity(body_a, velocity_a, angular_velocity_a, point_a)
			local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)

			if tangent_velocity:GetLength() <= solver.MAX_TANGENT_WARM_SPEED then
				if math.abs(tangent_impulse_1) > physics.EPSILON then
					local impulse = tangent * tangent_impulse_1
					velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
					velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
					did_apply = true
				end

				if bitangent and math.abs(tangent_impulse_2) > physics.EPSILON then
					local impulse = bitangent * tangent_impulse_2
					velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
					velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
					did_apply = true
				end
			end
		end
	end

	if did_apply then
		motion.SetBodyMotionFromCurrentState(body_a, velocity_a, angular_velocity_a, dt)
		motion.SetBodyMotionFromCurrentState(body_b, velocity_b, angular_velocity_b, dt)
	end
end

function manifold.SolveImpulses(body_a, body_b, normal, manifold_data, dt)
	local velocity_a = body_a:GetVelocity():Copy()
	local velocity_b = body_b:GetVelocity():Copy()
	local angular_velocity_a = body_a:GetAngularVelocity():Copy()
	local angular_velocity_b = body_b:GetAngularVelocity():Copy()
	local restitution = physics.solver:GetPairRestitution(body_a, body_b)
	local dynamic_friction = physics.solver:GetPairFriction(body_a, body_b)
	local static_friction = math.max(dynamic_friction, physics.solver:GetPairStaticFriction(body_a, body_b))
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

		if tangent_speed > physics.EPSILON and (dynamic_friction > 0 or static_friction > 0) then
			local tangent = get_cached_tangent(contact, normal)

			if not tangent or not allow_persistent_tangent then
				tangent = tangent_velocity / tangent_speed
			end

			local bitangent
			tangent, bitangent = build_tangent_basis(normal, tangent)

			if tangent and bitangent then
				local tangent_inverse_mass_1 = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)
				local tangent_inverse_mass_2 = body_a:GetInverseMassAlong(bitangent, point_a) + body_b:GetInverseMassAlong(bitangent, point_b)

				if
					tangent_inverse_mass_1 > physics.EPSILON and
					tangent_inverse_mass_2 > physics.EPSILON
				then
					local tangent_impulse_1 = -relative_velocity:Dot(tangent) / tangent_inverse_mass_1
					local tangent_impulse_2 = -relative_velocity:Dot(bitangent) / tangent_inverse_mass_2
					local static_impulse_limit = (contact.normal_impulse or 0) * static_friction
					local desired_tangent_impulse_length = math.sqrt(tangent_impulse_1 * tangent_impulse_1 + tangent_impulse_2 * tangent_impulse_2)
					local use_static_friction = physics.solver:ShouldUseStaticFriction(contact, tangent_speed, desired_tangent_impulse_length, static_impulse_limit)
					local friction_limit = use_static_friction and static_friction or dynamic_friction
					local max_tangent_impulse = (contact.normal_impulse or 0) * friction_limit
					local previous_tangent_impulse_1 = allow_persistent_tangent and
						(
							contact.tangent_impulse_1 or
							contact.tangent_impulse or
							0
						)
						or
						0
					local previous_tangent_impulse_2 = allow_persistent_tangent and (contact.tangent_impulse_2 or 0) or 0
					local new_tangent_impulse_1 = previous_tangent_impulse_1 + tangent_impulse_1
					local new_tangent_impulse_2 = previous_tangent_impulse_2 + tangent_impulse_2
					local tangent_impulse_length = math.sqrt(
						new_tangent_impulse_1 * new_tangent_impulse_1 + new_tangent_impulse_2 * new_tangent_impulse_2
					)

					if
						tangent_impulse_length > max_tangent_impulse and
						tangent_impulse_length > physics.EPSILON
					then
						local scale = max_tangent_impulse / tangent_impulse_length
						new_tangent_impulse_1 = new_tangent_impulse_1 * scale
						new_tangent_impulse_2 = new_tangent_impulse_2 * scale
					end

					local impulse_delta_1 = new_tangent_impulse_1 - previous_tangent_impulse_1
					local impulse_delta_2 = new_tangent_impulse_2 - previous_tangent_impulse_2

					if allow_persistent_tangent then
						contact.tangent_impulse = new_tangent_impulse_1
						contact.tangent_impulse_1 = new_tangent_impulse_1
						contact.tangent_impulse_2 = new_tangent_impulse_2
						contact.static_friction_active = use_static_friction
						contact.tangent = tangent:Copy()
					else
						contact.static_friction_active = use_static_friction
					end

					if math.abs(impulse_delta_1) > physics.EPSILON then
						local impulse = tangent * impulse_delta_1
						velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
						velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
					end

					if math.abs(impulse_delta_2) > physics.EPSILON then
						local impulse = bitangent * impulse_delta_2
						velocity_a, angular_velocity_a = motion.ApplyImpulseToMotion(body_a, velocity_a, angular_velocity_a, impulse * -1, point_a)
						velocity_b, angular_velocity_b = motion.ApplyImpulseToMotion(body_b, velocity_b, angular_velocity_b, impulse, point_b)
					end
				end
			end
		end
	end

	motion.SetBodyMotionFromCurrentState(body_a, velocity_a, angular_velocity_a, dt)
	motion.SetBodyMotionFromCurrentState(body_b, velocity_b, angular_velocity_b, dt)
end

function manifold.PruneOld(manifolds, step_stamp, prune_steps)
	for body_a, row in pairs(manifolds or {}) do
		for body_b, pair_manifold in pairs(row or {}) do
			if
				not pair_manifold.last_seen_step or
				pair_manifold.last_seen_step < step_stamp - prune_steps
			then
				row[body_b] = nil

				if manifolds[body_b] then
					manifolds[body_b][body_a] = nil

					if not next(manifolds[body_b]) then manifolds[body_b] = nil end
				end
			end
		end

		if not next(row) then manifolds[body_a] = nil end
	end
end

return manifold
