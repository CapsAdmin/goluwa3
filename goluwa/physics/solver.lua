local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics/shared.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local contact_services = import("goluwa/physics/contact_services.lua")
local fallback_services = import("goluwa/physics/fallback_solver.lua")
local manifold_services = import("goluwa/physics/manifold.lua")
local shape_helper_services = import("goluwa/physics/shape_accessors.lua")
local register_pair_modules = import("goluwa/physics/pair_solvers/init.lua").RegisterAll
local solver = physics.Solver or {}
physics.Solver = solver
local EPSILON = 0.00001
local MANIFOLD_PRUNE_STEPS = 12
solver.PersistentManifolds = solver.PersistentManifolds or {}
solver.PairHandlers = solver.PairHandlers or {}
solver.MissingPairWarnings = solver.MissingPairWarnings or {}
solver.StepStamp = solver.StepStamp or 0
local contacts
local fallback
local manifolds
local shape_helpers

local function get_pair_restitution(body_a, body_b)
	return math.max(body_a.Restitution or 0, body_b.Restitution or 0)
end

local function get_pair_friction(body_a, body_b)
	return math.sqrt(math.max(body_a.Friction or 0, 0) * math.max(body_b.Friction or 0, 0))
end

function solver:BeginStep()
	self.StepStamp = (self.StepStamp or 0) + 1
	manifolds.PruneOld(self.PersistentManifolds, self.StepStamp, MANIFOLD_PRUNE_STEPS)
end

function solver:RegisterPairHandler(shape_a, shape_b, handler)
	if not self.PairHandlers[shape_a] then self.PairHandlers[shape_a] = {} end

	self.PairHandlers[shape_a][shape_b] = handler
end

function solver:GetPairHandler(shape_a, shape_b)
	return self.PairHandlers[shape_a] and self.PairHandlers[shape_a][shape_b] or nil
end

function solver:WarnMissingPairHandler(shape_a, shape_b)
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

local function solve_rigid_body_pair(body_a, body_b, entry_a, entry_b, dt)
	local shape_a = body_a:GetShapeType()
	local shape_b = body_b:GetShapeType()

	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	local handler = solver:GetPairHandler(shape_a, shape_b)

	if handler then return handler(body_a, body_b, entry_a, entry_b, dt) end

	solver:WarnMissingPairHandler(shape_a, shape_b)
	return fallback.SolveAABBPairCollision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
end

function solver.SolveDistanceConstraints(dt)
	for i = #physics.DistanceConstraints, 1, -1 do
		local constraint = physics.DistanceConstraints[i]

		if constraint and constraint.Enabled ~= false then constraint:Solve(dt) end
	end
end

function solver.SolveRigidBodyPairs(bodies, dt)
	local entries = broadphase.BuildEntries(physics, bodies)

	broadphase.ForEachCandidate(entries, function(a, b)
		solve_rigid_body_pair(a.body, b.body, a, b, dt)
	end)
end

function solver.SolveBodyContacts(body, dt)
	contacts.SolveBodyContacts(body, dt)
end

shape_helpers = shape_helper_services.CreateServices()
contacts = contact_services.CreateServices{
	Vec3 = Vec3,
	Quat = Quat,
	physics = physics,
	EPSILON = EPSILON,
	get_pair_restitution = get_pair_restitution,
	get_pair_friction = get_pair_friction,
	get_persistent_manifolds = function()
		return solver.PersistentManifolds
	end,
	get_step_stamp = function()
		return solver.StepStamp
	end,
	get_manifolds = function()
		return manifolds
	end,
}
fallback = fallback_services.CreateServices{
	Vec3 = Vec3,
	resolve_pair_penetration = contacts.ResolvePairPenetration,
}
manifolds = manifold_services.CreateServices{
	Vec3 = Vec3,
	EPSILON = EPSILON,
	WARM_START_SCALE = 0.9,
	get_pair_restitution = get_pair_restitution,
	get_pair_friction = get_pair_friction,
	get_point_velocity = contacts.GetPointVelocity,
	apply_impulse_to_motion = contacts.ApplyImpulseToMotion,
	set_body_motion_from_current_state = contacts.SetBodyMotionFromCurrentState,
}
register_pair_modules(
	solver,
	{
		Vec3 = Vec3,
		Quat = Quat,
		physics = physics,
		EPSILON = EPSILON,
		clamp = shape_helpers.Clamp,
		get_sign = shape_helpers.GetSign,
		get_sphere_radius = shape_helpers.GetSphereRadius,
		get_box_extents = shape_helpers.GetBoxExtents,
		get_box_axes = shape_helpers.GetBoxAxes,
		get_body_polyhedron = shape_helpers.GetBodyPolyhedron,
		body_has_significant_rotation = shape_helpers.BodyHasSignificantRotation,
		resolve_pair_penetration = contacts.ResolvePairPenetration,
		apply_pair_impulse = contacts.ApplyPairImpulse,
		mark_pair_grounding = contacts.MarkPairGrounding,
	}
)
return solver