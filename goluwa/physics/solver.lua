local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local Solver = prototype.CreateTemplate("physics_solver")
import.loaded["goluwa/physics/solver.lua"] = Solver
Solver.MANIFOLD_PRUNE_STEPS = Solver.MANIFOLD_PRUNE_STEPS or 12
Solver.WARM_START_SCALE = Solver.WARM_START_SCALE or 0.9
Solver.TANGENT_WARM_START_SCALE = Solver.TANGENT_WARM_START_SCALE or 0.1
Solver.MAX_TANGENT_WARM_SPEED = Solver.MAX_TANGENT_WARM_SPEED or 0.25
Solver.PairHandlers = Solver.PairHandlers or {}
Solver.PersistentManifolds = Solver.PersistentManifolds or {}
Solver.MissingPairWarnings = Solver.MissingPairWarnings or {}
Solver.StepStamp = Solver.StepStamp or 0

local function clone_pair_handlers(source)
	local out = {}

	for shape_a, handlers in pairs(source or {}) do
		out[shape_a] = {}

		for shape_b, handler in pairs(handlers) do
			out[shape_a][shape_b] = handler
		end
	end

	return out
end

function Solver.New(config)
	local self = Solver:CreateObject()
	return self:Initialize(config)
end

function Solver:Initialize(config)
	config = config or {}
	self.physics = config.physics or self.physics or physics
	self.MANIFOLD_PRUNE_STEPS = config.MANIFOLD_PRUNE_STEPS or self.MANIFOLD_PRUNE_STEPS or Solver.MANIFOLD_PRUNE_STEPS
	self.WARM_START_SCALE = config.WARM_START_SCALE or self.WARM_START_SCALE or Solver.WARM_START_SCALE
	self.TANGENT_WARM_START_SCALE = config.TANGENT_WARM_START_SCALE or self.TANGENT_WARM_START_SCALE or Solver.TANGENT_WARM_START_SCALE
	self.MAX_TANGENT_WARM_SPEED = config.MAX_TANGENT_WARM_SPEED or self.MAX_TANGENT_WARM_SPEED or Solver.MAX_TANGENT_WARM_SPEED
	self.PersistentManifolds = config.PersistentManifolds or {}
	self.PairHandlers = clone_pair_handlers(config.PairHandlers or Solver.PairHandlers)
	self.MissingPairWarnings = config.MissingPairWarnings or {}
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

function Solver:GetPairRollingFriction(body_a, body_b)
	local friction_a = math.max(body_a:GetRollingFriction() or 0, 0)
	local friction_b = math.max(body_b:GetRollingFriction() or 0, 0)
	local mode = resolve_pair_combine_mode(body_a:GetRollingFrictionCombineMode(), body_b:GetRollingFrictionCombineMode())
	return combine_material_value(friction_a, friction_b, mode, "friction")
end

local contact_resolution = import("goluwa/physics/contact_resolution.lua")

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

local manifolds = import("goluwa/physics/manifold.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local islands = import("goluwa/physics/islands.lua")

function Solver:BeginStep()
	local physics = self:GetPhysics()
	self.StepStamp = (self.StepStamp or 0) + 1
	manifolds.PruneOld(self.PersistentManifolds, self.StepStamp, self.MANIFOLD_PRUNE_STEPS or Solver.MANIFOLD_PRUNE_STEPS)
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

local function is_simple_body(physics, collider_list)
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


local function solve_rigid_body_pair(self, body_a, body_b, entry_a, entry_b, dt)
	local physics = self:GetPhysics()

	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	local colliders_a = body_a:GetColliders()
	local colliders_b = body_b:GetColliders()

	if is_simple_body(physics, colliders_a) and is_simple_body(physics, colliders_b) then
		local shape_a = body_a:GetShapeType()
		local shape_b = body_b:GetShapeType()
		local handler = self:GetPairHandler(shape_a, shape_b)

		if handler then return handler(body_a, body_b, entry_a, entry_b, dt) end

		self:WarnMissingPairHandler(shape_a, shape_b)
		return fallback_solve_aabb_pair_collision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
	end

	local handled = false

	for _, collider_a in ipairs(colliders_a) do
		for _, collider_b in ipairs(colliders_b) do
			if physics.ShouldBodiesCollide(collider_a, collider_b) then
				local shape_a = collider_a:GetShapeType()
				local shape_b = collider_b:GetShapeType()
				local handler = self:GetPairHandler(shape_a, shape_b)

				if handler then
					if handler(collider_a, collider_b, entry_a, entry_b, dt) then handled = true end
				else
					self:WarnMissingPairHandler(shape_a, shape_b)
				end
			end
		end
	end

	return handled
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
		pairs = broadphase.BuildCandidatePairs(physics, bodies_or_pairs)
	end

	for i = 1, #pairs do
		local pair = pairs[i]
		local entry_a = pair.entry_a
		local entry_b = pair.entry_b
		solve_rigid_body_pair(self, entry_a.body, entry_b.body, entry_a, entry_b, dt)
	end
end

function Solver:SolveBodyContacts(body, dt)
	world_contacts.SolveBodyContacts(body, dt)
end

Solver:Register()

import("goluwa/physics/pair_solvers/polyhedron.lua")
import("goluwa/physics/pair_solvers/sphere.lua")
import("goluwa/physics/pair_solvers/capsule.lua")
import("goluwa/physics/pair_solvers/box.lua")
return Solver
