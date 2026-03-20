local physics = import("goluwa/physics.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local mesh_contact_common = import("goluwa/physics/mesh_contact_common.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local mesh_simple_contacts = {}

local SPHERE_TRIANGLE_CONTACT_HANDLERS = {}
local CAPSULE_TRIANGLE_CONTACT_HANDLERS = {}

local function query_mesh_sphere_contact(handlers, v0, v1, v2)
	return triangle_contact_queries.QuerySphere(handlers.body, v0, v1, v2, {epsilon = physics.EPSILON})
end

local function get_mesh_sphere_delta(handlers, result)
	return handlers.center - result.position
end

local function get_mesh_sphere_fallback_delta(handlers, _, v0, v1, v2)
	return handlers.center - triangle_geometry.GetTriangleCenter(v0, v1, v2)
end

local function get_mesh_sphere_contact_points(handlers, result, normal)
	return result.position, handlers.center - normal * handlers.radius
end

SPHERE_TRIANGLE_CONTACT_HANDLERS.Query = query_mesh_sphere_contact
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetDelta = get_mesh_sphere_delta
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetFallbackDelta = get_mesh_sphere_fallback_delta
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetContactPoints = get_mesh_sphere_contact_points

local function query_mesh_capsule_contact(handlers, v0, v1, v2)
	return triangle_contact_queries.QueryCapsule(
		handlers.body,
		v0,
		v1,
		v2,
		{
			epsilon = physics.EPSILON,
			fallback_normal = physics.Up,
		}
	)
end

local function get_mesh_capsule_delta(_, result)
	return result.segment_point - result.position
end

local function get_mesh_capsule_fallback_delta(handlers, _, v0, v1, v2)
	return handlers.body:GetPosition() - triangle_geometry.GetTriangleCenter(v0, v1, v2)
end

local function get_mesh_capsule_contact_points(_, result, normal)
	return result.position, result.segment_point - normal * (result.radius or 0)
end

CAPSULE_TRIANGLE_CONTACT_HANDLERS.Query = query_mesh_capsule_contact
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetDelta = get_mesh_capsule_delta
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetFallbackDelta = get_mesh_capsule_fallback_delta
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetContactPoints = get_mesh_capsule_contact_points

function mesh_simple_contacts.SolveMeshSphereCollision(mesh_body, sphere_body, mesh_shape, dt)
	local center = sphere_body:GetPosition()
	local radius = sphere_body:GetSphereRadius()
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = sphere_body
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = center
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = radius
	local resolved = mesh_contact_common.SolveBestTriangleContact(
		mesh_body,
		sphere_body,
		mesh_shape,
		dt,
		SPHERE_TRIANGLE_CONTACT_HANDLERS
	)
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = nil
	return resolved
end

function mesh_simple_contacts.SolveMeshCapsuleCollision(mesh_body, capsule_body, mesh_shape, dt)
	local shape = capsule_geometry.GetCapsuleShape(capsule_body)

	if not shape then return false end
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.body = capsule_body

	local resolved = mesh_contact_common.SolveBestTriangleContact(
		mesh_body,
		capsule_body,
		mesh_shape,
		dt,
		CAPSULE_TRIANGLE_CONTACT_HANDLERS
	)
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.body = nil
	return resolved
end

return mesh_simple_contacts
