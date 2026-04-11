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
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local mesh_contact_common = {}
local EPSILON = physics_constants.EPSILON
local SPHERE_TRIANGLE_CONTACT_HANDLERS = {}
local CAPSULE_TRIANGLE_CONTACT_HANDLERS = {}
local NARROW_PHASE_PAIR_CACHE = setmetatable({}, {__mode = "k"})
local NARROW_PHASE_CACHE_ENABLED = true
local LOCAL_SPACE_NARROW_PHASE_ENABLED = true
local MAX_NARROW_CACHE_TRIANGLES = 4
local MAX_NARROW_CACHE_NEIGHBORS = 6

local function new_weak_key_table()
	return setmetatable({}, {__mode = "k"})
end

function mesh_contact_common.GetMeshShape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() == "mesh" and shape or nil
end

function mesh_contact_common.SetNarrowPhaseCacheEnabled(enabled)
	NARROW_PHASE_CACHE_ENABLED = enabled ~= false

	if not NARROW_PHASE_CACHE_ENABLED then
		NARROW_PHASE_PAIR_CACHE = setmetatable({}, {__mode = "k"})
	end

	return NARROW_PHASE_CACHE_ENABLED
end

function mesh_contact_common.GetNarrowPhaseCacheEnabled()
	return NARROW_PHASE_CACHE_ENABLED
end

function mesh_contact_common.ClearNarrowPhaseCache()
	NARROW_PHASE_PAIR_CACHE = setmetatable({}, {__mode = "k"})
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

local function get_narrow_phase_pair_cache(mesh_body, other_body)
	if not (mesh_body and other_body) then return nil end

	local row = NARROW_PHASE_PAIR_CACHE[mesh_body]

	if not row then
		row = new_weak_key_table()
		NARROW_PHASE_PAIR_CACHE[mesh_body] = row
	end

	local entry = row[other_body]

	if entry then return entry end

	entry = {}
	row[other_body] = entry
	return entry
end

local function clear_cached_triangle_fields(pair)
	if not pair then return end

	pair.mesh_cached_polygon = nil
	pair.mesh_cached_triangle_index = nil
	pair.mesh_cached_triangle_normal = nil
	pair.mesh_cached_triangle_overlap = nil
	pair.mesh_cached_triangles = nil
end

local function same_cached_triangle(candidate, polygon, triangle_index)
	return candidate and
		candidate.polygon == polygon and
		candidate.triangle_index == triangle_index
end

local function push_cached_triangle(pair, polygon, triangle_index, normal, overlap)
	if not (pair and polygon and triangle_index ~= nil) then return end

	local list = pair.mesh_cached_triangles

	if not list then
		list = {}
		pair.mesh_cached_triangles = list
	end

	for i = 1, #list do
		local candidate = list[i]

		if same_cached_triangle(candidate, polygon, triangle_index) then
			table.remove(list, i)

			break
		end
	end

	table.insert(
		list,
		1,
		{
			polygon = polygon,
			triangle_index = triangle_index,
			normal = normal,
			overlap = overlap,
		}
	)

	while #list > MAX_NARROW_CACHE_TRIANGLES do
		list[#list] = nil
	end

	pair.mesh_cached_polygon = polygon
	pair.mesh_cached_triangle_index = triangle_index
	pair.mesh_cached_triangle_normal = normal
	pair.mesh_cached_triangle_overlap = overlap
end

local function append_cached_triangle_candidate(candidates, seen, polygon, triangle_index)
	if not (polygon and triangle_index ~= nil) then return false end

	local polygon_seen = seen[polygon]

	if not polygon_seen then
		polygon_seen = {}
		seen[polygon] = polygon_seen
	end

	if polygon_seen[triangle_index] then return false end

	polygon_seen[triangle_index] = true
	candidates[#candidates + 1] = {polygon = polygon, triangle_index = triangle_index}
	return true
end

local function append_neighbor_triangle_candidates(candidates, seen, polygon, triangle_index)
	if not (polygon and triangle_index ~= nil) then return 0 end

	local feature_cache = triangle_mesh.GetPolygonFeatureCache(polygon)
	local _, _, _, i0, i1, i2 = triangle_mesh.GetPolygonTriangleLocalVertices(polygon, triangle_index)

	if not (feature_cache and i0 and i1 and i2) then return 0 end

	local added = 0

	local function append_from_vertex(vertex_index)
		local faces = feature_cache.faces_by_vertex_index[vertex_index]

		if not faces then return end

		for _, face_index in ipairs(faces) do
			if
				face_index ~= triangle_index and
				append_cached_triangle_candidate(candidates, seen, polygon, face_index)
			then
				added = added + 1

				if added >= MAX_NARROW_CACHE_NEIGHBORS then return true end
			end
		end

		return false
	end

	if append_from_vertex(i0) then return added end

	if append_from_vertex(i1) then return added end

	if append_from_vertex(i2) then return added end

	return added
end

local function collect_cached_triangle_candidates(pair)
	local candidates = {}
	local seen = {}
	local list = pair and pair.mesh_cached_triangles or nil

	if list and list[1] then
		for _, candidate in ipairs(list) do
			append_cached_triangle_candidate(candidates, seen, candidate.polygon, candidate.triangle_index)
		end
	elseif pair and pair.mesh_cached_polygon and pair.mesh_cached_triangle_index ~= nil then
		append_cached_triangle_candidate(candidates, seen, pair.mesh_cached_polygon, pair.mesh_cached_triangle_index)
	end

	local base_count = #candidates

	for i = 1, base_count do
		local candidate = candidates[i]
		append_neighbor_triangle_candidates(candidates, seen, candidate.polygon, candidate.triangle_index)

		if #candidates >= base_count + MAX_NARROW_CACHE_NEIGHBORS then break end
	end

	return candidates
end

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

	if not normal then return nil end

	local point_a, point_b = handlers.GetContactPoints(handlers, result, normal, v0, v1, v2)

	if query_space == "local" then
		point_a = local_point_to_world(mesh_body, point_a)
		point_b = local_point_to_world(mesh_body, point_b)
	end

	return mesh_contact_common.UpdateBestContact(nil, triangle_index, normal, overlap, point_a, point_b, polygon)
end

local function cache_best_triangle(mesh_body, other_body, best)
	if not NARROW_PHASE_CACHE_ENABLED then return end

	if not (best and best.polygon and best.triangle_index ~= nil) then return end

	local pair = get_narrow_phase_pair_cache(mesh_body, other_body)

	if not pair then return end

	push_cached_triangle(pair, best.polygon, best.triangle_index, best.normal, best.overlap)
end

local function try_cached_triangle(mesh_body, other_body, handlers, combined_margin)
	local pair = get_narrow_phase_pair_cache(mesh_body, other_body)

	if not NARROW_PHASE_CACHE_ENABLED then return nil end

	if not pair then return nil end

	local candidates = collect_cached_triangle_candidates(pair)

	if not candidates[1] then return nil end

	local cached_normal = pair_solver_helpers.GetCachedPairNormal(mesh_body, other_body)

	for _, candidate in ipairs(candidates) do
		local polygon = candidate.polygon
		local triangle_index = candidate.triangle_index
		local local_v0, local_v1, local_v2 = triangle_mesh.GetPolygonTriangleLocalVertices(polygon, triangle_index)

		if local_v0 and local_v1 and local_v2 then
			local v0 = local_v0
			local v1 = local_v1
			local v2 = local_v2

			if handlers.QuerySpace ~= "local" then
				v0 = mesh_body:LocalToWorld(local_v0)
				v1 = mesh_body:LocalToWorld(local_v1)
				v2 = mesh_body:LocalToWorld(local_v2)
			end

			local best = evaluate_triangle_contact(
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

			if best then
				if cached_normal and cached_normal:Dot(best.normal) < 0.8 then

				else
					push_cached_triangle(pair, polygon, triangle_index, best.normal, best.overlap)
					return best
				end
			end
		end
	end

	clear_cached_triangle_fields(pair)
	return nil
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
				fallback_normal = physics.Up,
			}
		)
	end

	local result = triangle_contact_queries.BuildCapsuleTrianglePair(
		handlers.start_local,
		handlers.end_local,
		handlers.radius,
		handlers.center_local,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			fallback_normal = handlers.fallback_normal_local or physics.Up,
		}
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

function LOCAL_AABB_TRANSFORM_PROXY:TransformVector(point)
	return self.body:WorldToLocal(point)
end

local function invoke_overlapping_mesh_triangle(v0, v1, v2, triangle_index, context)
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

	context.best = mesh_contact_common.UpdateBestContact(
		context.best,
		best.triangle_index,
		best.normal,
		best.overlap,
		best.point_a,
		best.point_b,
		best.polygon
	)
end

function mesh_contact_common.ForEachOverlappingMeshTriangle(mesh_body, mesh_shape, other_body, callback, context)
	local bounds = static_model_query.BuildExpandedWorldContactAABB(other_body:GetBroadphaseAABB(), mesh_body, other_body)
	LOCAL_AABB_TRANSFORM_PROXY.body = mesh_body
	local local_bounds = AABB.BuildLocalAABBFromWorldAABB(bounds, LOCAL_AABB_TRANSFORM_PROXY)
	LOCAL_AABB_TRANSFORM_PROXY.body = nil
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

function mesh_contact_common.ForEachCachedMeshTriangle(mesh_body, other_body, callback, context)
	if not NARROW_PHASE_CACHE_ENABLED then return 0 end

	local pair = get_narrow_phase_pair_cache(mesh_body, other_body)

	if not pair then return 0 end

	local candidates = collect_cached_triangle_candidates(pair)
	local use_local_space = context and context.use_local_space
	local previous_entry = context and context.entry or nil
	local count = 0

	for _, candidate in ipairs(candidates) do
		local polygon = candidate.polygon
		local triangle_index = candidate.triangle_index
		local local_v0, local_v1, local_v2 = triangle_mesh.GetPolygonTriangleLocalVertices(polygon, triangle_index)

		if local_v0 and local_v1 and local_v2 then
			if context then context.entry = {polygon = polygon} end

			if use_local_space then
				callback(local_v0, local_v1, local_v2, triangle_index, context)
			else
				callback(
					mesh_body:LocalToWorld(local_v0),
					mesh_body:LocalToWorld(local_v1),
					mesh_body:LocalToWorld(local_v2),
					triangle_index,
					context
				)
			end

			count = count + 1
		end
	end

	if context then context.entry = previous_entry end

	return count
end

function mesh_contact_common.CacheTriangle(mesh_body, other_body, polygon, triangle_index, normal, overlap)
	if not NARROW_PHASE_CACHE_ENABLED then return false end

	if not (polygon and triangle_index ~= nil) then return false end

	local pair = get_narrow_phase_pair_cache(mesh_body, other_body)

	if not pair then return false end

	push_cached_triangle(pair, polygon, triangle_index, normal, overlap)
	return true
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

function mesh_contact_common.UpdateBestContact(best, triangle_index, normal, overlap, point_a, point_b, polygon)
	if not normal or overlap <= EPSILON then return best end

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

function mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
	if not best then return false end

	local options = nil
	local mesh_shape = mesh_contact_common.GetMeshShape(mesh_body)

	if
		mesh_shape and
		mesh_shape.Heightmap ~= nil and
		other_body.GetShapeType and
		other_body:GetShapeType() == "capsule" and
		best.normal and
		best.normal.y >= math.max(other_body:GetMinGroundNormalY() or 0, 0.45)
	then
		options = {
			friction_scale = 0.25,
		}
	end

	return contact_resolution.ResolvePairPenetration(
		mesh_body,
		other_body,
		best.normal,
		best.overlap,
		dt,
		best.point_a,
		best.point_b,
		nil,
		options
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
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.use_local_space = handlers.QuerySpace == "local"
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best = try_cached_triangle(mesh_body, other_body, handlers, combined_margin)

	if SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best then
		local best = SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best
		cache_best_triangle(mesh_body, other_body, best)
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = nil
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = nil
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = nil
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = 0
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best = nil
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.entry = nil
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.use_local_space = nil
		return mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
	end

	mesh_contact_common.ForEachOverlappingMeshTriangle(
		mesh_body,
		mesh_shape,
		other_body,
		solve_best_triangle_contact_callback,
		SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT
	)
	local best = SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best
	cache_best_triangle(mesh_body, other_body, best)
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.mesh_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.other_body = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.handlers = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.combined_margin = 0
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.best = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.entry = nil
	SOLVE_BEST_TRIANGLE_CONTACT_CONTEXT.use_local_space = nil
	return mesh_contact_common.ResolveBestContact(mesh_body, other_body, best, dt)
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
	local start_world, end_world, radius = use_local_space and capsule_geometry.GetSegmentWorld(capsule_body) or nil,
	nil,
	nil

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
		mesh_body:GetRotation():GetConjugated():VecMul(physics.Up) or
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
