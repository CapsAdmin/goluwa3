local mesh_polyhedron_contacts = import("goluwa/physics/mesh_polyhedron_contacts.lua")
local mesh_simple_contacts = import("goluwa/physics/mesh_simple_contacts.lua")
local mesh_contact_solvers = {}
local supported_dynamic_shape_types = {}

local function register_solver(shape_type, solver)
	mesh_contact_solvers[shape_type] = solver
	supported_dynamic_shape_types[#supported_dynamic_shape_types + 1] = shape_type
end

function mesh_contact_solvers.SupportsDynamicShapeType(shape_type)
	return mesh_contact_solvers[shape_type] ~= nil
end

function mesh_contact_solvers.GetSupportedDynamicShapeTypes()
	return supported_dynamic_shape_types
end

register_solver("sphere", mesh_simple_contacts.SolveMeshSphereCollision)
register_solver("capsule", mesh_simple_contacts.SolveMeshCapsuleCollision)
register_solver("box", mesh_polyhedron_contacts.SolveMeshPolyhedronCollision)
register_solver("convex", mesh_polyhedron_contacts.SolveMeshPolyhedronCollision)

return mesh_contact_solvers
