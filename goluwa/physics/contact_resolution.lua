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
local GROUND_NORMAL_SCRATCH = Vec3()

function contact_resolution.MarkPairGrounding(body_a, body_b, normal, rolling_friction)
	if rolling_friction == nil then
		rolling_friction = body_a:GetPhysics().solver:GetPairRollingFriction(body_a, body_b)
	end

	if -normal.y >= body_a:GetMinGroundNormalY() then
		body_a:SetGrounded(true)
		body_a:SetGroundNormal(Vec3.SetScaled(GROUND_NORMAL_SCRATCH, normal, -1))
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

contact_resolution.GetPairManifold = get_pair_manifold

local function set_pair_manifold(manifolds, body_a, body_b, manifold)
	get_or_create_manifold_row(manifolds, body_a)[body_b] = manifold
	get_or_create_manifold_row(manifolds, body_b)[body_a] = manifold
end

local function refresh_pair_materials(solver, body_a, body_b, manifold)
	if manifold.material_step == solver.StepStamp then return end

	local friction = solver:GetPairFriction(body_a, body_b)
	manifold.restitution = solver:GetPairRestitution(body_a, body_b)
	manifold.friction = friction
	manifold.static_friction = math.max(friction, solver:GetPairStaticFriction(body_a, body_b))
	manifold.rolling_friction = solver:GetPairRollingFriction(body_a, body_b)
	manifold.material_step = solver.StepStamp
end

local EMPTY_OPTIONS = {}
local SINGLE_CONTACT = {}
local SINGLE_CONTACTS = {SINGLE_CONTACT}
local FINISH_WORLD_POINT_A = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}
local FINISH_WORLD_POINT_B = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}

function contact_resolution.ApplyManifoldRestitution(body_a, body_b, manifold, dt)
	if not manifold.idle then
		manifolds.ApplyRestitution(body_a, body_b, manifold.normal, manifold, dt)
	end

	local extra = manifold.extra

	if extra then
		for i = 1, #extra do
			contact_resolution.ApplyManifoldRestitution(body_a, body_b, extra[i], dt)
		end
	end
end

local function solve_single_manifold_velocity(body_a, body_b, manifold, dt, relax)
	local physics = body_a:GetPhysics()
	local solver = physics.solver

	if manifold.last_warm_step ~= solver.StepStamp then
		manifolds.CaptureRestitutionBias(body_a, body_b, manifold.normal, manifold, solver.CollideStamp)

		if manifold.prepared_step ~= solver.StepStamp then
			manifolds.PrepareContacts(body_a, body_b, manifold.normal, manifold, solver.StepStamp)
		end

		manifolds.WarmStart(body_a, body_b, manifold.normal, manifold, dt)
		manifold.last_warm_step = solver.StepStamp
		solver:QueuePositionPair(body_a, body_b, manifold)

		if manifold.overlap > 0 then
			physics.collision_pairs:RecordCollisionPair(body_a, body_b, manifold.normal, manifold.overlap)
		end
	end

	refresh_pair_materials(solver, body_a, body_b, manifold)
	manifolds.SolveImpulses(
		body_a,
		body_b,
		manifold.normal,
		manifold,
		dt,
		relax,
		manifold.restitution,
		manifold.friction,
		manifold.static_friction
	)
end

function contact_resolution.SolveManifoldVelocity(body_a, body_b, manifold, dt, relax)
	if manifold.idle then
		manifold.last_warm_step = body_a:GetPhysics().solver.StepStamp
	else
		solve_single_manifold_velocity(body_a, body_b, manifold, dt, relax)
	end

	local extra = manifold.extra

	if extra then
		for i = 1, #extra do
			contact_resolution.SolveManifoldVelocity(body_a, body_b, extra[i], dt, relax)
		end
	end
end

function contact_resolution.FinishManifold(body_a, body_b, manifold)
	local contacts = manifold.contacts

	for i = 1, #contacts do
		local contact = contacts[i]

		if i <= 6 then
			contact.point_a = body_a:LocalToWorld(contact.local_point_a, nil, nil, FINISH_WORLD_POINT_A[i])
			contact.point_b = body_b:LocalToWorld(contact.local_point_b, nil, nil, FINISH_WORLD_POINT_B[i])
		else
			contact.point_a = body_a:LocalToWorld(contact.local_point_a)
			contact.point_b = body_b:LocalToWorld(contact.local_point_b)
		end
	end

	if manifold.resolve_options and manifold.resolve_options.skip_grounding then
		return
	end

	local support_tolerance = math.max(body_a:GetPhysics().solver.PENETRATION_SLOP or 0, 0.005)

	if manifold.overlap <= 0 then
		local touching = false

		for i = 1, #contacts do
			if (contacts[i].separation or 0) <= support_tolerance then
				touching = true

				break
			end
		end

		if not touching then return end
	end

	contact_resolution.MarkPairGrounding(body_a, body_b, manifold.normal, manifold.rolling_friction)
	mark_pair_grounding_from_contacts(body_a, body_b, contacts)

	for i = 1, #contacts do
		local contact = contacts[i]

		if (contact.separation or 0) <= support_tolerance then
			accumulate_pair_ground_support(body_a, body_b, manifold.normal, contact.point_a, contact.point_b)
		end
	end
end

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

local function fill_manifold(manifold, body_a, body_b, normal, overlap, contacts, options, solver)
	manifold.last_seen_step = solver.StepStamp
	manifold.idle = false
	manifold.normal = normal:Copy()
	manifold.solve_a = body_a
	manifold.solve_b = body_b
	manifold.overlap = overlap
	manifold.resolve_options = options

	if manifold.last_rebuild_step ~= solver.StepStamp then
		manifolds.RebuildContacts(body_a, body_b, manifold, contacts)
		manifold.prepared_step = nil
		local deepest = -math.huge
		local normal_x, normal_y, normal_z = normal.x, normal.y, normal.z

		for i = 1, #contacts do
			local depth = (
					contacts[i].point_a.x - contacts[i].point_b.x
				) * normal_x + (
					contacts[i].point_a.y - contacts[i].point_b.y
				) * normal_y + (
					contacts[i].point_a.z - contacts[i].point_b.z
				) * normal_z

			if depth > deepest then deepest = depth end
		end

		manifold.depth_offset = overlap - deepest
		manifold.last_rebuild_step = solver.StepStamp
		stats:Count("contact_points", #contacts)
	end
end

local function store_rebuild_pose(manifold, body_a, body_b)
	local pose_a = manifold.rebuild_pose_a or {}
	local pose_b = manifold.rebuild_pose_b or {}
	local position_a = body_a:GetPosition()
	local position_b = body_b:GetPosition()
	local rotation_a = body_a:GetRotation()
	local rotation_b = body_b:GetRotation()
	pose_a.px = position_a.x
	pose_a.py = position_a.y
	pose_a.pz = position_a.z
	pose_a.rx = rotation_a.x
	pose_a.ry = rotation_a.y
	pose_a.rz = rotation_a.z
	pose_a.rw = rotation_a.w
	pose_b.px = position_b.x
	pose_b.py = position_b.y
	pose_b.pz = position_b.z
	pose_b.rx = rotation_b.x
	pose_b.ry = rotation_b.y
	pose_b.rz = rotation_b.z
	pose_b.rw = rotation_b.w
	manifold.rebuild_pose_a = pose_a
	manifold.rebuild_pose_b = pose_b
end

local CLUSTER_MEMBERS = {}
local CLUSTER_USED = {}
local CLUSTER_MATCH_DOT = 0.9
local MAX_CLUSTER_MANIFOLDS = 4

function contact_resolution.ResolvePairClusters(body_a, body_b, clusters, cluster_count, dt, options)
	if body_a.InverseMass + body_b.InverseMass <= 0 then return false end

	local solver = body_a:GetPhysics().solver
	local head = get_pair_manifold(solver.PersistentManifolds, body_a, body_b) or {}
	local extra = head.extra

	if not extra then
		extra = {}
		head.extra = extra
	end

	local members = CLUSTER_MEMBERS
	local used = CLUSTER_USED
	local member_count = 1 + #extra
	members[1] = head

	for i = 1, #extra do
		members[i + 1] = extra[i]
	end

	for i = 1, member_count do
		used[i] = false
	end

	for cluster_index = 1, cluster_count do
		local cluster = clusters[cluster_index]
		local pick = nil
		local best_dot = CLUSTER_MATCH_DOT

		for member_index = 1, member_count do
			local member = members[member_index]

			if not used[member_index] and not member.idle and member.normal then
				local dot = member.normal:Dot(cluster.normal)

				if dot > best_dot then
					best_dot = dot
					pick = member_index
				end
			end
		end

		if not pick then
			for member_index = 1, member_count do
				local member = members[member_index]

				if not used[member_index] and (member.idle or not member.normal) then
					pick = member_index

					break
				end
			end
		end

		if not pick and member_count < MAX_CLUSTER_MANIFOLDS then
			member_count = member_count + 1
			members[member_count] = {idle = true}
			extra[member_count - 1] = members[member_count]
			used[member_count] = false
			pick = member_count
		end

		if pick then
			used[pick] = true
			fill_manifold(
				members[pick],
				body_a,
				body_b,
				cluster.normal,
				cluster.overlap,
				cluster.contacts,
				options,
				solver
			)
		end
	end

	for member_index = 1, member_count do
		local member = members[member_index]

		if not used[member_index] and not member.idle then
			member.idle = true
			member.contacts = {}
			member.overlap = -1
		end
	end

	head.last_seen_step = solver.StepStamp
	head.last_rebuild_step = solver.StepStamp
	head.solve_a = body_a
	head.solve_b = body_b
	store_rebuild_pose(head, body_a, body_b)
	set_pair_manifold(solver.PersistentManifolds, body_a, body_b, head)
	contact_resolution.SolveManifoldVelocity(body_a, body_b, head, dt)
	return true
end

function contact_resolution.ResolvePairPenetration(body_a, body_b, normal, overlap, dt, point_a, point_b, contacts, options)
	local physics = body_a:GetPhysics()
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b
	options = options or EMPTY_OPTIONS

	if inverse_mass_sum <= 0 then return false end

	if not contacts and point_a and point_b then
		SINGLE_CONTACT.point_a = point_a
		SINGLE_CONTACT.point_b = point_b
		contacts = SINGLE_CONTACTS
	end

	if contacts and #contacts > 0 then
		local solver = physics.solver
		local manifold = get_pair_manifold(solver.PersistentManifolds, body_a, body_b) or {}
		fill_manifold(manifold, body_a, body_b, normal, overlap, contacts, options, solver)
		store_rebuild_pose(manifold, body_a, body_b)
		set_pair_manifold(solver.PersistentManifolds, body_a, body_b, manifold)
		contact_resolution.SolveManifoldVelocity(body_a, body_b, manifold, dt)
		return true
	end

	if overlap <= 0 then return false end

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
