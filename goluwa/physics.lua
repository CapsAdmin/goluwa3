local singleton = {}
import.loaded["goluwa/physics.lua"] = singleton
local prototype = import("goluwa/prototype.lua")
local Broadphase = import("goluwa/physics/broadphase.lua")
local CollisionPairs = import("goluwa/physics/collision_pairs.lua")
import("goluwa/physics/convex_hull.lua")
local sweep = import("goluwa/physics/sweep.lua")
local trace = import("goluwa/physics/trace.lua")
local constraint = import("goluwa/physics/constraint.lua")
local Solver = import("goluwa/physics/solver.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local mesh_polyhedron_contacts = import("goluwa/physics/mesh_polyhedron_contacts.lua")
local world_step = import("goluwa/physics/world_step.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local Physics = prototype.CreateTemplate("physics_engine")
Physics.EPSILON = physics_constants.EPSILON

function Physics.New(config)
	config = config or {}
	local self = Physics:CreateObject(config.instance)
	-- todo
	self.FixedTimeStep = config.FixedTimeStep or (1 / 30)
	self.RigidBodyIterations = config.RigidBodyIterations or 1
	self.RigidBodySubsteps = config.RigidBodySubsteps or 1
	self.Gravity = config.Gravity or Vec3(0, -28, 0)
	self.Up = config.Up or Vec3(0, 1, 0)
	self.DefaultCollisionMargin = config.DefaultCollisionMargin or physics_constants.DEFAULT_COLLISION_MARGIN
	self.MaxFrameTime = config.MaxFrameTime or 0.1
	self.FrameAccumulator = config.FrameAccumulator or 0
	self.InterpolationAlpha = config.InterpolationAlpha or 0

	do
		self.RayCast = trace.RayCast
		self.GetHitNormal = trace.GetHitNormal
		self.GetHitSurfaceContact = trace.GetHitSurfaceContact
		self.SweepCollider = sweep.SweepCollider
		self.Sweep = sweep.Sweep
		self.SphereCast = sweep.Sweep
		self.ShapeCast = sweep.SweepCollider
		self.GetConstraints = constraint.GetConstraints
		self.RemoveAllConstraints = constraint.RemoveAllConstraints
		self.ResetState = function()
			self:_ResetState()
		end
		self.GetInterpolationAlpha = function()
			self:_GetInterpolationAlpha()
		end
		self.Step = function(dt)
			return world_step.Step(self, dt)
		end
		self.Update = function(dt)
			return world_step.Update(self, dt)
		end
		self.UpdateFixed = function(dt)
			return world_step.UpdateFixed(self, dt)
		end
		self.UpdateRigidBodies = function(dt)
			return world_step.UpdateRigidBodies(self, dt)
		end
		self:AddGlobalEvent("Update")
	end

	self.solver = self:CreateSolver()
	self.collision_pairs = self:CreateCollisionPairs()
	self.broadphase = self:CreateBroadphase()
	self:RegisterPairHandlers(self.solver)
	return self
end

function Physics:OnUpdate(dt)
	self.UpdateFixed(dt)
end

function Physics:_GetInterpolationAlpha()
	return math.min(math.max(self.InterpolationAlpha or 0, 0), 1)
end

function Physics:_ResetState()
	local collision_pairs = self.collision_pairs or self:CreateCollisionPairs()
	local broadphase = self.broadphase or self:CreateBroadphase()
	local solver = self.solver or self:CreateSolver()
	local constraints = self.GetConstraints and self.GetConstraints() or nil
	self.collision_pairs = collision_pairs
	self.broadphase = broadphase
	self.solver = solver
	self:RegisterPairHandlers(solver)
	collision_pairs:ResetState()
	broadphase:ResetState()
	solver:ResetState()

	if constraints then
		for i = #constraints, 1, -1 do
			local constraint_obj = constraints[i]

			if not (constraint_obj and constraint_obj.IsValid and constraint_obj:IsValid()) then
				table.remove(constraints, i)
			end
		end
	end
end

import("goluwa/physics/rigid_body.lua")

function Physics:RegisterPairHandlers(solver)
	solver = solver or self.solver

	if not solver then return end

	local polyhedron_pair_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")
	local sphere_pair_solver = import("goluwa/physics/pair_solvers/sphere.lua")
	local capsule_pair_solver = import("goluwa/physics/pair_solvers/capsule.lua")
	local box_pair_solver = import("goluwa/physics/pair_solvers/box.lua")

	solver:RegisterPairHandler("convex", "box", function(body_a, body_b, _, _, dt)
		return polyhedron_pair_solver.SolvePolyhedronPairCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("box", "convex", function(body_a, body_b, _, _, dt)
		return polyhedron_pair_solver.SolvePolyhedronPairCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("convex", "convex", function(body_a, body_b, _, _, dt)
		return polyhedron_pair_solver.SolvePolyhedronPairCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("sphere", "sphere", function(body_a, body_b, _, _, dt)
		return sphere_pair_solver.SolveSpherePairCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("sphere", "box", function(body_a, body_b, _, _, dt)
		return sphere_pair_solver.SolveSphereBoxCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("box", "sphere", function(body_a, body_b, _, _, dt)
		return sphere_pair_solver.SolveSphereBoxCollision(body_b, body_a, dt)
	end)

	solver:RegisterPairHandler("sphere", "convex", function(body_a, body_b, _, _, dt)
		return sphere_pair_solver.SolveSphereConvexCollision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("convex", "sphere", function(body_a, body_b, _, _, dt)
		return sphere_pair_solver.SolveSphereConvexCollision(body_b, body_a, dt)
	end)

	solver:RegisterPairHandler("capsule", "sphere", capsule_pair_solver.SolveCapsuleSpherePair)
	solver:RegisterPairHandler("sphere", "capsule", capsule_pair_solver.SolveSphereCapsulePair)
	solver:RegisterPairHandler("capsule", "capsule", capsule_pair_solver.SolveCapsuleCapsulePair)
	solver:RegisterPairHandler("capsule", "box", capsule_pair_solver.SolveCapsuleBoxPair)
	solver:RegisterPairHandler("box", "capsule", capsule_pair_solver.SolveBoxCapsulePair)

	solver:RegisterPairHandler("box", "box", function(body_a, body_b, _, _, dt)
		return box_pair_solver.SolveBoxPairCollision(body_a, body_b, dt)
	end)

	local SUPPORTED_DYNAMIC_SHAPES = {
		"sphere",
		"capsule",
		"box",
		"convex",
	}
	local MESH_CONTACT_SOLVERS = {
		sphere = mesh_contact_common.SolveMeshSphereCollision,
		capsule = mesh_contact_common.SolveMeshCapsuleCollision,
		box = mesh_polyhedron_contacts.SolveMeshPolyhedronCollision,
		convex = mesh_polyhedron_contacts.SolveMeshPolyhedronCollision,
	}

	local function solve_registered_mesh_pair(body_a, body_b, _, _, dt)
		local mesh_body, dynamic_body, mesh_shape = mesh_contact_common.GetStaticMeshDynamicPair(body_a, body_b)

		if not mesh_body then return false end

		local solver_fn = MESH_CONTACT_SOLVERS[dynamic_body:GetShapeType()]
		return solver_fn and solver_fn(mesh_body, dynamic_body, mesh_shape, dt) or false
	end

	for _, dynamic_shape in ipairs(SUPPORTED_DYNAMIC_SHAPES) do
		solver:RegisterPairHandler("mesh", dynamic_shape, solve_registered_mesh_pair)
		solver:RegisterPairHandler(dynamic_shape, "mesh", solve_registered_mesh_pair)
	end
end

function Physics:CreateCollisionPairs()
	return CollisionPairs.New({physics = self})
end

function Physics:CreateBroadphase()
	return Broadphase.New({physics = self})
end

function Physics:CreateSolver()
	local solver = Solver.New({physics = self})
	self.solver = solver
	self:RegisterPairHandlers(solver)
	return solver
end

Physics:Register()
return Physics.New{
	instance = singleton,
}
