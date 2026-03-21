local physics = import("goluwa/physics.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local static_model_query = import("goluwa/physics/static_model_query.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local mesh_contact_common = {}
local EPSILON = physics_constants.EPSILON
local SPHERE_TRIANGLE_CONTACT_HANDLERS = {}
local CAPSULE_TRIANGLE_CONTACT_HANDLERS = {}

function mesh_contact_common.GetMeshShape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() == "mesh" and shape or nil
end

function mesh_contact_common.GetStaticMeshDynamicPair(body_a, body_b)
	local shape_a = mesh_contact_common.GetMeshShape(body_a)
	local shape_b = mesh_contact_common.GetMeshShape(body_b)

	if
		shape_a and
		pair_solver_helpers.IsSolverImmovable(body_a) and
		pair_solver_helpers.HasSolverMass(body_b)
	then
		return body_a, body_b, shape_a
	end

	if
		shape_b and
		pair_solver_helpers.IsSolverImmovable(body_b) and
		pair_solver_helpers.HasSolverMass(body_a)
	then
		return body_b, body_a, shape_b
	end

	return nil, nil, nil
end

local LOCAL_AABB_TRANSFORM_PROXY = {
	body = nil,
}
local OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT = {
	mesh_body = nil,
	callback = nil,
	user_context = nil,
}
local SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT = {
	mesh_body = nil,
	other_body = nil,
	handlers = nil,
	combined_margin = 0,
	best = nil,
}

local function query_mesh_sphere_contact(handlers, v0, v1, v2)
	return triangle_contact_queries.QuerySphere(handlers.body, v0, v1, v2, {epsilon = EPSILON})
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
			epsilon = EPSILON,
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

function LOCAL_AABB_TRANSFORM_PROXY:TransformVector(point)
	return self.body:WorldToLocal(point)
end

local function invoke_overlapping_mesh_triangle(v0, v1, v2, triangle_index, context)
	local mesh_body = context.mesh_body
	context.callback(
		mesh_body:LocalToWorld(v0),
		mesh_body:LocalToWorld(v1),
		mesh_body:LocalToWorld(v2),
		triangle_index,
		context.user_context
	)
end

local function solve_best_triangle_contact_callback(v0, v1, v2, triangle_index, context)
	local handlers = context.handlers
	local result = handlers.Query(handlers, v0, v1, v2)

	if not result then return end

	local normal = select(
		1,
		mesh_contact_common.SelectTriangleNormal(
			context.mesh_body,
			context.other_body,
			handlers.GetDelta(handlers, result, v0, v1, v2),
			handlers.GetFallbackDelta(handlers, result, v0, v1, v2),
			handlers.GetFallbackNormal and
				handlers.GetFallbackNormal(handlers, result, v0, v1, v2) or
				result.face_normal
		)
	)
	local overlap = context.combined_margin - result.surface_distance

	if not normal then return end

	local point_a, point_b = handlers.GetContactPoints(handlers, result, normal, v0, v1, v2)
	context.best = mesh_contact_common.UpdateBestContact(context.best, triangle_index, normal, overlap, point_a, point_b)
end

function mesh_contact_common.ForEachOverlappingMeshTriangle(mesh_body, mesh_shape, other_body, callback, context)
	local bounds = static_model_query.BuildExpandedWorldContactAABB(other_body:GetBroadphaseAABB(), mesh_body, other_body)
	LOCAL_AABB_TRANSFORM_PROXY.body = mesh_body
	local local_bounds = AABB.BuildLocalAABBFromWorldAABB(bounds, LOCAL_AABB_TRANSFORM_PROXY)
	LOCAL_AABB_TRANSFORM_PROXY.body = nil
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.mesh_body = mesh_body
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.callback = callback
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.user_context = context
	mesh_shape:ForEachOverlappingTriangle(
		mesh_body,
		local_bounds,
		invoke_overlapping_mesh_triangle,
		OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT
	)
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.mesh_body = nil
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.callback = nil
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.user_context = nil
end

function mesh_contact_common.SelectTriangleNormal(mesh_body, other_body, delta, fallback_delta, fallback_normal)
	return pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		(
				other_body.GetVelocity and
				other_body:GetVelocity() or
				Vec3()
			) - (
				mesh_body.GetVelocity and
				mesh_body:GetVelocity() or
				Vec3()
			),
		fallback_delta,
		fallback_normal or pair_solver_helpers.GetCachedPairNormal(mesh_body, other_body)
	)
end

function mesh_contact_common.UpdateBestContact(best, triangle_index, normal, overlap, point_a, point_b)
	if not normal or overlap <= EPSILON then return best end

	if not best or overlap > best.overlap then
		return {
			triangle_index = triangle_index,
			normal = normal,
			overlap = overlap,
			point_a = point_a,
			point_b = point_b,
		}
	end

	return best
end

function mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
	if not best then return false end

	return contact_resolution.ResolvePairPenetration(
		mesh_body,
		other_body,
		best.normal,
		best.overlap,
		dt,
		best.point_a,
		best.point_b
	)
end

function mesh_contact_common.SolveBestTriangleContact(mesh_body, other_body, mesh_shape, dt, handlers)
	local combined_margin = handlers.combined_margin

	if combined_margin == nil then
		combined_margin = (other_body:GetCollisionMargin() or 0) + (mesh_body:GetCollisionMargin() or 0)
	end

	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = mesh_body
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = other_body
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = handlers
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = combined_margin
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best = nil
	mesh_contact_common.ForEachOverlappingMeshTriangle(
		mesh_body,
		mesh_shape,
		other_body,
		solve_best_triangle_contact_callback,
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT
	)
	local best = SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = 0
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best = nil
	return mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
end

function mesh_contact_common.SolveMeshSphereCollision(mesh_body, sphere_body, mesh_shape, dt)
	local center = sphere_body:GetPosition()
	local radius = sphere_body:GetSphereRadius()
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = sphere_body
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = center
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = radius
	local resolved = mesh_contact_common.SolveBestTriangleContact(mesh_body, sphere_body, mesh_shape, dt, SPHERE_TRIANGLE_CONTACT_HANDLERS)
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = nil
	return resolved
end

function mesh_contact_common.SolveMeshCapsuleCollision(mesh_body, capsule_body, mesh_shape, dt)
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

return mesh_contact_common
