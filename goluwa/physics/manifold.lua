local physics_constants = import("goluwa/physics/constants.lua")
local impulse_motion = import("goluwa/physics/impulse_motion.lua")
local motion = import("goluwa/physics/motion.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = {}
local EPSILON = physics_constants.EPSILON
local SOLVER_TANGENT = Vec3()
local EMPTY_CONTACTS = {}
local PREPARE_CROSS = Vec3()
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
	local tangent = contact.tangent

	if not tangent then return false end

	return project_tangent_into(out, tangent, normal)
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

local CLAIMED = {}

-- contacts are rebuilt into the spare list from the previous substep and the
-- two lists swap, so matched contacts carry their impulses over without any
-- per-rebuild allocation
function manifold.RebuildContacts(body_a, body_b, manifold_data, contacts)
	local previous_contacts = manifold_data.contacts or EMPTY_CONTACTS
	local previous_count = #previous_contacts
	local rebuilt = manifold_data.spare_contacts or {}
	local claimed = CLAIMED

	for i = 1, previous_count do
		claimed[i] = false
	end

	for contact_index = 1, #contacts do
		local contact = contacts[contact_index]
		local rebuilt_contact = rebuilt[contact_index]

		if not rebuilt_contact then
			rebuilt_contact = {
				local_point_a = Vec3(),
				local_point_b = Vec3(),
				world_a = Vec3(),
				world_b = Vec3(),
				tangent_store = Vec3(),
			}
			rebuilt[contact_index] = rebuilt_contact
		end

		local local_point_a = body_a:WorldToLocal(contact.point_a, nil, nil, rebuilt_contact.local_point_a)
		local local_point_b = body_b:WorldToLocal(contact.point_b, nil, nil, rebuilt_contact.local_point_b)
		local matched_index
		-- contacts carrying a feature key match by exact feature pair first
		-- (box3d b3MakeFeatureId); proximity is only the fallback
		local feature_key = contact.feature_key

		if feature_key then
			for previous_index = 1, previous_count do
				if
					not claimed[previous_index] and
					previous_contacts[previous_index].feature_key == feature_key
				then
					matched_index = previous_index

					break
				end
			end
		end

		if not matched_index then
			local best_distance = 0.25

			for previous_index = 1, previous_count do
				if not claimed[previous_index] then
					local previous = previous_contacts[previous_index]
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
						matched_index = previous_index
					end
				end
			end
		end

		local matched_contact = matched_index and previous_contacts[matched_index] or nil

		if matched_index then claimed[matched_index] = true end

		if matched_contact then
			local tangent_impulse = matched_contact.tangent_impulse
			rebuilt_contact.normal_impulse = matched_contact.normal_impulse
			rebuilt_contact.tangent_impulse = tangent_impulse
			rebuilt_contact.tangent_impulse_1 = matched_contact.tangent_impulse_1 or tangent_impulse
			rebuilt_contact.tangent_impulse_2 = matched_contact.tangent_impulse_2
			rebuilt_contact.v_pre = matched_contact.v_pre
			rebuilt_contact.rest_stamp = matched_contact.rest_stamp
			rebuilt_contact.rest_speed = matched_contact.rest_speed
			rebuilt_contact.rest_total = matched_contact.rest_total
			rebuilt_contact.rest_impulse = matched_contact.rest_impulse
			rebuilt_contact.static_friction_active = matched_contact.static_friction_active

			if matched_contact.tangent then
				rebuilt_contact.tangent_store:CopyFrom(matched_contact.tangent)
				rebuilt_contact.tangent = rebuilt_contact.tangent_store
			else
				rebuilt_contact.tangent = nil
			end
		else
			rebuilt_contact.normal_impulse = 0
			rebuilt_contact.tangent_impulse = 0
			rebuilt_contact.tangent_impulse_1 = 0
			rebuilt_contact.tangent_impulse_2 = 0
			rebuilt_contact.v_pre = nil
			rebuilt_contact.rest_stamp = nil
			rebuilt_contact.rest_speed = nil
			rebuilt_contact.rest_total = nil
			rebuilt_contact.rest_impulse = nil
			rebuilt_contact.static_friction_active = 0
			rebuilt_contact.tangent = nil
		end

		rebuilt_contact.separation = contact.separation
		rebuilt_contact.base_depth = nil
		rebuilt_contact.feature_key = feature_key
		rebuilt_contact.normal_impulse = rebuilt_contact.normal_impulse or 0
		rebuilt_contact.tangent_impulse = rebuilt_contact.tangent_impulse or 0
		rebuilt_contact.tangent_impulse_1 = rebuilt_contact.tangent_impulse_1 or 0
		rebuilt_contact.tangent_impulse_2 = rebuilt_contact.tangent_impulse_2 or 0
	end

	for i = #contacts + 1, #rebuilt do
		rebuilt[i] = nil
	end

	manifold_data.contacts = rebuilt
	manifold_data.spare_contacts = previous_contacts ~= EMPTY_CONTACTS and previous_contacts or nil
	return rebuilt
end

local SOLVER_POINT_A = Vec3()
local SOLVER_POINT_B = Vec3()
local SOLVER_TANGENT_VELOCITY = Vec3()
local BIAS_POINT_A = Vec3()
local BIAS_POINT_B = Vec3()

function manifold.CaptureRestitutionBias(body_a, body_b, normal, manifold_data, stamp)
	local state_a, state_b = impulse_motion.CapturePairMotion(body_a, body_b)

	for _, contact in ipairs(manifold_data.contacts or {}) do
		local point_a = body_a:LocalToWorld(contact.local_point_a, nil, nil, BIAS_POINT_A)
		local point_b = body_b:LocalToWorld(contact.local_point_b, nil, nil, BIAS_POINT_B)
		contact.v_pre = impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b):Dot(normal)

		-- restitution bounces off the speed the contact first arrived with in
		-- this step, before any of its substeps solved it
		if contact.rest_stamp ~= stamp then
			contact.rest_stamp = stamp
			contact.rest_speed = contact.v_pre
			contact.rest_total = 0
			contact.rest_impulse = 0
		end
	end
end

function manifold.WarmStart(body_a, body_b, normal, manifold_data, dt)
	local state_a, state_b = impulse_motion.CapturePairMotion(body_a, body_b)

	-- a sleeping body never integrated gravity this step, so the impulse that
	-- used to balance it would only kick it awake
	if body_a.Awake == false then state_a.immovable = true end

	if body_b.Awake == false then state_b.immovable = true end

	local did_apply = false
	manifold_data.twist_impulse = 0
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)
	local physics = body_a:GetPhysics()
	local solver = physics.solver

	for _, contact in ipairs(manifold_data.contacts or {}) do
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

		-- the solver accumulates impulses and clamps them against the contact's
		-- friction cone, so what it holds must be exactly what was applied here
		local applied_tangent_1 = 0
		local applied_tangent_2 = 0

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
					applied_tangent_1 = tangent_impulse_1
					did_apply = true
				end

				if math.abs(tangent_impulse_2) > EPSILON then
					impulse_motion.ApplyPairImpulse(state_a, state_b, SOLVER_BITANGENT, tangent_impulse_2, point_a, point_b)
					applied_tangent_2 = tangent_impulse_2
					did_apply = true
				end
			end
		end

		contact.tangent_impulse = applied_tangent_1
		contact.tangent_impulse_1 = applied_tangent_1
		contact.tangent_impulse_2 = applied_tangent_2
	end

	if did_apply then impulse_motion.CommitPairMotion(state_a, state_b, dt) end
end

-- Everything the normal row needs that only depends on the poses is computed
-- once per substep (contacts are rebuilt or the substep changes): bodies do not
-- move while velocity impulses are solved, so the lever arms, the angular
-- response per unit impulse and the effective mass stay valid for every pass.
local function prepare_contacts(body_a, body_b, normal, manifold_data, stamp)
	local nx, ny, nz = normal.x, normal.y, normal.z
	local position_a = body_a:GetBody().Position
	local position_b = body_b:GetBody().Position
	local mass_a = body_a:HasSolverMass() and body_a.InverseMass or 0
	local mass_b = body_b:HasSolverMass() and body_b.InverseMass or 0
	local movable_a = body_a:IsSolverImmovable() and 0 or 1
	local movable_b = body_b:IsSolverImmovable() and 0 or 1
	local has_inertia_a = body_a:HasSolverMass()
	local has_inertia_b = body_b:HasSolverMass()
	local contacts = manifold_data.contacts

	for i = 1, #contacts do
		local contact = contacts[i]
		local point_a = body_a:LocalToWorld(contact.local_point_a, nil, nil, contact.world_a)
		local point_b = body_b:LocalToWorld(contact.local_point_b, nil, nil, contact.world_b)
		contact.world_a = point_a
		contact.world_b = point_b
		local depth = (
				point_a.x - point_b.x
			) * nx + (
				point_a.y - point_b.y
			) * ny + (
				point_a.z - point_b.z
			) * nz

		-- the anchors are fixed to the bodies and the normal to the rebuild
		-- pose, so the gap follows from how far the anchors moved along the
		-- normal since the narrowphase measured it
		if contact.base_depth then
			contact.separation = contact.base_separation - (depth - contact.base_depth)
		else
			-- narrowphases that clip against a reference face report a signed
			-- gap, the others only the manifold overlap
			contact.separation = contact.separation or -(depth + (manifold_data.depth_offset or 0))
			contact.base_separation = contact.separation
			contact.base_depth = depth
		end

		local rx, ry, rz = point_a.x - position_a.x, point_a.y - position_a.y, point_a.z - position_a.z
		contact.ra_x, contact.ra_y, contact.ra_z = rx, ry, rz
		local cx, cy, cz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
		contact.ca_x, contact.ca_y, contact.ca_z = cx, cy, cz
		local inverse_mass = 0

		if has_inertia_a then
			local delta = body_a:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, cx, cy, cz))
			contact.wa_x, contact.wa_y, contact.wa_z = delta.x, delta.y, delta.z
			inverse_mass = inverse_mass + mass_a + cx * delta.x + cy * delta.y + cz * delta.z
		else
			contact.wa_x, contact.wa_y, contact.wa_z = 0, 0, 0
		end

		rx, ry, rz = point_b.x - position_b.x, point_b.y - position_b.y, point_b.z - position_b.z
		contact.rb_x, contact.rb_y, contact.rb_z = rx, ry, rz
		cx, cy, cz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
		contact.cb_x, contact.cb_y, contact.cb_z = cx, cy, cz

		if has_inertia_b then
			local delta = body_b:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, cx, cy, cz))
			contact.wb_x, contact.wb_y, contact.wb_z = delta.x, delta.y, delta.z
			inverse_mass = inverse_mass + mass_b + cx * delta.x + cy * delta.y + cz * delta.z
		else
			contact.wb_x, contact.wb_y, contact.wb_z = 0, 0, 0
		end

		contact.normal_inverse_mass = inverse_mass
	end

	-- twist friction resists spin about the normal; contacts further from
	-- the manifold centre give it more leverage, a lone contact gives none
	local count = #contacts
	local centre_x, centre_y, centre_z = 0, 0, 0

	for i = 1, count do
		centre_x = centre_x + contacts[i].world_a.x
		centre_y = centre_y + contacts[i].world_a.y
		centre_z = centre_z + contacts[i].world_a.z
	end

	centre_x, centre_y, centre_z = centre_x / count, centre_y / count, centre_z / count

	for i = 1, count do
		local dx, dy, dz = contacts[i].world_a.x - centre_x, contacts[i].world_a.y - centre_y, contacts[i].world_a.z - centre_z
		contacts[i].lever_arm = math.sqrt(dx * dx + dy * dy + dz * dz)
	end

	local twist_inverse_mass = 0

	if has_inertia_a then
		local delta = body_a:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, nx, ny, nz))
		twist_inverse_mass = twist_inverse_mass + nx * delta.x + ny * delta.y + nz * delta.z
	end

	if has_inertia_b then
		local delta = body_b:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, nx, ny, nz))
		twist_inverse_mass = twist_inverse_mass + nx * delta.x + ny * delta.y + nz * delta.z
	end

	manifold_data.twist_mass = twist_inverse_mass > EPSILON and 1 / twist_inverse_mass or 0
	manifold_data.prepared_step = stamp
	manifold_data.prepared_mass_a = mass_a * movable_a
	manifold_data.prepared_mass_b = mass_b * movable_b
end

-- world-space inverse inertia applied to a world vector: R * I^-1 * R^T * v
local function inverse_inertia_apply(body, vx, vy, vz)
	body = body:GetBody()
	local tx = 2 * (-body.Rotation.y * vz + body.Rotation.z * vy)
	local ty = 2 * (-body.Rotation.z * vx + body.Rotation.x * vz)
	local tz = 2 * (-body.Rotation.x * vy + body.Rotation.y * vx)
	local lx = vx + body.Rotation.w * tx + (-body.Rotation.y * tz + body.Rotation.z * ty)
	local ly = vy + body.Rotation.w * ty + (-body.Rotation.z * tx + body.Rotation.x * tz)
	local lz = vz + body.Rotation.w * tz + (-body.Rotation.x * ty + body.Rotation.y * tx)
	local ix = body.InverseInertiaTensor.m00 * lx + body.InverseInertiaTensor.m01 * ly + body.InverseInertiaTensor.m02 * lz
	local iy = body.InverseInertiaTensor.m10 * lx + body.InverseInertiaTensor.m11 * ly + body.InverseInertiaTensor.m12 * lz
	local iz = body.InverseInertiaTensor.m20 * lx + body.InverseInertiaTensor.m21 * ly + body.InverseInertiaTensor.m22 * lz
	tx = 2 * (body.Rotation.y * iz - body.Rotation.z * iy)
	ty = 2 * (body.Rotation.z * ix - body.Rotation.x * iz)
	tz = 2 * (body.Rotation.x * iy - body.Rotation.y * ix)
	return ix + body.Rotation.w * tx + (body.Rotation.y * tz - body.Rotation.z * ty),
	iy + body.Rotation.w * ty + (body.Rotation.z * tx - body.Rotation.x * tz),
	iz + body.Rotation.w * tz + (body.Rotation.x * ty - body.Rotation.y * tx)
end

-- v . (R * I^-1 * R^T * v), without rotating the result back
local function inverse_inertia_dot(body, vx, vy, vz)
	body = body:GetBody()
	local tx = 2 * (-body.Rotation.y * vz + body.Rotation.z * vy)
	local ty = 2 * (-body.Rotation.z * vx + body.Rotation.x * vz)
	local tz = 2 * (-body.Rotation.x * vy + body.Rotation.y * vx)
	local lx = vx + body.Rotation.w * tx + (-body.Rotation.y * tz + body.Rotation.z * ty)
	local ly = vy + body.Rotation.w * ty + (-body.Rotation.z * tx + body.Rotation.x * tz)
	local lz = vz + body.Rotation.w * tz + (-body.Rotation.x * ty + body.Rotation.y * tx)
	return lx * (body.InverseInertiaTensor.m00 * lx + body.InverseInertiaTensor.m01 * ly + body.InverseInertiaTensor.m02 * lz) + ly * (body.InverseInertiaTensor.m10 * lx + body.InverseInertiaTensor.m11 * ly + body.InverseInertiaTensor.m12 * lz) + lz * (body.InverseInertiaTensor.m20 * lx + body.InverseInertiaTensor.m21 * ly + body.InverseInertiaTensor.m22 * lz)
end

manifold.PrepareContacts = prepare_contacts

function manifold.SolveImpulses(
	body_a,
	body_b,
	normal,
	manifold_data,
	dt,
	relax,
	restitution,
	dynamic_friction,
	static_friction
)
	local physics = body_a:GetPhysics()
	local stamp = physics.solver.StepStamp or 0

	if manifold_data.prepared_step ~= stamp then
		prepare_contacts(body_a, body_b, normal, manifold_data, stamp)
	end

	local bounces = restitution > 0
	local allow_persistent_tangent = supports_persistent_tangent(body_a, body_b, manifold_data)
	local passes = physics.solver:GetManifoldSolverPasses(body_a, body_b, normal, manifold_data, restitution)
	-- soft contact: a spring-damper per contact (Box2D soft step), static
	-- pairs twice as stiff. The relax pass solves rigidly with no bias
	-- (rate 0, full mass scale, no impulse scale) and no speculative gap.
	local bias_rate = 0
	local soft_mass_scale = 1
	local soft_impulse_scale = 0
	local speculative = false

	-- a sleeping body skipped gravity this substep, so the soft solve would
	-- relax the support impulse it still carries and kick it awake
	if
		not relax and
		not (
			(
				manifold_data.prepared_mass_a > 0 and
				body_a.Awake == false
			)
			or
			(
				manifold_data.prepared_mass_b > 0 and
				body_b.Awake == false
			)
		)
	then
		local hertz = math.min(physics.solver.CONTACT_HERTZ, 0.25 / dt)
		local damping_ratio = physics.solver.CONTACT_DAMPING_RATIO

		if manifold_data.prepared_mass_a == 0 or manifold_data.prepared_mass_b == 0 then
			hertz = hertz * 2
			damping_ratio = damping_ratio * 0.5
		end

		local omega = 2 * math.pi * hertz
		local a1 = 2 * damping_ratio + dt * omega
		local a2 = dt * omega * a1
		soft_impulse_scale = 1 / (1 + a2)
		soft_mass_scale = a2 * soft_impulse_scale
		bias_rate = omega / a1
		speculative = true
	end

	local position_correction = -math.huge

	for pass = 1, passes do
		for contact_index = 1, #manifold_data.contacts do
			local contact = manifold_data.contacts[contact_index]

			if contact.normal_inverse_mass > EPSILON then
				local normal_speed = (
						body_b.Velocity.x - body_a.Velocity.x
					) * normal.x + (
						body_b.Velocity.y - body_a.Velocity.y
					) * normal.y + (
						body_b.Velocity.z - body_a.Velocity.z
					) * normal.z + body_b.AngularVelocity.x * contact.cb_x + body_b.AngularVelocity.y * contact.cb_y + body_b.AngularVelocity.z * contact.cb_z - body_a.AngularVelocity.x * contact.ca_x - body_a.AngularVelocity.y * contact.ca_y - body_a.AngularVelocity.z * contact.ca_z
				local effective_speed = normal_speed
				-- the gap before this substep's motion; bodies already moved by v_pre * dt.
				-- A closed gap solves softly with a push-out bias, an open gap is
				-- speculative: it may still approach by gap / dt.
				local gap = contact.separation - (contact.v_pre or 0) * dt
				local open_gap = 0

				if speculative then open_gap = math.min(1, math.max(0, gap * 1e30)) end

				-- the relax pass solves a contact as touching so a resting body keeps
				-- its support, but one that is clearly open stays open: solved as
				-- touching it would prop up the side of a tilted box that should
				-- be falling flat
				if relax and gap > physics.solver.RELAX_OPEN_GAP then open_gap = 1 end

				local bias = open_gap * gap / dt + (
						1 - open_gap
					) * math.max(
						bias_rate * (gap + physics.solver.PENETRATION_SLOP),
						-physics.solver.CONTACT_PUSH_SPEED
					)
				position_correction = math.max(position_correction, -(gap + physics.solver.PENETRATION_SLOP) * (1 - open_gap))
				local normal_impulse = -(
						1 + (
							1 - open_gap
						) * (
							soft_mass_scale - 1
						)
					) * (
						effective_speed + bias
					) / contact.normal_inverse_mass - (
						1 - open_gap
					) * soft_impulse_scale * (
						contact.normal_impulse or
						0
					)
				local new_impulse = math.max((contact.normal_impulse or 0) + normal_impulse, 0)
				local impulse_delta = new_impulse - (contact.normal_impulse or 0)
				contact.normal_impulse = new_impulse

				if bounces then
					contact.rest_total = (contact.rest_total or 0) + new_impulse
				end

				if math.abs(impulse_delta) > EPSILON then
					if manifold_data.prepared_mass_a > 0 then
						local scale = impulse_delta * manifold_data.prepared_mass_a
						body_a.Velocity.x = body_a.Velocity.x - normal.x * scale
						body_a.Velocity.y = body_a.Velocity.y - normal.y * scale
						body_a.Velocity.z = body_a.Velocity.z - normal.z * scale
						body_a.AngularVelocity.x = body_a.AngularVelocity.x - impulse_delta * contact.wa_x
						body_a.AngularVelocity.y = body_a.AngularVelocity.y - impulse_delta * contact.wa_y
						body_a.AngularVelocity.z = body_a.AngularVelocity.z - impulse_delta * contact.wa_z
					end

					if manifold_data.prepared_mass_b > 0 then
						local scale = impulse_delta * manifold_data.prepared_mass_b
						body_b.Velocity.x = body_b.Velocity.x + normal.x * scale
						body_b.Velocity.y = body_b.Velocity.y + normal.y * scale
						body_b.Velocity.z = body_b.Velocity.z + normal.z * scale
						body_b.AngularVelocity.x = body_b.AngularVelocity.x + impulse_delta * contact.wb_x
						body_b.AngularVelocity.y = body_b.AngularVelocity.y + impulse_delta * contact.wb_y
						body_b.AngularVelocity.z = body_b.AngularVelocity.z + impulse_delta * contact.wb_z
					end
				end
			end

			if
				pass == passes and
				(
					dynamic_friction > 0 or
					static_friction > 0
				)
			then
				local rel_x = body_b.Velocity.x + body_b.AngularVelocity.y * (
						contact.rb_z
					) - body_b.AngularVelocity.z * (
						contact.rb_y
					) - body_a.Velocity.x - body_a.AngularVelocity.y * (
						contact.ra_z
					) + body_a.AngularVelocity.z * (
						contact.ra_y
					)
				local rel_y = body_b.Velocity.y + body_b.AngularVelocity.z * (
						contact.rb_x
					) - body_b.AngularVelocity.x * (
						contact.rb_z
					) - body_a.Velocity.y - body_a.AngularVelocity.z * (
						contact.ra_x
					) + body_a.AngularVelocity.x * (
						contact.ra_z
					)
				local rel_z = body_b.Velocity.z + body_b.AngularVelocity.x * (
						contact.rb_y
					) - body_b.AngularVelocity.y * (
						contact.rb_x
					) - body_a.Velocity.z - body_a.AngularVelocity.x * (
						contact.ra_y
					) + body_a.AngularVelocity.y * (
						contact.ra_x
					)
				local normal_dot = rel_x * normal.x + rel_y * normal.y + rel_z * normal.z
				local tangent_speed = math.sqrt(
					(
							rel_x - normal.x * normal_dot
						) ^ 2 + (
							rel_y - normal.y * normal_dot
						) ^ 2 + (
							rel_z - normal.z * normal_dot
						) ^ 2
				)

				if tangent_speed > EPSILON then
					-- tangent direction: the cached one while it is still usable,
					-- otherwise the sliding direction
					local px, py, pz = rel_x - normal.x * normal_dot,
					rel_y - normal.y * normal_dot,
					rel_z - normal.z * normal_dot
					local inv = 1 / tangent_speed
					local cached = allow_persistent_tangent and contact.tangent

					if cached then
						local dot = cached.x * normal.x + cached.y * normal.y + cached.z * normal.z
						local cx, cy, cz = cached.x - normal.x * dot, cached.y - normal.y * dot, cached.z - normal.z * dot
						local length_squared = cx * cx + cy * cy + cz * cz

						if length_squared > EPSILON * EPSILON then
							px, py, pz = cx, cy, cz
							inv = 1 / math.sqrt(length_squared)
						end
					end

					-- bitangent = t x n, then re-orthogonalise t = n x b
					local bx, by, bz = (py * normal.z - pz * normal.y) * inv,
					(pz * normal.x - px * normal.z) * inv,
					(px * normal.y - py * normal.x) * inv
					px, py, pz = px * inv, py * inv, pz * inv

					if bx * bx + by * by + bz * bz <= EPSILON * EPSILON then
						local ax, ay, az = 1, 0, 0

						if math.abs(normal.y) < 0.9 then ax, ay = 0, 1 end

						local dot = ax * normal.x + ay * normal.y + az * normal.z
						px, py, pz = ax - normal.x * dot, ay - normal.y * dot, az - normal.z * dot
						inv = 1 / math.sqrt(px * px + py * py + pz * pz)
						px, py, pz = px * inv, py * inv, pz * inv
						bx, by, bz = py * normal.z - pz * normal.y,
						pz * normal.x - px * normal.z,
						px * normal.y - py * normal.x
					end

					inv = 1 / math.sqrt(bx * bx + by * by + bz * bz)
					bx, by, bz = bx * inv, by * inv, bz * inv
					local tx, ty, tz = normal.y * bz - normal.z * by,
					normal.z * bx - normal.x * bz,
					normal.x * by - normal.y * bx
					inv = 1 / math.sqrt(tx * tx + ty * ty + tz * tz)
					tx, ty, tz = tx * inv, ty * inv, tz * inv
					local inverse_mass_1, inverse_mass_2 = 0, 0

					if manifold_data.prepared_mass_a > 0 then
						local rax, ray, raz = contact.ra_x, contact.ra_y, contact.ra_z
						inverse_mass_1 = manifold_data.prepared_mass_a + inverse_inertia_dot(body_a, ray * tz - raz * ty, raz * tx - rax * tz, rax * ty - ray * tx)
						inverse_mass_2 = manifold_data.prepared_mass_a + inverse_inertia_dot(body_a, ray * bz - raz * by, raz * bx - rax * bz, rax * by - ray * bx)
					end

					if manifold_data.prepared_mass_b > 0 then
						local rbx, rby, rbz = contact.rb_x, contact.rb_y, contact.rb_z
						inverse_mass_1 = inverse_mass_1 + manifold_data.prepared_mass_b + inverse_inertia_dot(body_b, rby * tz - rbz * ty, rbz * tx - rbx * tz, rbx * ty - rby * tx)
						inverse_mass_2 = inverse_mass_2 + manifold_data.prepared_mass_b + inverse_inertia_dot(body_b, rby * bz - rbz * by, rbz * bx - rbx * bz, rbx * by - rby * bx)
					end

					if inverse_mass_1 > EPSILON and inverse_mass_2 > EPSILON then
						local impulse_1 = -(rel_x * tx + rel_y * ty + rel_z * tz) / inverse_mass_1
						local impulse_2 = -(rel_x * bx + rel_y * by + rel_z * bz) / inverse_mass_2
						local normal_impulse = contact.normal_impulse or 0
						local static_flag = math.max(
							math.min(1, math.max(0, (normal_impulse * static_friction) * 1e8)) * math.min(
									1,
									math.max(
										0,
										(
												(
													normal_impulse * static_friction
												) ^ 2 - impulse_1 * impulse_1 - impulse_2 * impulse_2
											) * 1e8 + 1
									)
								),
							math.min(1, math.max(0, (physics.solver.STATIC_FRICTION_SPEED - tangent_speed) * 1e8 + 1)),
							contact.static_friction_active * math.min(
									1,
									math.max(0, (physics.solver.STATIC_FRICTION_EXIT_SPEED - tangent_speed) * 1e8 + 1)
								)
						)
						local max_tangent_impulse = normal_impulse * (
								dynamic_friction + (
									static_friction - dynamic_friction
								) * static_flag
							)
						local previous_1 = 0
						local previous_2 = 0

						if allow_persistent_tangent then
							previous_1 = contact.tangent_impulse_1 or contact.tangent_impulse or 0
							previous_2 = contact.tangent_impulse_2 or 0
						end

						local new_1 = previous_1 + impulse_1
						local new_2 = previous_2 + impulse_2
						local cone_scale = math.min(
							1,
							max_tangent_impulse / math.max(math.sqrt(new_1 * new_1 + new_2 * new_2), EPSILON)
						)
						new_1 = new_1 * cone_scale
						new_2 = new_2 * cone_scale
						local delta_1 = new_1 - previous_1
						local delta_2 = new_2 - previous_2
						contact.static_friction_active = static_flag

						if allow_persistent_tangent then
							contact.tangent_impulse = new_1
							contact.tangent_impulse_1 = new_1
							contact.tangent_impulse_2 = new_2
							local tangent_store = contact.tangent_store

							if not tangent_store then
								tangent_store = Vec3()
								contact.tangent_store = tangent_store
							end

							tangent_store.x, tangent_store.y, tangent_store.z = tx, ty, tz
							contact.tangent = tangent_store
						end

						-- r x (d1 t + d2 b) is linear, so one inverse inertia call covers both rows
						local wx, wy, wz = delta_1 * tx + delta_2 * bx,
						delta_1 * ty + delta_2 * by,
						delta_1 * tz + delta_2 * bz

						if manifold_data.prepared_mass_a > 0 then
							body_a.Velocity.x = body_a.Velocity.x - wx * manifold_data.prepared_mass_a
							body_a.Velocity.y = body_a.Velocity.y - wy * manifold_data.prepared_mass_a
							body_a.Velocity.z = body_a.Velocity.z - wz * manifold_data.prepared_mass_a
							local rax, ray, raz = contact.ra_x, contact.ra_y, contact.ra_z
							local dx, dy, dz = inverse_inertia_apply(body_a, ray * wz - raz * wy, raz * wx - rax * wz, rax * wy - ray * wx)
							body_a.AngularVelocity.x = body_a.AngularVelocity.x - dx
							body_a.AngularVelocity.y = body_a.AngularVelocity.y - dy
							body_a.AngularVelocity.z = body_a.AngularVelocity.z - dz
						end

						if manifold_data.prepared_mass_b > 0 then
							body_b.Velocity.x = body_b.Velocity.x + wx * manifold_data.prepared_mass_b
							body_b.Velocity.y = body_b.Velocity.y + wy * manifold_data.prepared_mass_b
							body_b.Velocity.z = body_b.Velocity.z + wz * manifold_data.prepared_mass_b
							local rbx, rby, rbz = contact.rb_x, contact.rb_y, contact.rb_z
							local dx, dy, dz = inverse_inertia_apply(body_b, rby * wz - rbz * wy, rbz * wx - rbx * wz, rbx * wy - rby * wx)
							body_b.AngularVelocity.x = body_b.AngularVelocity.x + dx
							body_b.AngularVelocity.y = body_b.AngularVelocity.y + dy
							body_b.AngularVelocity.z = body_b.AngularVelocity.z + dz
						end
					end
				end
			end
		end

		if pass == passes and manifold_data.twist_mass > 0 and dynamic_friction > 0 then
			local twist_limit = 0

			for contact_index = 1, #manifold_data.contacts do
				twist_limit = twist_limit + manifold_data.contacts[contact_index].lever_arm * (
						manifold_data.contacts[contact_index].normal_impulse or
						0
					)
			end

			twist_limit = twist_limit * dynamic_friction
			local twist_speed = (
					body_b.AngularVelocity.x - body_a.AngularVelocity.x
				) * normal.x + (
					body_b.AngularVelocity.y - body_a.AngularVelocity.y
				) * normal.y + (
					body_b.AngularVelocity.z - body_a.AngularVelocity.z
				) * normal.z
			local previous = manifold_data.twist_impulse
			local new_impulse = math.min(
				math.max(previous - manifold_data.twist_mass * twist_speed, -twist_limit),
				twist_limit
			)
			manifold_data.twist_impulse = new_impulse
			local delta = new_impulse - previous

			if manifold_data.prepared_mass_a > 0 then
				local d = body_a:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, normal.x * delta, normal.y * delta, normal.z * delta))
				body_a.AngularVelocity.x = body_a.AngularVelocity.x - d.x
				body_a.AngularVelocity.y = body_a.AngularVelocity.y - d.y
				body_a.AngularVelocity.z = body_a.AngularVelocity.z - d.z
			end

			if manifold_data.prepared_mass_b > 0 then
				local d = body_b:GetAngularVelocityDelta(Vec3.Set(PREPARE_CROSS, normal.x * delta, normal.y * delta, normal.z * delta))
				body_b.AngularVelocity.x = body_b.AngularVelocity.x + d.x
				body_b.AngularVelocity.y = body_b.AngularVelocity.y + d.y
				body_b.AngularVelocity.z = body_b.AngularVelocity.z + d.z
			end
		end
	end

	body_a.PositionCorrection = math.max(body_a.PositionCorrection, position_correction)
	body_b.PositionCorrection = math.max(body_b.PositionCorrection, position_correction)

	-- a sleeping body only wakes once the impulses push it past its thresholds
	if body_a.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_a, body_a.Velocity, body_a.AngularVelocity, dt)
	end

	if body_b.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_b, body_b.Velocity, body_b.AngularVelocity, dt)
	end
end

-- Bounce after the substeps: contacts that took compression impulse and
-- arrived faster than the threshold get the velocity that makes them leave
-- at restitution times their arrival speed. Runs on velocities only.
function manifold.ApplyRestitution(body_a, body_b, normal, manifold_data, dt)
	local physics = body_a:GetPhysics()
	local solver = physics.solver
	local restitution = manifold_data.restitution or solver:GetPairRestitution(body_a, body_b)

	if restitution <= EPSILON then return end

	local gravity = physics.Gravity
	local threshold = math.max(
		0.33,
		math.sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z) * dt * 2
	)

	for contact_index = 1, #manifold_data.contacts do
		local contact = manifold_data.contacts[contact_index]

		if
			contact.rest_stamp == solver.CollideStamp and
			contact.rest_speed < -threshold and
			contact.rest_total > 0 and
			contact.normal_inverse_mass > EPSILON
		then
			local normal_speed = (
					body_b.Velocity.x - body_a.Velocity.x
				) * normal.x + (
					body_b.Velocity.y - body_a.Velocity.y
				) * normal.y + (
					body_b.Velocity.z - body_a.Velocity.z
				) * normal.z + body_b.AngularVelocity.x * contact.cb_x + body_b.AngularVelocity.y * contact.cb_y + body_b.AngularVelocity.z * contact.cb_z - body_a.AngularVelocity.x * contact.ca_x - body_a.AngularVelocity.y * contact.ca_y - body_a.AngularVelocity.z * contact.ca_z
			local new_impulse = math.max(
				contact.rest_impulse - (
						normal_speed + restitution * contact.rest_speed
					) / contact.normal_inverse_mass,
				0
			)
			local impulse_delta = new_impulse - contact.rest_impulse
			contact.rest_impulse = new_impulse

			if manifold_data.prepared_mass_a > 0 then
				local scale = impulse_delta * manifold_data.prepared_mass_a
				body_a.Velocity.x = body_a.Velocity.x - normal.x * scale
				body_a.Velocity.y = body_a.Velocity.y - normal.y * scale
				body_a.Velocity.z = body_a.Velocity.z - normal.z * scale
				body_a.AngularVelocity.x = body_a.AngularVelocity.x - impulse_delta * contact.wa_x
				body_a.AngularVelocity.y = body_a.AngularVelocity.y - impulse_delta * contact.wa_y
				body_a.AngularVelocity.z = body_a.AngularVelocity.z - impulse_delta * contact.wa_z
			end

			if manifold_data.prepared_mass_b > 0 then
				local scale = impulse_delta * manifold_data.prepared_mass_b
				body_b.Velocity.x = body_b.Velocity.x + normal.x * scale
				body_b.Velocity.y = body_b.Velocity.y + normal.y * scale
				body_b.Velocity.z = body_b.Velocity.z + normal.z * scale
				body_b.AngularVelocity.x = body_b.AngularVelocity.x + impulse_delta * contact.wb_x
				body_b.AngularVelocity.y = body_b.AngularVelocity.y + impulse_delta * contact.wb_y
				body_b.AngularVelocity.z = body_b.AngularVelocity.z + impulse_delta * contact.wb_z
			end
		end
	end

	if body_a.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_a, body_a.Velocity, body_a.AngularVelocity, dt)
	end

	if body_b.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_b, body_b.Velocity, body_b.AngularVelocity, dt)
	end
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
