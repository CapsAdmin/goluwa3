local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local Solver = prototype.CreateTemplate("physics_solver")
import.loaded["goluwa/physics/solver.lua"] = Solver

function Solver.New(config)
	local self = Solver:CreateObject()
	config = config or {}
	self.physics = config.physics or self.physics or physics
	self.MANIFOLD_PRUNE_STEPS = config.MANIFOLD_PRUNE_STEPS or self.MANIFOLD_PRUNE_STEPS or 12
	self.MANIFOLD_SOLVER_PASSES = config.MANIFOLD_SOLVER_PASSES or self.MANIFOLD_SOLVER_PASSES or 1
	self.RESTING_MANIFOLD_SOLVER_PASSES = config.RESTING_MANIFOLD_SOLVER_PASSES or self.RESTING_MANIFOLD_SOLVER_PASSES or 2
	self.RESTING_MANIFOLD_MIN_CONTACTS = config.RESTING_MANIFOLD_MIN_CONTACTS or self.RESTING_MANIFOLD_MIN_CONTACTS or 3
	self.RESTING_MANIFOLD_MIN_NORMAL_Y = config.RESTING_MANIFOLD_MIN_NORMAL_Y or self.RESTING_MANIFOLD_MIN_NORMAL_Y or 0.65
	self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED = config.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or 1.5
	self.RESTING_MANIFOLD_MAX_TANGENT_SPEED = config.RESTING_MANIFOLD_MAX_TANGENT_SPEED or self.RESTING_MANIFOLD_MAX_TANGENT_SPEED or 0.75
	self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED = config.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or 2.5
	self.PENETRATION_SLOP = config.PENETRATION_SLOP or self.PENETRATION_SLOP or 0.005
	self.POSITIONAL_CORRECTION_FACTOR = config.POSITIONAL_CORRECTION_FACTOR or self.POSITIONAL_CORRECTION_FACTOR or 0.9
	self.MAX_POSITIONAL_CORRECTION = config.MAX_POSITIONAL_CORRECTION or self.MAX_POSITIONAL_CORRECTION or 0.5
	self.MAX_DEPENETRATION_SPEED = config.MAX_DEPENETRATION_SPEED or self.MAX_DEPENETRATION_SPEED or 24
	self.WARM_START_SCALE = config.WARM_START_SCALE or self.WARM_START_SCALE or 0.9
	self.TANGENT_WARM_START_SCALE = config.TANGENT_WARM_START_SCALE or self.TANGENT_WARM_START_SCALE or 0.1
	self.MAX_TANGENT_WARM_SPEED = config.MAX_TANGENT_WARM_SPEED or self.MAX_TANGENT_WARM_SPEED or 0.25
	self.STATIC_FRICTION_SPEED = config.STATIC_FRICTION_SPEED or self.STATIC_FRICTION_SPEED or 0.08
	self.STATIC_FRICTION_EXIT_SPEED = config.STATIC_FRICTION_EXIT_SPEED or self.STATIC_FRICTION_EXIT_SPEED or 0.12
	self.PersistentManifolds = setmetatable({}, {__mode = "k"})
	self.PairHandlers = {}
	self.MissingPairWarnings = {}
	self.StepStamp = config.StepStamp or 0
	return self
end

function Solver:GetPhysics()
	return self.physics or physics
end

function Solver:ResetState()
	table.clear(self.PersistentManifolds)
end

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
	local static_friction = body.GetStaticFriction and body:GetStaticFriction() or nil

	if static_friction == nil then
		static_friction = body.GetFriction and body:GetFriction() or body.Friction or 0
	end

	return math.max(static_friction or 0, 0)
end

function Solver:GetPairStaticFriction(body_a, body_b)
	local friction_a = self:GetBodyStaticFriction(body_a)
	local friction_b = self:GetBodyStaticFriction(body_b)
	local mode = resolve_pair_combine_mode(
		body_a.GetStaticFrictionCombineMode and
			body_a:GetStaticFrictionCombineMode() or
			body_a.GetFrictionCombineMode and
			body_a:GetFrictionCombineMode()
			or
			nil,
		body_b.GetStaticFrictionCombineMode and
			body_b:GetStaticFrictionCombineMode() or
			body_b.GetFrictionCombineMode and
			body_b:GetFrictionCombineMode()
			or
			nil
	)
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function Solver:GetPairRollingFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetRollingFriction() or 0, 0)
	local friction_b = math.max(body_b:GetRollingFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRollingFrictionCombineMode(), body_b:GetRollingFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function Solver:ShouldUseStaticFriction(contact, tangent_speed, tangent_impulse_length, max_static_impulse)
	local enter_speed = math.max(self.STATIC_FRICTION_SPEED or 0, 0)
	local exit_speed = math.max(self.STATIC_FRICTION_EXIT_SPEED or enter_speed, enter_speed)
	max_static_impulse = math.max(max_static_impulse or 0, 0)

	if
		max_static_impulse > 0 and
		(
			tangent_impulse_length or
			math.huge
		) <= max_static_impulse
	then
		return true
	end

	if tangent_speed <= enter_speed then return true end

	return contact and
		contact.static_friction_active == true and
		tangent_speed <= exit_speed or
		false
end

function Solver:GetManifoldSolverPasses(body_a, body_b, normal, manifold_data)
	local base_passes = math.max(1, self.MANIFOLD_SOLVER_PASSES or 1)
	local resting_passes = math.max(base_passes, self.RESTING_MANIFOLD_SOLVER_PASSES or base_passes)

	if resting_passes <= base_passes then return base_passes end

	local contacts = manifold_data and manifold_data.contacts or nil

	if #(contacts or {}) < math.max(1, self.RESTING_MANIFOLD_MIN_CONTACTS or 1) then return base_passes end

	if math.abs(normal and normal.y or 0) < math.max(0, self.RESTING_MANIFOLD_MIN_NORMAL_Y or 0) then return base_passes end

	if self:GetPairRestitution(body_a, body_b) > 0.05 then return base_passes end

	local velocity_a = body_a.GetVelocity and body_a:GetVelocity() or Vec3()
	local velocity_b = body_b.GetVelocity and body_b:GetVelocity() or Vec3()
	local relative_velocity = velocity_b - velocity_a

	if relative_velocity:GetLength() > math.max(0, self.RESTING_MANIFOLD_MAX_RELATIVE_SPEED or 0) then return base_passes end

	local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)

	if tangent_velocity:GetLength() > math.max(0, self.RESTING_MANIFOLD_MAX_TANGENT_SPEED or 0) then return base_passes end

	local angular_speed_a = body_a.GetAngularVelocity and body_a:GetAngularVelocity():GetLength() or 0
	local angular_speed_b = body_b.GetAngularVelocity and body_b:GetAngularVelocity():GetLength() or 0

	if math.max(angular_speed_a, angular_speed_b) > math.max(0, self.RESTING_MANIFOLD_MAX_ANGULAR_SPEED or 0) then
		return base_passes
	end

	return resting_passes
end

local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local manifolds = import("goluwa/physics/manifold.lua")
local islands = import("goluwa/physics/islands.lua")

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

local function get_collider_sweep_hit(dynamic_body, collider)
	if not (physics.SweepCollider and collider and dynamic_body) then return nil end

	local previous_position = collider:GetPreviousPosition()
	local current_position = collider:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return nil end

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

	if not (hit and hit.rigid_body and hit.collider and hit.rigid_body ~= dynamic_body) then return nil end

	return {
		collider = collider,
		hit = hit,
		movement = movement,
		previous_position = previous_position,
		current_position = current_position,
	}
end

local function rewind_body_to_sweep_hit(dynamic_body, sweep_result)
	if not (dynamic_body and sweep_result and sweep_result.hit and sweep_result.collider) then return nil end

	local hit = sweep_result.hit
	local collider = sweep_result.collider
	local movement = sweep_result.movement
	local movement_length = movement:GetLength()

	if movement_length <= physics.EPSILON then return nil end

	local fraction = math.max(0, math.min(hit.fraction or 0, 1))
	local skin = math.max(collider:GetCollisionMargin() or 0, physics.DefaultSkin or 0)
	local post_fraction = math.min(1, fraction + skin / movement_length)
	local target_position = sweep_result.previous_position + movement * post_fraction
	local delta = target_position - sweep_result.current_position

	if delta:GetLength() <= physics.EPSILON then return nil end

	dynamic_body:SetPosition(dynamic_body:GetPosition() + delta)
	return delta
end

local function solve_body_swept_contacts(solver, body, dt)
	if not (body and body.CollisionEnabled) then return false end

	local best = nil

	for _, collider in ipairs(body:GetColliders() or {}) do
		local sweep_hit = get_collider_sweep_hit(body, collider)

		if sweep_hit and ((not best) or (sweep_hit.hit.fraction or 1) < (best.hit.fraction or 1)) then
			best = sweep_hit
		end
	end

	if not best then return false end

	local original_position = body:GetPosition():Copy()
	local delta = rewind_body_to_sweep_hit(body, best)

	if not delta then return false end

	local target_body = best.hit and best.hit.rigid_body or nil
	local target_collider = best.hit and best.hit.collider or nil

	if not (target_body and target_collider and physics.ShouldBodiesCollide(body, target_body)) then
		body:SetPosition(original_position)
		return false
	end

	local solved = pair_solver_helpers.DispatchColliderPairs(
		solver,
		body:GetShapeType() == "compound" and body:GetColliders() or {body},
		{target_collider},
		nil,
		nil,
		dt
	)

	if not solved then
		body:SetPosition(original_position)
		return false
	end

	return true
end

function Solver:BeginStep()
	local physics = self:GetPhysics()
	self.StepStamp = (self.StepStamp or 0) + 1
	manifolds.PruneOld(
		self.PersistentManifolds,
		self.StepStamp,
		self.MANIFOLD_PRUNE_STEPS or Solver.MANIFOLD_PRUNE_STEPS
	)
	local constraints = physics.GetConstraints()

	for i = 1, #constraints do
		local constraint = constraints[i]

		if constraint and constraint.BeginStep then constraint:BeginStep() end
	end
end

function Solver:RegisterPairHandler(shape_a, shape_b, handler)
	if not self.PairHandlers[shape_a] then self.PairHandlers[shape_a] = {} end

	self.PairHandlers[shape_a][shape_b] = handler
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

local function solve_rigid_body_pair(self, body_a, body_b, entry_a, entry_b, dt)
	local physics = self:GetPhysics()

	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	local colliders_a = body_a:GetColliders()
	local colliders_b = body_b:GetColliders()

	if
		pair_solver_helpers.IsSimpleBody(colliders_a) and
		pair_solver_helpers.IsSimpleBody(colliders_b)
	then
		local handled, found = pair_solver_helpers.TryInvokePairHandler(self, body_a, body_b, entry_a, entry_b, dt)

		if found then return handled end

		return fallback_solve_aabb_pair_collision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
	end

	return pair_solver_helpers.DispatchColliderPairs(self, colliders_a, colliders_b, entry_a, entry_b, dt)
end

function Solver:SolveDistanceConstraints(dt, constraints_override)
	local physics = self:GetPhysics()
	local constraints = constraints_override or physics.GetConstraints()

	for i = #constraints, 1, -1 do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false then constraint:Solve(dt) end
	end
end

Solver.SolveConstraints = Solver.SolveDistanceConstraints

function Solver:SolveRigidBodyPairs(bodies_or_pairs, dt)
	local pairs = bodies_or_pairs

	if not (pairs and pairs[1] and pairs[1].entry_a and pairs[1].entry_b) then
		local physics = self:GetPhysics()
		pairs = physics.broadphase:BuildCandidatePairs(bodies_or_pairs)
	end

	for i = 1, #pairs do
		local pair = pairs[i]
		local entry_a = pair.entry_a
		local entry_b = pair.entry_b
		solve_rigid_body_pair(self, entry_a.body, entry_b.body, entry_a, entry_b, dt)
	end
end

function Solver:SolveBodyContacts(body, dt)
	return solve_body_swept_contacts(self, body, dt)
end

Solver:Register()
return Solver
