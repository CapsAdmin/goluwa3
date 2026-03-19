local physics = import("goluwa/physics.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local world_static_query = import("goluwa/physics/world_static_query.lua")
local mesh_contact_common = {}

function mesh_contact_common.GetMeshShape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() == "mesh" and shape or nil
end

function mesh_contact_common.GetStaticMeshDynamicPair(body_a, body_b)
	local shape_a = mesh_contact_common.GetMeshShape(body_a)
	local shape_b = mesh_contact_common.GetMeshShape(body_b)

	if shape_a and pair_solver_helpers.IsSolverImmovable(body_a) and pair_solver_helpers.HasSolverMass(body_b) then
		return body_a, body_b, shape_a
	end

	if shape_b and pair_solver_helpers.IsSolverImmovable(body_b) and pair_solver_helpers.HasSolverMass(body_a) then
		return body_b, body_a, shape_b
	end

	return nil, nil, nil
end

local LOCAL_AABB_TRANSFORM_PROXY = {
	body = nil,
}

function LOCAL_AABB_TRANSFORM_PROXY:TransformVector(point)
	return self.body:WorldToLocal(point)
end

function mesh_contact_common.ForEachOverlappingMeshTriangle(mesh_body, mesh_shape, other_body, callback)
	local bounds = world_static_query.BuildExpandedWorldContactAABB(other_body:GetBroadphaseAABB(), mesh_body, other_body)
	LOCAL_AABB_TRANSFORM_PROXY.body = mesh_body
	local local_bounds = AABB.BuildLocalAABBFromWorldAABB(bounds, LOCAL_AABB_TRANSFORM_PROXY)
	LOCAL_AABB_TRANSFORM_PROXY.body = nil
	mesh_shape:ForEachOverlappingTriangle(mesh_body, local_bounds, function(v0, v1, v2, triangle_index, context)
		callback(
			mesh_body:LocalToWorld(v0),
			mesh_body:LocalToWorld(v1),
			mesh_body:LocalToWorld(v2),
			triangle_index,
			context
		)
	end)
end

function mesh_contact_common.SelectTriangleNormal(mesh_body, other_body, delta, fallback_delta, fallback_normal)
	return pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		(other_body.GetVelocity and other_body:GetVelocity() or Vec3()) - (mesh_body.GetVelocity and mesh_body:GetVelocity() or Vec3()),
		fallback_delta,
		fallback_normal or pair_solver_helpers.GetCachedPairNormal(mesh_body, other_body)
	)
end

function mesh_contact_common.UpdateBestContact(best, triangle_index, normal, overlap, point_a, point_b)
	if not normal or overlap <= physics.EPSILON then return best end

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

	local best = nil

	mesh_contact_common.ForEachOverlappingMeshTriangle(mesh_body, mesh_shape, other_body, function(v0, v1, v2, triangle_index)
		local result = handlers.Query(v0, v1, v2)

		if not result then return end

		local normal = select(
			1,
			mesh_contact_common.SelectTriangleNormal(
				mesh_body,
				other_body,
				handlers.GetDelta(result, v0, v1, v2),
				handlers.GetFallbackDelta(result, v0, v1, v2),
				handlers.GetFallbackNormal and handlers.GetFallbackNormal(result, v0, v1, v2) or result.face_normal
			)
		)
		local overlap = combined_margin - result.surface_distance

		if not normal then return end

		local point_a, point_b = handlers.GetContactPoints(result, normal, v0, v1, v2)
		best = mesh_contact_common.UpdateBestContact(best, triangle_index, normal, overlap, point_a, point_b)
	end)

	return mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
end

return mesh_contact_common
