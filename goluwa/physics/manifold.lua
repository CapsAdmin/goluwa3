local physics_constants = import("goluwa/physics/constants.lua")
local impulse_motion = import("goluwa/physics/impulse_motion.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = {}
local EPSILON = physics_constants.EPSILON
local SOLVER_TANGENT = Vec3()
local SOLVER_BITANGENT = Vec3()

local function project_tangent_into(out, tangent, normal)
	local dot = tangent.x * normal.x + tangent.y * normal.y + tangent.z * normal.z
	out.x = tangent.x - normal.x * dot
	out.y = tangent.y - normal.y * dot
	out.z = tangent.z - normal.z * dot
	local length = math.sqrt(out.x * out.x + out.y * out.y + out.z * out.z)

	if length <= EPSILON then return false end

	local inv = 1 / length
	out.x, out.y, out.z = out.x * inv, out.y * inv, out.z * inv
	return true
end

local function get_cached_tangent_into(out, contact, normal)
	return project_tangent_into(out, contact.tangent, normal)
end

local function build_fallback_tangent_into(out, normal)
	local ax, ay, az

	if math.abs(normal.y) < 0.9 then
		ax, ay, az = 0, 1, 0
	else
		ax, ay, az = 1, 0, 0
	end

	local dot = ax * normal.x + ay * normal.y + az * normal.z
	out.x = ax - normal.x * dot
	out.y = ay - normal.y * dot
	out.z = az - normal.z * dot
	local length = math.sqrt(out.x * out.x + out.y * out.y + out.z * out.z)

	if length <= EPSILON then return false end

	local inv = 1 / length
	out.x, out.y, out.z = out.x * inv, out.y * inv, out.z * inv
	return true
end

local function get_separation_tolerance(solver)
	return math.max(solver.PENETRATION_SLOP or 0, 0.005) * 4
end

-- Separated (lifted) manifold points can only keep holding persistent impulse while the
-- pair is still moving fast. Once the pair slows down the lift is released, otherwise a
-- body locks into its tilted pose instead of settling flat onto the reference face.
local function pair_breaks_lifted_support(solver, body_a, body_b)
	local velocity_a = body_a.Velocity
	local velocity_b = body_b.Velocity
	local speed_a = velocity_a and velocity_a:GetLength() or 0
	local speed_b = velocity_b and velocity_b:GetLength() or 0
	return math.max(speed_a, speed_b) <= (solver.LIFT_BREAK_SPEED or 0.5)
end

local function build_tangent_basis_into(out_tangent, out_bitangent, normal, preferred_tangent)
	if
		not (
			preferred_tangent and
			project_tangent_into(out_tangent, preferred_tangent, normal)
		) and
		not build_fallback_tangent_into(out_tangent, normal)
	then
		return false
	end

	local tx, ty, tz = out_tangent.x, out_tangent.y, out_tangent.z
	local bx = ty * normal.z - tz * normal.y
	local by = tz * normal.x - tx * normal.z
	local bz = tx * normal.y - ty * normal.x

	if bx * bx + by * by + bz * bz <= EPSILON * EPSILON then
		if not build_fallback_tangent_into(out_tangent, normal) then return false end

		tx, ty, tz = out_tangent.x, out_tangent.y, out_tangent.z
		bx = ty * normal.z - tz * normal.y
		by = tz * normal.x - tx * normal.z
		bz = tx * normal.y - ty * normal.x
	end

	local bitangent_length = math.sqrt(bx * bx + by * by + bz * bz)
	local inv = 1 / bitangent_length
	bx, by, bz = bx * inv, by * inv, bz * inv
	out_bitangent.x, out_bitangent.y, out_bitangent.z = bx, by, bz
	out_tangent.x = normal.y * bz - normal.z * by
	out_tangent.y = normal.z * bx - normal.x * bz
	out_tangent.z = normal.x * by - normal.y * bx
	local tangent_length = math.sqrt(
		out_tangent.x * out_tangent.x + out_tangent.y * out_tangent.y + out_tangent.z * out_tangent.z
	)
	inv = 1 / tangent_length
	out_tangent.x, out_tangent.y, out_tangent.z = out_tangent.x * inv, out_tangent.y * inv, out_tangent.z * inv
	return true
end

local function supports_persistent_tangent(body_a, body_b, manifold_data)
	if #(manifold_data.contacts or {}) ~= 1 then return false end

	local shape_a = body_a:GetShapeType()
	local shape_b = body_b:GetShapeType()
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
			local dx = previous.local_point_a.x - local_point_a.x
			local dy = previous.local_point_a.y - local_point_a.y
			local dz = previous.local_point_a.z - local_point_a.z
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			dx = previous.local_point_b.x - local_point_b.x
			dy = previous.local_point_b.y - local_point_b.y
			dz = previous.local_point_b.z - local_point_b.z
			distance = distance + math.sqrt(dx * dx + dy * dy + dz * dz)

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
			separation = contact.separation or 0,
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

local SOLVER_POINT_A = Vec3()
local SOLVER_POINT_B = Vec3()
local SOLVER_TANGENT_VELOCITY = Vec3()

function manifold.WarmStart(body_a, body_b, normal, manifold_data, dt)
	local state_a, state_b = impulse_motion.CapturePairMotion(body_a, body_b)
	local did_apply = false
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)
	local physics = body_a:GetPhysics()
	local solver = physics.solver
	local separation_tolerance = get_separation_tolerance(solver)
	local lifts_broken = pair_breaks_lifted_support(solver, body_a, body_b)

	for _, contact in ipairs(manifold_data.contacts or {}) do
		if lifts_broken and (contact.separation or 0) > separation_tolerance then
			goto continue
		end

		local point_a = body_a:LocalToWorld(contact.local_point_a, nil, nil, SOLVER_POINT_A)
		local point_b = body_b:LocalToWorld(contact.local_point_b, nil, nil, SOLVER_POINT_B)
		local normal_impulse = math.max(contact.normal_impulse or 0, 0) * solver.WARM_START_SCALE
		local tangent_impulse_1 = (
				contact.tangent_impulse_1 or
				contact.tangent_impulse or
				0
			) * solver.TANGENT_WARM_START_SCALE
		local tangent_impulse_2 = (contact.tangent_impulse_2 or 0) * solver.TANGENT_WARM_START_SCALE
		local has_tangent_basis = build_tangent_basis_into(SOLVER_TANGENT, SOLVER_BITANGENT, normal, contact.tangent)

		if normal_impulse > EPSILON then
			impulse_motion.ApplyPairImpulse(state_a, state_b, normal, normal_impulse, point_a, point_b)
			did_apply = true
		end

		if
			has_tangent_basis and
			allow_persistent_tangent and
			(
				math.abs(tangent_impulse_1) > EPSILON or
				math.abs(tangent_impulse_2) > EPSILON
			)
		then
			local relative_velocity = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
			local normal_dot = relative_velocity.x * normal.x + relative_velocity.y * normal.y + relative_velocity.z * normal.z
			local tangent_speed_squared = relative_velocity.x * relative_velocity.x + relative_velocity.y * relative_velocity.y + relative_velocity.z * relative_velocity.z - normal_dot * normal_dot

			if
				tangent_speed_squared <= solver.MAX_TANGENT_WARM_SPEED * solver.MAX_TANGENT_WARM_SPEED
			then
				if math.abs(tangent_impulse_1) > EPSILON then
					impulse_motion.ApplyPairImpulse(state_a, state_b, SOLVER_TANGENT, tangent_impulse_1, point_a, point_b)
					did_apply = true
				end

				if math.abs(tangent_impulse_2) > EPSILON then
					impulse_motion.ApplyPairImpulse(state_a, state_b, SOLVER_BITANGENT, tangent_impulse_2, point_a, point_b)
					did_apply = true
				end
			end
		end

		::continue::
	end

	if did_apply then impulse_motion.CommitPairMotion(state_a, state_b, dt) end
end

function manifold.SolveImpulses(body_a, body_b, normal, manifold_data, dt)
	local state_a, state_b = impulse_motion.CapturePairMotion(body_a, body_b)
	local physics = body_a:GetPhysics()
	local solver = physics.solver
	local restitution = manifold_data.restitution or solver:GetPairRestitution(body_a, body_b)
	local dynamic_friction = manifold_data.friction or solver:GetPairFriction(body_a, body_b)
	local static_friction = manifold_data.static_friction or
		math.max(dynamic_friction, solver:GetPairStaticFriction(body_a, body_b))
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)
	local passes = solver:GetManifoldSolverPasses(body_a, body_b, normal, manifold_data, restitution)
	local separation_tolerance = get_separation_tolerance(solver)
	local lifts_broken = pair_breaks_lifted_support(solver, body_a, body_b)
	local contacts = manifold_data.contacts or {}

	for pass = 1, passes do
		for _, contact in ipairs(contacts) do
			if lifts_broken and (contact.separation or 0) > separation_tolerance then
				contact.normal_impulse = 0
				contact.tangent_impulse = 0
				contact.tangent_impulse_1 = 0
				contact.tangent_impulse_2 = 0
				contact.static_friction_active = false

				goto continue
			end

			local point_a = body_a:LocalToWorld(contact.local_point_a, nil, nil, SOLVER_POINT_A)
			local point_b = body_b:LocalToWorld(contact.local_point_b, nil, nil, SOLVER_POINT_B)
			local relative_velocity = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
			local normal_speed = relative_velocity:Dot(normal)
			local inverse_mass = body_a:GetInverseMassAlong(normal, point_a) + body_b:GetInverseMassAlong(normal, point_b)

			if inverse_mass > EPSILON then
				local applied_restitution = pass == 1 and normal_speed < -0.33 and restitution or 0
				local normal_impulse = -(1 + applied_restitution) * normal_speed / inverse_mass
				local new_impulse = math.max((contact.normal_impulse or 0) + normal_impulse, 0)
				local impulse_delta = new_impulse - (contact.normal_impulse or 0)
				contact.normal_impulse = new_impulse

				if math.abs(impulse_delta) > EPSILON then
					impulse_motion.ApplyPairImpulse(state_a, state_b, normal, impulse_delta, point_a, point_b)
				end
			end

			relative_velocity = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
			local normal_dot = relative_velocity.x * normal.x + relative_velocity.y * normal.y + relative_velocity.z * normal.z
			local tangent_velocity = SOLVER_TANGENT_VELOCITY
			tangent_velocity.x = relative_velocity.x - normal.x * normal_dot
			tangent_velocity.y = relative_velocity.y - normal.y * normal_dot
			tangent_velocity.z = relative_velocity.z - normal.z * normal_dot
			local tangent_speed = math.sqrt(
				tangent_velocity.x * tangent_velocity.x + tangent_velocity.y * tangent_velocity.y + tangent_velocity.z * tangent_velocity.z
			)

			if
				pass == passes and
				tangent_speed > EPSILON and
				(
					dynamic_friction > 0 or
					static_friction > 0
				)
			then
				local tangent_source

				if
					allow_persistent_tangent and
					get_cached_tangent_into(SOLVER_TANGENT, contact, normal)
				then
					tangent_source = SOLVER_TANGENT
				else
					local inv_speed = 1 / tangent_speed
					tangent_velocity.x = tangent_velocity.x * inv_speed
					tangent_velocity.y = tangent_velocity.y * inv_speed
					tangent_velocity.z = tangent_velocity.z * inv_speed
					tangent_source = tangent_velocity
				end

				if
					build_tangent_basis_into(SOLVER_TANGENT, SOLVER_BITANGENT, normal, tangent_source)
				then
					local tangent = SOLVER_TANGENT
					local bitangent = SOLVER_BITANGENT
					local tangent_inverse_mass_1 = body_a:GetInverseMassAlong(tangent, point_a) + body_b:GetInverseMassAlong(tangent, point_b)
					local tangent_inverse_mass_2 = body_a:GetInverseMassAlong(bitangent, point_a) + body_b:GetInverseMassAlong(bitangent, point_b)

					if tangent_inverse_mass_1 > EPSILON and tangent_inverse_mass_2 > EPSILON then
						local tangent_impulse_1 = -relative_velocity:Dot(tangent) / tangent_inverse_mass_1
						local tangent_impulse_2 = -relative_velocity:Dot(bitangent) / tangent_inverse_mass_2
						local static_impulse_limit = (contact.normal_impulse or 0) * static_friction
						local desired_tangent_impulse_length = math.sqrt(tangent_impulse_1 * tangent_impulse_1 + tangent_impulse_2 * tangent_impulse_2)
						local use_static_friction = solver:ShouldUseStaticFriction(contact, tangent_speed, desired_tangent_impulse_length, static_impulse_limit)
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
							tangent_impulse_length > EPSILON
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

						if math.abs(impulse_delta_1) > EPSILON then
							impulse_motion.ApplyPairImpulse(state_a, state_b, tangent, impulse_delta_1, point_a, point_b)
						end

						if math.abs(impulse_delta_2) > EPSILON then
							impulse_motion.ApplyPairImpulse(state_a, state_b, bitangent, impulse_delta_2, point_a, point_b)
						end
					end
				end
			end

			::continue::
		end
	end

	impulse_motion.CommitPairMotion(state_a, state_b, dt)
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
