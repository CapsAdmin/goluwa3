local physics_constants = import("goluwa/physics/constants.lua")
local stats = import("goluwa/physics/stats.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local mesh_contact_common = {}
local EPSILON = physics_constants.EPSILON
local SPHERE_TRIANGLE_CONTACT_HANDLERS = {}
local CAPSULE_TRIANGLE_CONTACT_HANDLERS = {}
local MAX_SPECULATIVE_DISTANCE = 0.5
local FACE_BEHIND_DOT = 0.99
local LOCAL_SPACE_NARROW_PHASE_ENABLED = true

function mesh_contact_common.BuildExpandedWorldContactAABB(bounds, body, extra_body, extra_pad)
	local margin = body and (body:GetCollisionMargin() or 0) or 0
	local probe_distance = body and (body:GetCollisionProbeDistance() or 0) or 0
	local extra_margin = extra_body and (extra_body:GetCollisionMargin() or 0) or 0
	local extra_probe_distance = extra_body and (extra_body:GetCollisionProbeDistance() or 0) or 0
	local pad = math.max(
			margin + probe_distance + extra_margin + extra_probe_distance,
			physics_constants.DEFAULT_COLLISION_MARGIN,
			physics_constants.EPSILON
		) + (
			extra_pad or
			0
		)
	return {
		min_x = bounds.min_x - pad,
		min_y = bounds.min_y - pad,
		min_z = bounds.min_z - pad,
		max_x = bounds.max_x + pad,
		max_y = bounds.max_y + pad,
		max_z = bounds.max_z + pad,
	}
end

function mesh_contact_common.GetMeshShape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape:GetTypeName() == "mesh" and shape or nil
end

function mesh_contact_common.SetLocalSpaceNarrowPhaseEnabled(enabled)
	LOCAL_SPACE_NARROW_PHASE_ENABLED = enabled ~= false
	return LOCAL_SPACE_NARROW_PHASE_ENABLED
end

function mesh_contact_common.GetLocalSpaceNarrowPhaseEnabled()
	return LOCAL_SPACE_NARROW_PHASE_ENABLED
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
	step_dt = 0,
	cluster_count = 0,
	bottom_y = 0,
}
local MAX_CONTACT_CLUSTERS = 4
local CLUSTER_NORMAL_DOT = 0.9
local CLUSTER_TIE_OVERLAP = 0.001
local RESTING_CONTACT_SLACK = 0.01
local FEATURE_FACE_DOT = 0.999
local FEATURE_FLOOR_TOLERANCE = 0.02
local BODY_BOUNDS = {}
local CLUSTERS = {}

for i = 1, MAX_CONTACT_CLUSTERS do
	CLUSTERS[i] = {
		normal = nil,
		overlap = 0,
		lever_squared = 0,
		feature = false,
		contacts = {{point_a = nil, point_b = nil}},
	}
end

local HEIGHTMAP_CAPSULE_OPTIONS = {friction_scale = 0.25}

local function local_vector_to_world(mesh_body, value)
	if not value then return nil end

	return mesh_body:GetRotation():VecMul(value)
end

local function local_point_to_world(mesh_body, value)
	if not value then return nil end

	return mesh_body:LocalToWorld(value)
end

local function evaluate_triangle_contact(
	mesh_body,
	other_body,
	handlers,
	combined_margin,
	v0,
	v1,
	v2,
	triangle_index,
	polygon
)
	local result = handlers.Query(handlers, v0, v1, v2)

	if not result then return nil end

	local query_space = handlers.QuerySpace or "world"
	local delta = handlers.GetDelta(handlers, result, v0, v1, v2)
	local fallback_delta = handlers.GetFallbackDelta(handlers, result, v0, v1, v2)
	local fallback_normal = handlers.GetFallbackNormal and
		handlers.GetFallbackNormal(handlers, result, v0, v1, v2) or
		result.face_normal

	if query_space == "local" then
		delta = local_vector_to_world(mesh_body, delta)
		fallback_delta = local_vector_to_world(mesh_body, fallback_delta)
		fallback_normal = local_vector_to_world(mesh_body, fallback_normal)
	end

	local normal = select(
		1,
		mesh_contact_common.SelectTriangleNormal(mesh_body, other_body, delta, fallback_delta, fallback_normal)
	)
	local overlap = combined_margin - result.surface_distance

	if not normal or overlap < -handlers.speculative_distance then return nil end

	local point_a, point_b = handlers.GetContactPoints(handlers, result, normal, v0, v1, v2)

	if query_space == "local" then
		point_a = local_point_to_world(mesh_body, point_a)
		point_b = local_point_to_world(mesh_body, point_b)
	end

	local best = mesh_contact_common.UpdateBestContact(nil, triangle_index, normal, overlap, point_a, point_b, polygon)
	best.feature = normal:Dot(fallback_normal) < FEATURE_FACE_DOT
	return best
end

local function query_mesh_sphere_contact(handlers, v0, v1, v2)
	if handlers.QuerySpace ~= "local" then
		return triangle_contact_queries.QuerySphere(handlers.body, v0, v1, v2, {epsilon = EPSILON})
	end

	local result = triangle_contact_queries.BuildSphereTrianglePair(handlers.center_local, handlers.radius, v0, v1, v2, {
		epsilon = EPSILON,
	})

	if not result then return nil end

	result.radius = handlers.radius
	result.surface_distance = result.distance - handlers.radius
	return result
end

local function get_mesh_sphere_delta(handlers, result)
	if handlers.QuerySpace ~= "local" then
		return handlers.center - result.position
	end

	return handlers.center_local - result.position
end

local function get_mesh_sphere_fallback_delta(handlers, _, v0, v1, v2)
	if handlers.QuerySpace ~= "local" then
		return handlers.center - triangle_geometry.GetTriangleCenter(v0, v1, v2)
	end

	return handlers.center_local - triangle_geometry.GetTriangleCenter(v0, v1, v2)
end

local function get_mesh_sphere_contact_points(_, result)
	return result.position, result.point
end

SPHERE_TRIANGLE_CONTACT_HANDLERS.Query = query_mesh_sphere_contact
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetDelta = get_mesh_sphere_delta
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetFallbackDelta = get_mesh_sphere_fallback_delta
SPHERE_TRIANGLE_CONTACT_HANDLERS.GetContactPoints = get_mesh_sphere_contact_points

local function query_mesh_capsule_contact(handlers, v0, v1, v2)
	if handlers.QuerySpace ~= "local" then
		return triangle_contact_queries.QueryCapsule(
			handlers.body,
			v0,
			v1,
			v2,
			{
				epsilon = EPSILON,
				fallback_normal = physics_constants.UP,
			}
		)
	end

	local result = triangle_contact_queries.BuildCapsuleTrianglePairWithin(
		handlers.start_local,
		handlers.end_local,
		handlers.radius,
		handlers.center_local,
		v0,
		v1,
		v2,
		EPSILON,
		handlers.fallback_normal_local or physics_constants.UP,
		handlers.radius + handlers.max_surface_distance
	)

	if not result then return nil end

	result.radius = handlers.radius
	result.surface_distance = result.distance - handlers.radius
	return result
end

local function get_mesh_capsule_delta(_, result)
	return result.segment_point - result.position
end

local function get_mesh_capsule_fallback_delta(handlers, _, v0, v1, v2)
	if handlers.QuerySpace ~= "local" then
		return handlers.body:GetPosition() - triangle_geometry.GetTriangleCenter(v0, v1, v2)
	end

	return handlers.center_local - triangle_geometry.GetTriangleCenter(v0, v1, v2)
end

local function get_mesh_capsule_contact_points(_, result)
	return result.position, result.point
end

CAPSULE_TRIANGLE_CONTACT_HANDLERS.Query = query_mesh_capsule_contact
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetDelta = get_mesh_capsule_delta
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetFallbackDelta = get_mesh_capsule_fallback_delta
CAPSULE_TRIANGLE_CONTACT_HANDLERS.GetContactPoints = get_mesh_capsule_contact_points

local function invoke_overlapping_mesh_triangle(v0, v1, v2, triangle_index, context)
	stats:Count("mesh_triangles")
	local mesh_body = context.mesh_body
	local user_context = context.user_context
	local previous_entry = user_context and user_context.entry or nil

	if user_context then user_context.entry = context.entry end

	local stop = false

	if user_context and user_context.use_local_space then
		stop = context.callback(v0, v1, v2, triangle_index, user_context) == true
	else
		stop = context.callback(
				mesh_body:LocalToWorld(v0),
				mesh_body:LocalToWorld(v1),
				mesh_body:LocalToWorld(v2),
				triangle_index,
				user_context
			) == true
	end

	if user_context then user_context.entry = previous_entry end

	return stop
end

local function solve_best_triangle_contact_callback(v0, v1, v2, triangle_index, context)
	local best = evaluate_triangle_contact(
		context.mesh_body,
		context.other_body,
		context.handlers,
		context.combined_margin,
		v0,
		v1,
		v2,
		triangle_index,
		context.entry and context.entry.polygon or nil
	)

	if not best then return end

	if best.overlap < 0 then
		if
			best.feature and
			best.overlap < -RESTING_CONTACT_SLACK and
			best.point_a.y < context.bottom_y + FEATURE_FLOOR_TOLERANCE
		then
			return
		end

		local velocity = context.other_body.Velocity
		local normal = best.normal
		local approach_speed = -(velocity.x * normal.x + velocity.y * normal.y + velocity.z * normal.z)

		if best.overlap < -(approach_speed * context.step_dt + RESTING_CONTACT_SLACK) then
			return
		end
	end

	local center = context.other_body.Position
	local lever_x = best.point_a.x - center.x
	local lever_y = best.point_a.y - center.y
	local lever_z = best.point_a.z - center.z
	local lever_squared = lever_x * lever_x + lever_y * lever_y + lever_z * lever_z
	local count = context.cluster_count
	local target = nil

	for i = 1, count do
		if CLUSTERS[i].normal:Dot(best.normal) > CLUSTER_NORMAL_DOT then
			target = CLUSTERS[i]

			break
		end
	end

	if target then
		if
			best.overlap < target.overlap - CLUSTER_TIE_OVERLAP or
			(
				best.overlap <= target.overlap + CLUSTER_TIE_OVERLAP and
				lever_squared >= target.lever_squared
			)
		then
			return
		end
	elseif count < MAX_CONTACT_CLUSTERS then
		count = count + 1
		context.cluster_count = count
		target = CLUSTERS[count]
	else
		for i = 1, count do
			if
				best.overlap > CLUSTERS[i].overlap and
				(
					not target or
					CLUSTERS[i].overlap < target.overlap
				)
			then
				target = CLUSTERS[i]
			end
		end

		if not target then return end
	end

	target.normal = best.normal
	target.overlap = best.overlap
	target.lever_squared = lever_squared
	target.feature = best.feature
	target.contacts[1].point_a = best.point_a
	target.contacts[1].point_b = best.point_b
end

function mesh_contact_common.ForEachOverlappingMeshTriangle(mesh_body, mesh_shape, other_body, callback, context, extra_pad)
	local bounds = mesh_contact_common.BuildExpandedWorldContactAABB(other_body:GetBroadphaseAABB(), mesh_body, other_body, extra_pad)
	local local_bounds = AABB.BuildLocalAABBFromWorldAABBInternal(
		bounds,
		mesh_body.WorldToLocal,
		mesh_body,
		mesh_body:GetPosition(),
		mesh_body:GetRotation()
	)
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.mesh_body = mesh_body
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.callback = callback
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.user_context = context
	local result = mesh_shape:ForEachOverlappingTriangle(
		mesh_body,
		local_bounds,
		invoke_overlapping_mesh_triangle,
		OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT
	)
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.mesh_body = nil
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.callback = nil
	OVERLAPPING_TRIANGLE_CALLBACK_CONTEXT.user_context = nil
	return result
end

function mesh_contact_common.SelectTriangleNormal(mesh_body, other_body, delta, fallback_delta, fallback_normal)
	local normal = select(
		1,
		pair_solver_helpers.GetSafeCollisionNormal(
			delta,
			other_body:GetVelocity() - mesh_body:GetVelocity(),
			fallback_delta,
			fallback_normal or pair_solver_helpers.GetCachedPairNormal(mesh_body, other_body)
		)
	)
	local shape = mesh_body and mesh_body.GetPhysicsShape and mesh_body:GetPhysicsShape()

	if
		normal and
		fallback_normal and
		shape and
		shape.IsOutwardWound and
		shape:IsOutwardWound(mesh_body) and
		normal:Dot(fallback_normal) < -FACE_BEHIND_DOT
	then
		normal = fallback_normal
	end

	return normal
end

function mesh_contact_common.UpdateBestContact(best, triangle_index, normal, overlap, point_a, point_b, polygon)
	if not normal then return best end

	if not best or overlap > best.overlap then
		return {
			triangle_index = triangle_index,
			normal = normal,
			overlap = overlap,
			point_a = point_a,
			point_b = point_b,
			polygon = polygon,
		}
	end

	return best
end

function mesh_contact_common.SolveBestTriangleContact(mesh_body, other_body, mesh_shape, dt, handlers)
	local combined_margin = handlers.combined_margin

	if combined_margin == nil then
		combined_margin = (other_body:GetCollisionMargin() or 0) + (mesh_body:GetCollisionMargin() or 0)
	end

	local speculative_distance = math.min(
		other_body.Velocity:GetLength() * other_body:GetPhysics().solver.StepDt,
		MAX_SPECULATIVE_DISTANCE
	)
	handlers.speculative_distance = speculative_distance
	handlers.max_surface_distance = combined_margin + speculative_distance
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = mesh_body
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = other_body
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = handlers
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = combined_margin
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.step_dt = other_body:GetPhysics().solver.StepDt
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.use_local_space = handlers.QuerySpace == "local"
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.cluster_count = 0
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.bottom_y = other_body:GetBroadphaseAABB(nil, nil, BODY_BOUNDS).min_y
	mesh_contact_common.ForEachOverlappingMeshTriangle(
		mesh_body,
		mesh_shape,
		other_body,
		solve_best_triangle_contact_callback,
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT,
		speculative_distance
	)
	local cluster_count = SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.cluster_count
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = 0
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.cluster_count = 0
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.entry = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.use_local_space = nil

	if cluster_count == 0 then return false end

	local options = nil

	if
		mesh_shape.IsHeightmap and
		other_body:GetShapeType() == "capsule" and
		CLUSTERS[1].normal.y >= math.max(other_body:GetMinGroundNormalY() or 0, 0.45)
	then
		options = HEIGHTMAP_CAPSULE_OPTIONS
	end

	return contact_resolution.ResolvePairClusters(mesh_body, other_body, CLUSTERS, cluster_count, dt, options)
end

function mesh_contact_common.SolveMeshSphereCollision(mesh_body, sphere_body, mesh_shape, dt)
	local center = sphere_body:GetPosition()
	local radius = sphere_body:GetSphereRadius()
	local use_local_space = LOCAL_SPACE_NARROW_PHASE_ENABLED
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = sphere_body
	SPHERE_TRIANGLE_CONTACT_HANDLERS.QuerySpace = use_local_space and "local" or "world"
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = center
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center_local = use_local_space and mesh_body:WorldToLocal(center) or nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = radius
	local resolved = mesh_contact_common.SolveBestTriangleContact(mesh_body, sphere_body, mesh_shape, dt, SPHERE_TRIANGLE_CONTACT_HANDLERS)
	SPHERE_TRIANGLE_CONTACT_HANDLERS.body = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.QuerySpace = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.center_local = nil
	SPHERE_TRIANGLE_CONTACT_HANDLERS.radius = nil
	return resolved
end

function mesh_contact_common.SolveMeshCapsuleCollision(mesh_body, capsule_body, mesh_shape, dt)
	local shape = capsule_geometry.GetCapsuleShape(capsule_body)
	local use_local_space = LOCAL_SPACE_NARROW_PHASE_ENABLED
	local start_world, end_world, radius

	if use_local_space then
		start_world, end_world, radius = capsule_geometry.GetSegmentWorld(capsule_body)
	end

	if not shape then return false end

	if use_local_space and not (start_world and end_world and radius) then
		return false
	end

	CAPSULE_TRIANGLE_CONTACT_HANDLERS.body = capsule_body
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.QuerySpace = use_local_space and "local" or "world"
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.center_local = use_local_space and mesh_body:WorldToLocal(capsule_body:GetPosition()) or nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.start_local = use_local_space and mesh_body:WorldToLocal(start_world) or nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.end_local = use_local_space and mesh_body:WorldToLocal(end_world) or nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.radius = use_local_space and radius or nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.fallback_normal_local = use_local_space and
		mesh_body:GetRotation():GetConjugated():VecMul(physics_constants.UP) or
		nil
	local resolved = mesh_contact_common.SolveBestTriangleContact(
		mesh_body,
		capsule_body,
		mesh_shape,
		dt,
		CAPSULE_TRIANGLE_CONTACT_HANDLERS
	)
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.body = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.QuerySpace = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.center_local = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.start_local = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.end_local = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.fallback_normal_local = nil
	CAPSULE_TRIANGLE_CONTACT_HANDLERS.radius = nil
	return resolved
end

return mesh_contact_common
