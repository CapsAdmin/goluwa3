local physics = import("goluwa/physics.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local mesh_contact_solvers = import("goluwa/physics/mesh_contact_solvers.lua")
local mesh_contact_pipeline = {}
local GetStaticMeshDynamicPair = mesh_contact_common.GetStaticMeshDynamicPair

local function SolveStaticMeshPairCollision(body_a, body_b, dt)
	local mesh_body, dynamic_body, mesh_shape = GetStaticMeshDynamicPair(body_a, body_b)

	if not mesh_body then return false end

	local solver = mesh_contact_solvers[dynamic_body:GetShapeType()]
	return solver and solver(mesh_body, dynamic_body, mesh_shape, dt) or false
end

local function solve_registered_mesh_pair(body_a, body_b, _, _, dt)
	return SolveStaticMeshPairCollision(body_a, body_b, dt)
end

function mesh_contact_pipeline.RegisterPairHandlers(solver)
	solver = solver or physics.solver

	if not solver then return end

	for _, dynamic_shape in ipairs(mesh_contact_solvers.GetSupportedDynamicShapeTypes()) do
		solver:RegisterPairHandler("mesh", dynamic_shape, solve_registered_mesh_pair)
		solver:RegisterPairHandler(dynamic_shape, "mesh", solve_registered_mesh_pair)
	end
end

return mesh_contact_pipeline
