local physics = import("goluwa/physics.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local mesh_simple_contacts = {}

function mesh_simple_contacts.SolveMeshSphereCollision(mesh_body, sphere_body, mesh_shape, dt)
	local center = sphere_body:GetPosition()
	local radius = sphere_body:GetSphereRadius()
	return mesh_contact_common.SolveBestTriangleContact(mesh_body, sphere_body, mesh_shape, dt, {
		Query = function(v0, v1, v2)
			return triangle_contact_queries.QuerySphere(sphere_body, v0, v1, v2, {epsilon = physics.EPSILON})
		end,
		GetDelta = function(result)
			return center - result.position
		end,
		GetFallbackDelta = function(_, v0, v1, v2)
			return center - triangle_geometry.GetTriangleCenter(v0, v1, v2)
		end,
		GetContactPoints = function(result, normal)
			return result.position, center - normal * radius
		end,
	})
end

function mesh_simple_contacts.SolveMeshCapsuleCollision(mesh_body, capsule_body, mesh_shape, dt)
	local shape = capsule_geometry.GetCapsuleShape(capsule_body)

	if not shape then return false end

	return mesh_contact_common.SolveBestTriangleContact(mesh_body, capsule_body, mesh_shape, dt, {
		Query = function(v0, v1, v2)
			return triangle_contact_queries.QueryCapsule(
				capsule_body,
				v0,
				v1,
				v2,
				{
					epsilon = physics.EPSILON,
					fallback_normal = physics.Up,
				}
			)
		end,
		GetDelta = function(result)
			return result.segment_point - result.position
		end,
		GetFallbackDelta = function(_, v0, v1, v2)
			return capsule_body:GetPosition() - triangle_geometry.GetTriangleCenter(v0, v1, v2)
		end,
		GetContactPoints = function(result, normal)
			return result.position, result.segment_point - normal * (result.radius or 0)
		end,
	})
end

return mesh_simple_contacts
