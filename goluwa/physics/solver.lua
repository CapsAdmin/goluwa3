local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local solver = physics.Solver or {}
physics.Solver = solver
import.loaded["goluwa/physics/solver.lua"] = solver

local MANIFOLD_PRUNE_STEPS = solver.MANIFOLD_PRUNE_STEPS or 12
solver.MANIFOLD_PRUNE_STEPS = MANIFOLD_PRUNE_STEPS
solver.WARM_START_SCALE = solver.WARM_START_SCALE or 0.9
solver.PersistentManifolds = solver.PersistentManifolds or {}
solver.PairHandlers = solver.PairHandlers or {}
solver.MissingPairWarnings = solver.MissingPairWarnings or {}
solver.StepStamp = solver.StepStamp or 0
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

function solver.GetPairRestitution(body_a, body_b)
	local restitution_a = math.max(body_a:GetRestitution() or 0, 0)
	local restitution_b = math.max(body_b:GetRestitution() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRestitutionCombineMode(), body_b:GetRestitutionCombineMode())
	return combine_material_value(restitution_a, restitution_b, mode, "restitution")
end

function solver.GetPairFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetFriction() or 0, 0)
	local friction_b = math.max(body_b:GetFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetFrictionCombineMode(), body_b:GetFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

function solver.GetPairRollingFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetRollingFriction() or 0, 0)
	local friction_b = math.max(body_b:GetRollingFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRollingFrictionCombineMode(), body_b:GetRollingFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

local fallback = import("goluwa/physics/fallback_solver.lua")
local manifolds = import("goluwa/physics/manifold.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local islands = import("goluwa/physics/islands.lua")

function solver:BeginStep()
	self.StepStamp = (self.StepStamp or 0) + 1
	manifolds.PruneOld(self.PersistentManifolds, self.StepStamp, MANIFOLD_PRUNE_STEPS)
	local constraints = physics.Constraints or physics.DistanceConstraints or {}

	for i = 1, #constraints do
		local constraint = constraints[i]

		if constraint and constraint.BeginStep then constraint:BeginStep() end
	end
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

local function is_simple_body(collider_list)
	if #collider_list ~= 1 then return false end

	local collider = collider_list[1]
	local local_position = collider:GetLocalPosition()
	local local_rotation = collider:GetLocalRotation()
	return local_position:GetLength() <= physics.EPSILON and
		math.abs(local_rotation.x) <= physics.EPSILON and
		math.abs(local_rotation.y) <= physics.EPSILON and
		math.abs(local_rotation.z) <= physics.EPSILON and
		math.abs(local_rotation.w - 1) <= physics.EPSILON
end

local function solve_rigid_body_pair(body_a, body_b, entry_a, entry_b, dt)
	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	local colliders_a = body_a:GetColliders()
	local colliders_b = body_b:GetColliders()

	if is_simple_body(colliders_a) and is_simple_body(colliders_b) then
		local shape_a = body_a:GetShapeType()
		local shape_b = body_b:GetShapeType()
		local handler = solver:GetPairHandler(shape_a, shape_b)

		if handler then return handler(body_a, body_b, entry_a, entry_b, dt) end

		solver:WarnMissingPairHandler(shape_a, shape_b)
		return fallback.SolveAABBPairCollision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
	end

	local handled = false

	for _, collider_a in ipairs(colliders_a) do
		for _, collider_b in ipairs(colliders_b) do
			if physics.ShouldBodiesCollide(collider_a, collider_b) then
				local shape_a = collider_a:GetShapeType()
				local shape_b = collider_b:GetShapeType()
				local handler = solver:GetPairHandler(shape_a, shape_b)

				if handler then
					if handler(collider_a, collider_b, entry_a, entry_b, dt) then handled = true end
				else
					solver:WarnMissingPairHandler(shape_a, shape_b)
				end
			end
		end
	end

	return handled
end

function solver.SolveDistanceConstraints(dt, constraints_override)
	local constraints = constraints_override or physics.Constraints or physics.DistanceConstraints or {}

	for i = #constraints, 1, -1 do
		local constraint = constraints[i]

		if constraint and constraint.Enabled ~= false then constraint:Solve(dt) end
	end
end

solver.SolveConstraints = solver.SolveDistanceConstraints

function solver.BuildBroadphasePairs(bodies)
	return broadphase.BuildCandidatePairs(physics, bodies)
end

function solver.BuildSimulationIslands(bodies, pairs, constraints)
	return islands.BuildSimulationIslands(bodies, pairs, constraints)
end

function solver.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
	return islands.PrepareSimulationIslands(simulation_islands, newly_awoken_bodies)
end

function solver.FinalizeSimulationIslands(simulation_islands)
	return islands.FinalizeSimulationIslands(simulation_islands)
end

function solver.IsSimulationIslandSleeping(island)
	return islands.IsSleepingIsland(island)
end

function solver.SolveRigidBodyPairs(bodies_or_pairs, dt)
	local pairs = bodies_or_pairs

	if not (pairs and pairs[1] and pairs[1].entry_a and pairs[1].entry_b) then
		pairs = broadphase.BuildCandidatePairs(physics, bodies_or_pairs)
	end

	for i = 1, #pairs do
		local pair = pairs[i]
		local entry_a = pair.entry_a
		local entry_b = pair.entry_b
		solve_rigid_body_pair(entry_a.body, entry_b.body, entry_a, entry_b, dt)
	end
end

function solver.SolveBodyContacts(body, dt)
	world_contacts.SolveBodyContacts(body, dt)
end

import("goluwa/physics/pair_solvers/polyhedron.lua")
import("goluwa/physics/pair_solvers/sphere.lua")
import("goluwa/physics/pair_solvers/capsule.lua")
import("goluwa/physics/pair_solvers/box.lua")
return solver