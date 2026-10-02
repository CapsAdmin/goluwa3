local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local manifolds = import("goluwa/physics/manifold.lua")
local islands = import("goluwa/physics/islands.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local stats = import("goluwa/physics/stats.lua")
local Solver = objects.CreateTemplate("physics_solver")
import.loaded["goluwa/physics/solver.lua"] = Solver
local COMBINE_MODE_PRIORITY = {
	average = 0,
	min = 1,
	multiply = 2,
	max = 3,
}

local function resolve_pair_combine_mode(mode_a, mode_b)
	if mode_a == mode_b then return mode_a end

	if mode_a == nil then return mode_b end

	if mode_b == nil then return mode_a end

	local priority_a = COMBINE_MODE_PRIORITY[mode_a]
	local priority_b = COMBINE_MODE_PRIORITY[mode_b]

	if priority_a and priority_b then
		if priority_a >= priority_b then return mode_a end

		return mode_b
	end

	if priority_a then return mode_a end

	if priority_b then return mode_b end

	return mode_a
end

local function combine_material_value(value_a, value_b, mode, legacy_mode)
	if mode == "average" then return (value_a + value_b) * 0.5 end

	if mode == "min" then return math.min(value_a, value_b) end

	if mode == "multiply" then return value_a * value_b end

	if mode == "max" then return math.max(value_a, value_b) end

	if legacy_mode == "friction" then return math.sqrt(value_a * value_b) end

	return math.max(value_a, value_b)
end

local function get_collider_sweep_hit(dynamic_body, collider, physics)
	if not (collider and dynamic_body) then return nil end

	stats:Count("sweeps_ccd")
	local previous_position = collider:GetPreviousPosition()
	local current_position = collider:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics_constants.EPSILON then return nil end

	local hit = physics.SweepCollider(
		collider,
		previous_position,
		movement,
		dynamic_body:GetOwner(),
		dynamic_body:GetFilterFunction(),
		{
			Rotation = collider:GetRotation(),
			UseRenderMeshes = false,
		}
	)

	if not (hit and hit.rigid_body and hit.collider and hit.rigid_body ~= dynamic_body) then
		return nil
	end

	return {
		collider = collider,
		hit = hit,
		movement = movement,
		previous_position = previous_position,
		current_position = current_position,
	}
end

local function rewind_body_to_sweep_hit(dynamic_body, sweep_result, physics)
	if
		not (
			dynamic_body and
			sweep_result and
			sweep_result.hit and
			sweep_result.collider
		)
	then
		return nil
	end

	local hit = sweep_result.hit
	local collider = sweep_result.collider
	local movement = sweep_result.movement
	local movement_length = movement:GetLength()

	if movement_length <= physics_constants.EPSILON then return nil end

	local fraction = math.max(0, math.min(hit.fraction or 0, 1))
	local skin = math.max(
		collider:GetCollisionMargin() or 0,
		physics.DefaultCollisionMargin or physics_constants.DEFAULT_COLLISION_MARGIN
	)
	local post_fraction = math.min(1, fraction + skin / movement_length)
	local target_position = sweep_result.previous_position + movement * post_fraction
	local delta = target_position - sweep_result.current_position

	if delta:GetLength() <= physics_constants.EPSILON then return nil end

	dynamic_body:SetPosition(dynamic_body:GetPosition() + delta)
	return delta
end

local function fallback_solve_aabb_pair_collision(body_a, body_b, bounds_a, bounds_b, dt)
	local overlap_x = math.min(bounds_a.max_x, bounds_b.max_x) - math.max(bounds_a.min_x, bounds_b.min_x)
	local overlap_y = math.min(bounds_a.max_y, bounds_b.max_y) - math.max(bounds_a.min_y, bounds_b.min_y)
	local overlap_z = math.min(bounds_a.max_z, bounds_b.max_z) - math.max(bounds_a.min_z, bounds_b.min_z)

	if overlap_x <= 0 or overlap_y <= 0 or overlap_z <= 0 then return end

	local center_delta = body_b:GetPosition() - body_a:GetPosition()
	local normal
	local overlap = overlap_x

	if overlap_y < overlap then
		overlap = overlap_y
		normal = Vec3(0, center_delta.y >= 0 and 1 or -1, 0)
	end

	if overlap_z < overlap then
		overlap = overlap_z
		normal = Vec3(0, 0, center_delta.z >= 0 and 1 or -1)
	end

	if not normal then normal = Vec3(center_delta.x >= 0 and 1 or -1, 0, 0) end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, normal, overlap, dt)
end

function Solver.New(config)
	local self = Solver:CreateObject()
	config = config or {}
	self.physics = config.physics or self.physics
	self.MANIFOLD_PRUNE_STEPS = config.MANIFOLD_PRUNE_STEPS or self.MANIFOLD_PRUNE_STEPS or 12
	self.MANIFOLD_SOLVER_PASSES = config.MANIFOLD_SOLVER_PASSES or self.MANIFOLD_SOLVER_PASSES or 1
	self.RESTING_MANIFOLD_SOLVER_PASSES = config.RESTING_MANIFOLD_SOLVER_PASSES or self.RESTING_MANIFOLD_SOLVER_PASSES or 2
	self.RESTING_MANIFOLD_MIN_CONTACTS = config.RESTING_MANIFOLD_MIN_CONTACTS or self.RESTING_MANIFOLD_MIN_CONTACTS or 3
	self.RESTING_MANIFOLD_MIN_NORMAL_Y = config.RESTING_MANIFOLD_MIN_NORMAL_Y or
		self.RESTING_MANIFOLD_MIN_NORMAL_Y or
		0.65
	self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED = config.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or
		self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or
		1.5
	self.RESTING_MANIFOLD_MAX_TANGENT_SPEED = config.RESTING_MANIFOLD_MAX_TANGENT_SPEED or
		self.RESTING_MANIFOLD_MAX_TANGENT_SPEED or
		0.75
	self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED = config.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or
		self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or
		2.5
	self.PENETRATION_SLOP = config.PENETRATION_SLOP or self.PENETRATION_SLOP or 0.005
	self.LIFT_BREAK_SPEED = config.LIFT_BREAK_SPEED or self.LIFT_BREAK_SPEED or 0.5
	self.CONTACT_HERTZ = config.CONTACT_HERTZ or self.CONTACT_HERTZ or 30
	self.CONTACT_DAMPING_RATIO = config.CONTACT_DAMPING_RATIO or self.CONTACT_DAMPING_RATIO or 10
	self.JOINT_HERTZ = config.JOINT_HERTZ or self.JOINT_HERTZ or 60
	self.JOINT_DAMPING_RATIO = config.JOINT_DAMPING_RATIO or self.JOINT_DAMPING_RATIO or 2
	self.CONTACT_PUSH_SPEED = config.CONTACT_PUSH_SPEED or self.CONTACT_PUSH_SPEED or 3
	self.REBUILD_POSE_THRESHOLD = config.REBUILD_POSE_THRESHOLD or self.REBUILD_POSE_THRESHOLD or 0.01
	self.WARM_START_SCALE = config.WARM_START_SCALE or self.WARM_START_SCALE or 0.9
	self.TANGENT_WARM_START_SCALE = config.TANGENT_WARM_START_SCALE or self.TANGENT_WARM_START_SCALE or 0.1
	self.MAX_TANGENT_WARM_SPEED = config.MAX_TANGENT_WARM_SPEED or self.MAX_TANGENT_WARM_SPEED or 0.25
	self.STATIC_FRICTION_SPEED = config.STATIC_FRICTION_SPEED or self.STATIC_FRICTION_SPEED or 0.08
	self.STATIC_FRICTION_EXIT_SPEED = config.STATIC_FRICTION_EXIT_SPEED or self.STATIC_FRICTION_EXIT_SPEED or 0.12
	self.PersistentManifolds = table.weak("k")
	self.PositionPairCount = 0
	self.PositionPairsA = {}
	self.PositionPairsB = {}
	self.PositionPairManifolds = {}
	self.PairHandlers = {}
	self.MissingPairWarnings = {}
	self.StepStamp = config.StepStamp or 0
	return self
end

function Solver:GetPhysics()
	return self.physics
end

function Solver:ResetState()
	self.PositionPairCount = 0
	table.clear(self.PositionPairsA)
	table.clear(self.PositionPairsB)
	table.clear(self.PositionPairManifolds)
	table.clear(self.PersistentManifolds)
end

function Solver:GetPairRestitution(body_a, body_b)
	local restitution_a = math.max(body_a:GetRestitution() or 0, 0)
	local restitution_b = math.max(body_b:GetRestitution() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRestitutionCombineMode(), body_b:GetRestitutionCombineMode())
	return combine_material_value(restitution_a, restitution_b, mode, "restitution")
end

function Solver:GetPairFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetFriction() or 0, 0)
	local friction_b = math.max(body_b:GetFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetFrictionCombineMode(), body_b:GetFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function Solver:GetBodyStaticFriction(body)
	local static_friction = body:GetStaticFriction()

	if static_friction == nil then static_friction = body:GetFriction() end

	return math.max(static_friction or 0, 0)
end

function Solver:GetPairStaticFriction(body_a, body_b)
	local friction_a = self:GetBodyStaticFriction(body_a)
	local friction_b = self:GetBodyStaticFriction(body_b)
	local mode = resolve_pair_combine_mode(
		body_a:GetStaticFrictionCombineMode() or body_a:GetFrictionCombineMode(),
		body_b:GetStaticFrictionCombineMode() or body_b:GetFrictionCombineMode()
	)
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function Solver:GetPairRollingFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetRollingFriction() or 0, 0)
	local friction_b = math.max(body_b:GetRollingFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRollingFrictionCombineMode(), body_b:GetRollingFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function Solver:GetManifoldSolverPasses(body_a, body_b, normal, manifold_data, restitution)
	local base_passes = math.max(1, self.MANIFOLD_SOLVER_PASSES or 1)
	local resting_passes = math.max(base_passes, self.RESTING_MANIFOLD_SOLVER_PASSES or base_passes)

	if resting_passes <= base_passes then return base_passes end

	local contacts = manifold_data and manifold_data.contacts or nil

	if #(contacts or {}) < math.max(1, self.RESTING_MANIFOLD_MIN_CONTACTS or 1) then
		return base_passes
	end

	if
		math.abs(normal and normal.y or 0) < math.max(0, self.RESTING_MANIFOLD_MIN_NORMAL_Y or 0)
	then
		return base_passes
	end

	if (restitution or self:GetPairRestitution(body_a, body_b)) > 0.05 then
		return base_passes
	end

	local velocity_a = body_a:GetVelocity()
	local velocity_b = body_b:GetVelocity()
	local dx = velocity_b.x - velocity_a.x
	local dy = velocity_b.y - velocity_a.y
	local dz = velocity_b.z - velocity_a.z
	local max_relative_speed = math.max(0, self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or 0)

	if dx * dx + dy * dy + dz * dz > max_relative_speed * max_relative_speed then
		return base_passes
	end

	local normal_dot = dx * normal.x + dy * normal.y + dz * normal.z
	local tangent_x = dx - normal.x * normal_dot
	local tangent_y = dy - normal.y * normal_dot
	local tangent_z = dz - normal.z * normal_dot
	local max_tangent_speed = math.max(0, self.RESTING_MANIFOLD_MAX_TANGENT_SPEED or 0)

	if
		tangent_x * tangent_x + tangent_y * tangent_y + tangent_z * tangent_z > max_tangent_speed * max_tangent_speed
	then
		return base_passes
	end

	local angular_speed_a = body_a:GetAngularVelocity():GetLength()
	local angular_speed_b = body_b:GetAngularVelocity():GetLength()

	if
		math.max(angular_speed_a, angular_speed_b) > math.max(0, self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or 0)
	then
		return base_passes
	end

	return resting_passes
end

function Solver:BeginStep(collide)
	local physics = self:GetPhysics()
	self.StepStamp = (self.StepStamp or 0) + 1

	if collide then self.CollideStamp = self.StepStamp end

	self.PositionPairCount = 0
	manifolds.PruneOld(
		self.PersistentManifolds,
		self.StepStamp,
		self.MANIFOLD_PRUNE_STEPS or Solver.MANIFOLD_PRUNE_STEPS
	)
	local constraints = physics:GetConstraints()

	for i = 1, #constraints do
		constraints[i]:BeginStep()
	end
end

-- manifold pairs solved this substep, in the order the velocity phase first
-- touched them; cleared every substep so no body is kept alive from here
function Solver:QueuePositionPair(body_a, body_b, manifold)
	local count = self.PositionPairCount + 1
	self.PositionPairCount = count
	self.PositionPairsA[count] = body_a
	self.PositionPairsB[count] = body_b
	self.PositionPairManifolds[count] = manifold
end

function Solver:FinishRigidBodyPairs()
	local count = self.PositionPairCount
	local bodies_a = self.PositionPairsA
	local bodies_b = self.PositionPairsB
	local pair_manifolds = self.PositionPairManifolds

	for i = 1, count do
		contact_resolution.FinishManifold(bodies_a[i], bodies_b[i], pair_manifolds[i])
		bodies_a[i] = nil
		bodies_b[i] = nil
		pair_manifolds[i] = nil
	end

	self.PositionPairCount = 0
end

function Solver:RegisterPairHandler(shape_a, shape_b, handler)
	if not self.PairHandlers[shape_a] then self.PairHandlers[shape_a] = {} end

	self.PairHandlers[shape_a][shape_b] = {callback = handler, name = "pairs_" .. shape_a .. "-" .. shape_b}
end

function Solver:GetPairHandler(shape_a, shape_b)
	return self.PairHandlers[shape_a] and self.PairHandlers[shape_a][shape_b] or nil
end

function Solver:WarnMissingPairHandler(shape_a, shape_b)
	local key = tostring(shape_a) .. "|" .. tostring(shape_b)

	if self.MissingPairWarnings[key] then return end

	self.MissingPairWarnings[key] = true

	if wlog then
		wlog(
			string.format(
				"missing rigid body pair solver for %s vs %s",
				tostring(shape_a),
				tostring(shape_b)
			),
			2
		)
	elseif logn then
		logn(
			string.format(
				"missing rigid body pair solver for %s vs %s",
				tostring(shape_a),
				tostring(shape_b)
			)
		)
	end
end

-- Joints are soft constraints solved at velocity level next to the contacts:
-- the biased call (relax false) pulls the error in with the joint softness,
-- the relax calls solve rigidly with no bias.
function Solver:SolveConstraints(dt, constraints_override, relax)
	local physics = self:GetPhysics()
	local constraints = constraints_override or physics:GetConstraints()
	local omega = 2 * math.pi * math.min(self.JOINT_HERTZ, 0.25 / dt)
	local a1 = 2 * self.JOINT_DAMPING_RATIO + dt * omega
	local impulse_scale = 1 / (1 + dt * omega * a1)
	local bias_rate = omega / a1

	for i = #constraints, 1, -1 do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false then
			constraint:Solve(dt, relax, bias_rate, impulse_scale)
		end
	end
end

local RECYCLE_POSE_THRESHOLD = 0.005
local RECYCLE_ROTATION_DOT = 0.99995
local REBUILD_ROTATION_DOT = 0.995

function Solver:SolveRigidBodyPairs(bodies_or_pairs, dt, pass, relax)
	local pairs = bodies_or_pairs

	if not (pairs and pairs[1] and pairs[1].entry_a and pairs[1].entry_b) then
		-- empty list has nothing to solve; rebuilding the broadphase with an
		-- empty body list would also wipe its tracked entries
		if not (pairs and pairs[1]) then return end

		local physics = self:GetPhysics()
		pairs = physics.broadphase:BuildCandidatePairs(bodies_or_pairs)
	end

	stats:Count("solver_pairs", #pairs)
	local cached_iteration = (pass or 1) > 1
	local reuse_manifolds = cached_iteration or self.CollideStamp ~= self.StepStamp
	local persistent_manifolds = self.PersistentManifolds
	local rebuild_pose_threshold = self.REBUILD_POSE_THRESHOLD or 0.01
	local squared_rebuild_pose_threshold = rebuild_pose_threshold * rebuild_pose_threshold
	local squared_recycle_pose_threshold = RECYCLE_POSE_THRESHOLD * RECYCLE_POSE_THRESHOLD

	for i = 1, #pairs do
		local pair = pairs[i]
		local entry_a = pair.entry_a
		local entry_b = pair.entry_b
		local body_a = entry_a.body
		local body_b = entry_b.body
		local physics = self:GetPhysics()
		local handled = false

		if relax then
			-- the relax pass only re-solves manifolds the substep already
			-- touched, it never runs the narrowphase
			local manifold = contact_resolution.GetPairManifold(persistent_manifolds, body_a, body_b)

			if manifold and manifold.last_warm_step == self.StepStamp then
				contact_resolution.SolveManifoldVelocity(body_a, body_b, manifold, dt, true)
			elseif
				not (
					pair_solver_helpers.IsSimpleBody(body_a:GetColliders()) and
					pair_solver_helpers.IsSimpleBody(body_b:GetColliders())
				)
			then
				pair_solver_helpers.DispatchColliderPairs(self, pair, dt, "relax")
			end
		-- pairs that found no contact in the first iteration of this substep stay
		-- skipped, bodies only move by small corrections between iterations
		elseif cached_iteration and pair.idle_stamp == self.StepStamp then
			stats:Count("solver_pairs_idle")
		elseif body_a:ShouldCollide(body_b) then
			if reuse_manifolds then
				local manifold = contact_resolution.GetPairManifold(persistent_manifolds, body_a, body_b)

				-- a manifold from an earlier step is recycled while both bodies
				-- stay inside a tighter pose tolerance than within a step
				if manifold and manifold.last_rebuild_step >= 0 then
					manifold.last_seen_step = self.StepStamp
					local recycled = manifold.last_rebuild_step < self.CollideStamp
					local geometry_stale = pair_solver_helpers.IsPoseInvalidated(
							body_a,
							manifold.rebuild_pose_a,
							recycled and squared_recycle_pose_threshold or squared_rebuild_pose_threshold,
							recycled and RECYCLE_ROTATION_DOT or REBUILD_ROTATION_DOT
						) or
						pair_solver_helpers.IsPoseInvalidated(
							body_b,
							manifold.rebuild_pose_b,
							recycled and squared_recycle_pose_threshold or squared_rebuild_pose_threshold,
							recycled and RECYCLE_ROTATION_DOT or REBUILD_ROTATION_DOT
						)

					if geometry_stale then
						-- force the full dispatch to rebuild the manifold from the
						-- current pose
						manifold.last_rebuild_step = -1
					else
						stats:Count(recycled and "solver_pairs_recycled" or "solver_pairs_cached")
						contact_resolution.SolveManifoldVelocity(body_a, body_b, manifold, dt, relax)
						handled = true
					end
				end
			end

			if not handled then
				local colliders_a = body_a:GetColliders()
				local colliders_b = body_b:GetColliders()

				if
					pair_solver_helpers.IsSimpleBody(colliders_a) and
					pair_solver_helpers.IsSimpleBody(colliders_b)
				then
					local result, found = pair_solver_helpers.TryInvokePairHandler(self, body_a, body_b, entry_a, entry_b, dt)

					if not found then
						stats:Count("pairs_fallback")
						fallback_solve_aabb_pair_collision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
					elseif not cached_iteration and not result then
						pair.idle_stamp = self.StepStamp
					end
				else
					pair_solver_helpers.DispatchColliderPairs(self, pair, dt, reuse_manifolds and "reuse" or "collide")
				end
			end
		end
	end
end

-- bounces every pair the step solved; pairs is the same list the substeps used
function Solver:ApplyRestitution(pairs, dt)
	for i = 1, #pairs do
		local body_a = pairs[i].entry_a.body
		local body_b = pairs[i].entry_b.body
		local manifold = contact_resolution.GetPairManifold(self.PersistentManifolds, body_a, body_b)

		if manifold and manifold.last_warm_step >= self.CollideStamp then
			contact_resolution.ApplyManifoldRestitution(body_a, body_b, manifold, dt)
		end
	end
end

function Solver:IslandPairFilter(pair)
	local body_a = pair.entry_a.body
	local body_b = pair.entry_b.body

	if body_a:GetAwake() or body_b:GetAwake() then return true end

	-- compound bodies key their manifolds by collider, so a body-level
	-- lookup cannot prove the pair is untouched; keep those links
	if #body_a:GetColliders() > 1 or #body_b:GetColliders() > 1 then
		return true
	end

	return contact_resolution.GetPairManifold(self.PersistentManifolds, body_a, body_b) ~= nil
end

function Solver:SolveBodyContacts(body, dt)
	if not (body and body.CollisionEnabled) then return false end

	if not pair_solver_helpers.ShouldSweepBody(body) then return false end

	local physics = self:GetPhysics()
	local best = nil

	for _, collider in ipairs(body:GetColliders() or {}) do
		local sweep_hit = get_collider_sweep_hit(body, collider, physics)

		if
			sweep_hit and
			(
				(
					not best
				) or
				(
					sweep_hit.hit.fraction or
					1
				) < (
					best.hit.fraction or
					1
				)
			)
		then
			best = sweep_hit
		end
	end

	if not best then return false end

	local target_body = best.hit and best.hit.rigid_body or nil

	if
		not (
			target_body and
			best.hit and
			best.hit.normal and
			body:ShouldCollide(target_body)
		)
	then
		return false
	end

	return pair_solver_helpers.ResolveSweptHit(
		target_body,
		body,
		best.previous_position,
		best.movement,
		{
			t = best.hit.fraction or best.hit.t or 0,
			normal = best.hit.normal,
		},
		dt,
		true
	)
end

Solver:Register()
return Solver
