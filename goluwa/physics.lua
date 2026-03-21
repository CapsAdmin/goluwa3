local physics = library()
import.loaded["goluwa/physics.lua"] = physics
import("goluwa/physics/shared.lua")
local Broadphase = import("goluwa/physics/broadphase.lua")
local CollisionPairs = import("goluwa/physics/collision_pairs.lua")
import("goluwa/physics/convex_hull.lua")
import("goluwa/physics/sweep.lua")
import("goluwa/physics/trace.lua")
import("goluwa/physics/constraint.lua")
local Solver = import("goluwa/physics/solver.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local mesh_polyhedron_contacts = import("goluwa/physics/mesh_polyhedron_contacts.lua")
physics.collision_pairs = physics.collision_pairs or CollisionPairs.New({physics = physics})
physics.broadphase = physics.broadphase or Broadphase.New({physics = physics})
physics.solver = Solver.New({physics = physics})
import("goluwa/physics/pair_solvers/polyhedron.lua")
import("goluwa/physics/pair_solvers/sphere.lua")
import("goluwa/physics/pair_solvers/capsule.lua")
import("goluwa/physics/pair_solvers/box.lua")

do
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

		local solver = MESH_CONTACT_SOLVERS[dynamic_body:GetShapeType()]
		return solver and solver(mesh_body, dynamic_body, mesh_shape, dt) or false
	end

	for _, dynamic_shape in ipairs(SUPPORTED_DYNAMIC_SHAPES) do
		physics.solver:RegisterPairHandler("mesh", dynamic_shape, solve_registered_mesh_pair)
		physics.solver:RegisterPairHandler(dynamic_shape, "mesh", solve_registered_mesh_pair)
	end
end

import("goluwa/physics/rigid_body.lua")

function physics.ResetState()
	local collision_pairs = physics.collision_pairs or CollisionPairs.New({physics = physics})
	local broadphase = physics.broadphase or Broadphase.New({physics = physics})
	local solver = physics.solver or Solver.New({physics = physics})
	local constraints = physics.GetConstraints and physics.GetConstraints() or nil
	physics.collision_pairs = collision_pairs
	physics.broadphase = broadphase
	physics.solver = solver
	collision_pairs:ResetState()
	broadphase:ResetState()
	solver:ResetState()

	if constraints then
		for i = #constraints, 1, -1 do
			local constraint = constraints[i]

			if not (constraint and constraint.IsValid and constraint:IsValid()) then
				table.remove(constraints, i)
			end
		end
	end
end

import("goluwa/physics/world_step.lua")
return physics
