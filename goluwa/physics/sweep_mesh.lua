local physics_constants = import("goluwa/physics/constants.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local polyhedron_triangle_contacts = import("goluwa/physics/polyhedron/triangle_contacts.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local triangle_scalar = import("goluwa/physics/triangle_scalar.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sweep_mesh = {}
local EPSILON = physics_constants.EPSILON
local POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS = 4
local POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS = 64
local POLYHEDRON_SWEEP_REFINE_STEPS = 10
local get_polyhedron_sweep_proxy
local ensure_normal_faces_motion = sweep_helpers.EnsureNormalFacesMotion
local sweep_polyhedron_against_triangle
local sweep_capsule_against_triangle
local sweep_sphere_against_triangle
local get_average_contact_positions = sweep_helpers.GetAverageContactPositions

local function get_segment_fraction(start_position, movement, point)
	local movement_length_sq = movement:Dot(movement)

	if movement_length_sq <= EPSILON * EPSILON then return 0 end

	return math.clamp((point - start_position):Dot(movement) / movement_length_sq, 0, 1)
end

local function get_capsule_segment_world(collider, position, rotation)
	return capsule_geometry.GetSegmentWorld(collider, position, rotation)
end

local function transform_direction(matrix, direction)
	if not matrix then return direction end

	local dx, dy, dz = direction.x, direction.y, direction.z
	return Vec3(
		matrix.m00 * dx + matrix.m10 * dy + matrix.m20 * dz,
		matrix.m01 * dx + matrix.m11 * dy + matrix.m21 * dz,
		matrix.m02 * dx + matrix.m12 * dy + matrix.m22 * dz
	):GetNormalized()
end

local MESH_BODY_POINT_SWEEP_CONTEXT = {
	origin = nil,
	movement = nil,
	radius = 0,
	max_fraction = 0,
	collider = nil,
	target_collider = nil,
	target_position = nil,
	target_rotation = nil,
	wv_cache = nil,
	entry = nil,
	best_hit = nil,
}
local MESH_BODY_COLLIDER_SWEEP_CONTEXT = {
	collider = nil,
	polyhedron = nil,
	start_position = nil,
	rotation = nil,
	movement = nil,
	max_fraction = 0,
	query_shape_type = nil,
	target_collider = nil,
	target_position = nil,
	target_rotation = nil,
	wv_cache = nil,
	entry = nil,
	best_hit = nil,
}
local POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT = {
	start_world = nil,
	movement = nil,
	segment_a = nil,
	segment_b = nil,
}
local TRIANGLE_SWEEP_PRISM_VERTICES = {}

local function fill_triangle_prism_vertices(out, v0, v1, v2, normal, half_thickness)
	out = out or {}
	local offset = normal * half_thickness
	out[1] = v0 + offset
	out[2] = v1 + offset
	out[3] = v2 + offset
	out[4] = v0 - offset
	out[5] = v1 - offset
	out[6] = v2 - offset

	for i = 7, #out do
		out[i] = nil
	end

	return out
end

-- triangle vertices are shared between neighbouring triangles (a heightmap
-- cell reuses its corner points 4+ times), so world-space transforms are
-- cached per sweep and keyed by the local vertex's pointer.
local function get_cached_world_vertex(context, v)
	local cache = context.wv_cache
	local wv = cache[v]

	if not wv then
		wv = context.target_collider:LocalToWorld(v, context.target_position, context.target_rotation)
		cache[v] = wv
	end

	return wv
end

local function collect_mesh_body_point_sweep_hit(v0, v1, v2, triangle_index, context)
	local wv0 = get_cached_world_vertex(context, v0)
	local wv1 = get_cached_world_vertex(context, v1)
	local wv2 = get_cached_world_vertex(context, v2)
	local hit = sweep_sphere_against_triangle(
		context.origin,
		context.movement,
		context.radius,
		wv0,
		wv1,
		wv2,
		context.max_fraction
	)

	if hit and (not context.best_hit or hit.t < context.best_hit.t) then
		local entry = context.entry
		context.best_hit = {
			t = hit.t,
			position = hit.position,
			normal = hit.normal,
			face_normal = hit.normal,
			model = entry.model,
			primitive = entry.primitive,
			primitive_index = entry.primitive_index,
			triangle_index = triangle_index,
		}
	end
end

local function collect_mesh_body_collider_sweep_hit(v0, v1, v2, triangle_index, context)
	local wv0 = get_cached_world_vertex(context, v0)
	local wv1 = get_cached_world_vertex(context, v1)
	local wv2 = get_cached_world_vertex(context, v2)
	local hit = nil

	if context.query_shape_type == "capsule" then
		hit = sweep_capsule_against_triangle(context.capsule_invariants, wv0, wv1, wv2, context.max_fraction)
	elseif context.polyhedron and context.polyhedron.vertices and context.polyhedron.faces then
		hit = sweep_polyhedron_against_triangle(
			context.collider,
			context.polyhedron,
			context.start_position,
			context.rotation,
			context.movement,
			wv0,
			wv1,
			wv2,
			context.max_fraction
		)
	end

	if hit and (not context.best_hit or hit.t < context.best_hit.t) then
		local entry = context.entry
		context.best_hit = {
			t = hit.t,
			point = hit.point,
			position = hit.position,
			normal = hit.normal,
			face_normal = hit.normal,
			model = entry.model,
			primitive = entry.primitive,
			primitive_index = entry.primitive_index,
			triangle_index = triangle_index,
		}
	end
end

local function evaluate_point_against_capsule_segment(context, t)
	local point = context.start_world + context.movement * t
	local closest = segment_geometry.ClosestPointOnSegment(context.segment_a, context.segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	return point, closest, delta, distance
end

local function collect_overlapping_world_triangle(v0, v1, v2, triangle_index, context)
	local local_to_world = context.world_triangle_transform
	local callback = context.world_triangle_callback

	if local_to_world then
		callback(
			local_to_world:TransformVector(v0),
			local_to_world:TransformVector(v1),
			local_to_world:TransformVector(v2),
			triangle_index,
			context
		)
		return
	end

	callback(v0, v1, v2, triangle_index, context)
end

local function for_each_overlapping_world_triangle(poly, local_body_aabb, local_to_world, callback, context)
	context.world_triangle_callback = callback
	context.world_triangle_transform = local_to_world
	triangle_mesh.ForEachOverlappingTriangle(poly, local_body_aabb, collect_overlapping_world_triangle, context)
	context.world_triangle_callback = nil
	context.world_triangle_transform = nil
end

local function get_primitive_query_aabb(primitive, local_aabb)
	if primitive and primitive.local_matrix_inverse then
		return AABB.BuildLocalAABBFromWorldAABB(local_aabb, primitive.local_matrix_inverse)
	end

	return local_aabb
end

local function get_primitive_local_motion(primitive, start_local, movement_local)
	if not (primitive and primitive.local_matrix_inverse) then
		return start_local, movement_local
	end

	local end_local = start_local + movement_local
	local primitive_start = primitive.local_matrix_inverse:TransformVector(start_local)
	local primitive_end = primitive.local_matrix_inverse:TransformVector(end_local)
	return primitive_start, primitive_end - primitive_start
end

local function get_primitive_local_to_world(primitive, local_to_world)
	if not (primitive and primitive.local_matrix) then return local_to_world end

	if not local_to_world then return primitive.local_matrix end

	primitive.sweep_local_to_world = primitive.sweep_local_to_world or Matrix44()
	primitive.local_matrix:GetMultiplied(local_to_world, primitive.sweep_local_to_world)
	return primitive.sweep_local_to_world
end

do
	local POLYHEDRON_SWEEP_PROXY_METHODS = {}

	function POLYHEDRON_SWEEP_PROXY_METHODS:GetPosition()
		return self.sweep_position
	end

	function POLYHEDRON_SWEEP_PROXY_METHODS:GetRotation()
		return self.sweep_rotation
	end

	function POLYHEDRON_SWEEP_PROXY_METHODS:LocalToWorld(local_point, position, rotation)
		position = position or self.sweep_position
		rotation = rotation or self.sweep_rotation
		return position + rotation:VecMul(local_point)
	end

	local POLYHEDRON_SWEEP_PROXY_META = {
		__index = function(self, key)
			local method = POLYHEDRON_SWEEP_PROXY_METHODS[key]

			if method ~= nil then return method end

			return self.collider[key]
		end,
	}

	function get_polyhedron_sweep_proxy(collider, position, rotation)
		local proxy = collider.polyhedron_sweep_proxy

		if not proxy then
			proxy = setmetatable({_PhysicsPolyhedronWorldVerticesCache = {}}, POLYHEDRON_SWEEP_PROXY_META)
			collider.polyhedron_sweep_proxy = proxy
		end

		proxy.collider = collider
		proxy.sweep_position = position
		proxy.sweep_rotation = rotation
		return proxy
	end
end

local function evaluate_polyhedron_triangle_contact(collider, polyhedron, position, rotation, v0, v1, v2)
	return polyhedron_triangle_contacts.FindContact(
		get_polyhedron_sweep_proxy(collider, position, rotation),
		polyhedron,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			triangle_slop = 0,
			manifold_merge_distance = 0.08,
		}
	)
end

local function build_polyhedron_triangle_sweep_hit(collider, polyhedron, position, rotation, v0, v1, v2, triangle_result, t)
	if not triangle_result then return nil end

	local point, contact_position = get_average_contact_positions(triangle_result.contacts)

	if not contact_position then
		point = triangle_result.point_a
		contact_position = triangle_result.point_b
	end

	if not (contact_position and triangle_result.normal) then return nil end

	return {
		t = t,
		point = point,
		position = contact_position,
		normal = triangle_result.normal,
	}
end

function sweep_polyhedron_against_triangle(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	v0,
	v1,
	v2,
	max_fraction
)
	local triangle_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, EPSILON)

	if triangle_normal then
		local sweep_fraction = math.max(0, max_fraction or 1)
		local hit_distance = math.max(
			(collider:GetCollisionMargin() or 0),
			(physics_constants.DEFAULT_COLLISION_MARGIN or 0) * 0.5,
			0.0005
		)
		local prism_vertices = fill_triangle_prism_vertices(
			TRIANGLE_SWEEP_PRISM_VERTICES,
			v0,
			v1,
			v2,
			triangle_normal,
			math.max(
				(collider:GetCollisionMargin() or 0) * 0.5,
				(physics_constants.DEFAULT_COLLISION_MARGIN or 0) * 0.5,
				0.0005
			)
		)
		local triangle_center = (v0 + v1 + v2) / 3
		local scratch = {}
		local hit = pair_solver_helpers.FindDistanceSweepHit(
			function(alpha)
				local t = alpha * sweep_fraction
				local position = start_position + movement * t
				local proxy = get_polyhedron_sweep_proxy(collider, position, rotation)
				local poly_vertices = polyhedron_cache.GetPolyhedronWorldVertices(proxy, polyhedron)
				local result = gjk_epa.Distance(
					poly_vertices,
					prism_vertices,
					scratch.last_normal or (position - triangle_center),
					scratch.simplex
				)
				scratch.simplex = result and result.simplex or scratch.simplex

				if result and result.normal then scratch.last_normal = result.normal end

				return result
			end,
			hit_distance,
			movement,
			movement:GetLength() * sweep_fraction,
			nil
		)

		if hit and (hit.distance or math.huge) <= hit_distance + EPSILON then
			local hit_t = hit.t * sweep_fraction
			local result = evaluate_polyhedron_triangle_contact(
				collider,
				polyhedron,
				start_position + movement * hit_t,
				rotation,
				v0,
				v1,
				v2
			)

			if result then
				return build_polyhedron_triangle_sweep_hit(
					collider,
					polyhedron,
					start_position + movement * hit.t,
					rotation,
					v0,
					v1,
					v2,
					result,
					hit_t
				)
			end
		end
	end

	local start_result = evaluate_polyhedron_triangle_contact(collider, polyhedron, start_position, rotation, v0, v1, v2)

	if start_result then
		return build_polyhedron_triangle_sweep_hit(collider, polyhedron, start_position, rotation, v0, v1, v2, start_result, 0)
	end

	local steps = sweep_helpers.GetPolyhedronSweepSampleSteps(
		polyhedron,
		movement:GetLength(),
		max_fraction,
		POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS,
		POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS
	)
	local previous_t = 0
	local previous_position = start_position

	for i = 1, steps do
		local t = max_fraction * (i / steps)
		local position = start_position + movement * t
		local result = evaluate_polyhedron_triangle_contact(collider, polyhedron, position, rotation, v0, v1, v2)

		if result then
			local low = previous_t
			local high = t
			local best_t = t
			local best_result = result

			for _ = 1, POLYHEDRON_SWEEP_REFINE_STEPS do
				local mid = (low + high) * 0.5
				local mid_position = start_position + movement * mid
				local mid_result = evaluate_polyhedron_triangle_contact(collider, polyhedron, mid_position, rotation, v0, v1, v2)

				if mid_result then
					best_t = mid
					best_result = mid_result
					high = mid
				else
					low = mid
				end
			end

			return build_polyhedron_triangle_sweep_hit(
				collider,
				polyhedron,
				start_position + movement * best_t,
				rotation,
				v0,
				v1,
				v2,
				best_result,
				best_t
			)
		end

		previous_t = t
		previous_position = position
	end

	return nil
end

local function build_polyhedron_local_vertices(polyhedron, position, rotation, world_to_local, out)
	out = out or {}

	for i, local_vertex in ipairs(polyhedron.vertices or {}) do
		local world_point = position + rotation:VecMul(local_vertex)
		out[i] = world_to_local and world_to_local:TransformVector(world_point) or world_point
	end

	for i = #(polyhedron.vertices or {}) + 1, #out do
		out[i] = nil
	end

	return out
end

local function sweep_polyhedron_against_planes(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	planes,
	max_fraction,
	world_to_local,
	local_to_world
)
	if
		not (
			planes and
			planes[1] and
			polyhedron and
			polyhedron.vertices and
			polyhedron.vertices[1]
		)
	then
		return nil
	end

	local epsilon = EPSILON
	local start_local_vertices = build_polyhedron_local_vertices(
		polyhedron,
		start_position,
		rotation,
		world_to_local,
		collider.sweep_local_vertices
	)
	collider.sweep_local_vertices = start_local_vertices
	local start_local_origin = world_to_local and
		world_to_local:TransformVector(start_position) or
		start_position
	local end_local_origin = world_to_local and
		world_to_local:TransformVector(start_position + movement * max_fraction) or
		(
			start_position + movement * max_fraction
		)
	local movement_local = end_local_origin - start_local_origin
	local t_enter = 0
	local t_exit = max_fraction
	local enter_normal = nil
	local origin_inside = true
	local nearest_inside_normal = nil
	local nearest_inside_distance = -math.huge

	for _, plane in ipairs(planes) do
		local start_distance = -math.huge

		for _, vertex in ipairs(start_local_vertices) do
			start_distance = math.max(start_distance, vertex:Dot(plane.normal) - plane.dist)
		end

		local delta_distance = movement_local:Dot(plane.normal)

		if start_distance > epsilon then
			origin_inside = false
		elseif start_distance > nearest_inside_distance then
			nearest_inside_distance = start_distance
			nearest_inside_normal = plane.normal
		end

		if math.abs(delta_distance) <= epsilon then
			if start_distance > epsilon then return nil end
		else
			local hit_t = -start_distance / delta_distance

			if delta_distance < 0 then
				if hit_t > t_enter then
					t_enter = hit_t
					enter_normal = plane.normal
				end
			else
				if hit_t < t_exit then t_exit = hit_t end
			end

			if t_enter - t_exit > epsilon then return nil end
		end
	end

	local hit_t = origin_inside and 0 or t_enter

	if hit_t < 0 or hit_t > max_fraction + epsilon then return nil end

	local hit_local_vertices = collider.sweep_hit_local_vertices or {}
	collider.sweep_hit_local_vertices = hit_local_vertices

	for i = 1, #start_local_vertices do
		hit_local_vertices[i] = start_local_vertices[i] + movement_local * hit_t
	end

	local local_normal = origin_inside and nearest_inside_normal or enter_normal

	if not local_normal then return nil end

	local point_local = nil
	local signed_distance = -math.huge

	for _, vertex in ipairs(hit_local_vertices) do
		local distance = vertex:Dot(local_normal) - planes[1].dist

		if distance > signed_distance then
			signed_distance = distance
			point_local = vertex
		end
	end

	for _, plane in ipairs(planes) do
		if plane.normal == local_normal then
			signed_distance = point_local:Dot(local_normal) - plane.dist

			break
		end
	end

	local contact_local = point_local - local_normal * signed_distance
	local point_world = local_to_world and local_to_world:TransformVector(point_local) or point_local
	local contact_world = local_to_world and local_to_world:TransformVector(contact_local) or contact_local
	local normal_world = local_to_world and
		transform_direction(local_to_world, local_normal) or
		local_normal
	return {
		t = math.max(0, hit_t),
		point = point_world,
		position = contact_world,
		normal = normal_world,
	}
end

-- invariants are built once per sweep and shared by every triangle test:
-- the capsule's start segment, radius and movement-derived constants.
local function build_capsule_sweep_invariants(collider, start_position, rotation, movement, out)
	out = out or {}
	local segment_a, segment_b, radius = capsule_geometry.GetSegmentWorld(collider, start_position, rotation)
	local segment_length = (segment_b - segment_a):GetLength()
	out.segment_a = segment_a
	out.segment_b = segment_b
	out.radius = radius
	out.start_position = start_position
	out.movement = movement
	out.movement_length = movement:GetLength()
	out.distance_scale = math.max(radius * 0.5 + segment_length * 0.25, 0.2)
	out.fallback_normal = out.movement_length > EPSILON and
		(
			movement * -1
		):GetNormalized() or
		physics_constants.UP
	return out
end

local function get_capsule_sweep_sample_steps(invariants, max_fraction)
	local scaled_length = math.max(0, invariants.movement_length * math.max(max_fraction or 1, 0))
	return math.max(4, math.min(64, math.ceil(scaled_length / invariants.distance_scale) * 2))
end

-- takes the unnormalized face normal: "signed distance > radius" becomes
-- "d > 0 and d^2 > (radius * len)^2", exact for same-sign sides and free of
-- the normalization sqrt
local function is_capsule_moving_away_from_triangle(invariants, v0, nx, ny, nz, normal_len_sq)
	local segment_a = invariants.segment_a
	local segment_b = invariants.segment_b
	local movement = invariants.movement
	local d_a = (segment_a.x - v0.x) * nx + (segment_a.y - v0.y) * ny + (segment_a.z - v0.z) * nz
	local d_b = (segment_b.x - v0.x) * nx + (segment_b.y - v0.y) * ny + (segment_b.z - v0.z) * nz
	local movement_dot = movement.x * nx + movement.y * ny + movement.z * nz
	local threshold = (invariants.radius * invariants.radius) * normal_len_sq
	return (
			d_a > 0 and
			d_a * d_a > threshold and
			d_b > 0 and
			d_b * d_b > threshold and
			movement_dot >= 0
		)
		or
		(
			d_a < 0 and
			d_a * d_a > threshold and
			d_b < 0 and
			d_b * d_b > threshold and
			movement_dot <= 0
		)
end

local function narrow_reach_interval(t_lo, t_hi, c0, e, v, smin, smax)
	if v == 0 then
		if c0 - e >= smax or c0 + e <= smin then return nil end

		return t_lo, t_hi
	end

	if v > 0 then
		t_hi = math.min(t_hi, (smax - c0 + e) / v)
		t_lo = math.max(t_lo, (smin - c0 - e) / v)
	else
		t_lo = math.max(t_lo, (smax - c0 + e) / v)
		t_hi = math.min(t_hi, (smin - c0 - e) / v)
	end

	if t_lo >= t_hi then return nil end

	return t_lo, t_hi
end

local function is_capsule_sweep_reachable(invariants, max_fraction, v0, v1, v2)
	local radius = invariants.radius
	local segment_a = invariants.segment_a
	local segment_b = invariants.segment_b
	local movement = invariants.movement
	local extx = math.abs(segment_b.x - segment_a.x) * 0.5 + radius
	local exty = math.abs(segment_b.y - segment_a.y) * 0.5 + radius
	local extz = math.abs(segment_b.z - segment_a.z) * 0.5 + radius
	local t_lo, t_hi = narrow_reach_interval(
		0,
		max_fraction,
		(segment_a.x + segment_b.x) * 0.5,
		extx,
		movement.x,
		math.min(v0.x, v1.x, v2.x),
		math.max(v0.x, v1.x, v2.x)
	)

	if not t_lo then return false end

	t_lo, t_hi = narrow_reach_interval(
		t_lo,
		t_hi,
		(segment_a.y + segment_b.y) * 0.5,
		exty,
		movement.y,
		math.min(v0.y, v1.y, v2.y),
		math.max(v0.y, v1.y, v2.y)
	)

	if not t_lo then return false end

	t_lo, t_hi = narrow_reach_interval(
		t_lo,
		t_hi,
		(segment_a.z + segment_b.z) * 0.5,
		extz,
		movement.z,
		math.min(v0.z, v1.z, v2.z),
		math.max(v0.z, v1.z, v2.z)
	)
	return t_lo ~= nil
end

local SWEEP_STATS = {
	candidate_triangles = 0,
	plane_rejected = 0,
	reach_rejected = 0,
	distance_calls = 0,
	scalar_fallbacks = 0,
	start_hits = 0,
	hits = 0,
	newton_steps = 0,
	bisect_steps = 0,
	low_newton_available = 0,
	high_newton_available = 0,
}

-- Vec3-based separation; fallback for triangles the scalar kernel can't
-- handle, and source of the exact contact for the final hit build.
local function get_capsule_triangle_separation_sq(invariants, t, v0, v1, v2, face_normal)
	local delta = invariants.movement * t
	local result = triangle_contact_queries.GetCapsuleTriangleSeparation(
		invariants.segment_a + delta,
		invariants.segment_b + delta,
		invariants.start_position + delta,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			face_normal = face_normal,
			fallback_normal = invariants.fallback_normal,
		}
	)

	if not result then return nil end

	local distance = result.distance

	if distance <= EPSILON and face_normal then
		result.normal = ensure_normal_faces_motion(face_normal, invariants.movement)
	end

	return result.segment_point, result.position, distance * distance, result.normal
end

-- squared-distance sweep predicate on the allocation-free scalar kernel:
-- no Vec3 construction, no sqrt, no normalization on this path.
local function eval_capsule_triangle_distance_sq(invariants, t, v0, v1, v2, face_normal)
	local movement = invariants.movement
	local dx = movement.x * t
	local dy = movement.y * t
	local dz = movement.z * t
	local segment_a = invariants.segment_a
	local segment_b = invariants.segment_b
	local distance_sq, sx, sy, sz, qx, qy, qz = triangle_scalar.SegmentToTriangleSq(
		segment_a.x + dx,
		segment_a.y + dy,
		segment_a.z + dz,
		segment_b.x + dx,
		segment_b.y + dy,
		segment_b.z + dz,
		v0.x,
		v0.y,
		v0.z,
		v1.x,
		v1.y,
		v1.z,
		v2.x,
		v2.y,
		v2.z,
		face_normal,
		EPSILON
	)

	if distance_sq then return distance_sq, sx, sy, sz, qx, qy, qz end

	SWEEP_STATS.scalar_fallbacks = SWEEP_STATS.scalar_fallbacks + 1
	local segment_point, triangle_point, full_distance_sq = get_capsule_triangle_separation_sq(invariants, t, v0, v1, v2, face_normal)

	if not full_distance_sq then return nil end

	return full_distance_sq,
	segment_point.x,
	segment_point.y,
	segment_point.z,
	triangle_point.x,
	triangle_point.y,
	triangle_point.z
end

-- full Vec3 re-query of the closest pair; only used for degenerate
-- triangles, where the scalar kernel falls back to the Vec3 pipeline anyway
local function build_capsule_triangle_sweep_hit_vec3(invariants, v0, v1, v2, face_normal, t)
	local delta = invariants.movement * t
	local result = triangle_contact_queries.GetCapsuleTriangleSeparation(
		invariants.segment_a + delta,
		invariants.segment_b + delta,
		invariants.start_position + delta,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			face_normal = face_normal,
			fallback_normal = invariants.fallback_normal,
		}
	)

	if not result then return nil end

	local distance = result.distance

	if distance <= EPSILON and face_normal then
		result.normal = ensure_normal_faces_motion(face_normal, invariants.movement)
	end

	local segment_point = result.segment_point
	local triangle_point = result.position
	local normal = result.normal

	if not (segment_point and triangle_point and normal) then return nil end

	return {
		t = t,
		point = segment_point - normal * invariants.radius,
		position = triangle_point,
		normal = normal,
	}
end

-- direct hit construction from the scalar closest pair: no re-query of the
-- triangle. normal semantics match GetCapsuleTriangleSeparation: the pair
-- direction when separated, the face normal oriented against the motion
-- when penetrating
local function build_capsule_triangle_sweep_hit(invariants, face_normal, t, sp_x, sp_y, sp_z, tp_x, tp_y, tp_z, distance_sq)
	local epsilon = EPSILON
	local radius = invariants.radius
	local normal

	if distance_sq > epsilon * epsilon then
		local distance = math.sqrt(distance_sq)
		normal = Vec3((sp_x - tp_x) / distance, (sp_y - tp_y) / distance, (sp_z - tp_z) / distance)
	else
		local nx, ny, nz = face_normal.x, face_normal.y, face_normal.z
		local movement = invariants.movement

		if nx * movement.x + ny * movement.y + nz * movement.z > 0 then
			normal = face_normal * -1
		else
			normal = face_normal
		end
	end

	return {
		t = t,
		point = Vec3(sp_x - normal.x * radius, sp_y - normal.y * radius, sp_z - normal.z * radius),
		position = Vec3(tp_x, tp_y, tp_z),
		normal = normal,
	}
end

function sweep_capsule_against_triangle(invariants, v0, v1, v2, max_fraction)
	local epsilon = EPSILON
	local radius = invariants.radius
	local movement = invariants.movement
	local nx, ny, nz, normal_len_sq = triangle_scalar.TriangleNormalRaw(v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z)
	local is_degenerate = normal_len_sq <= epsilon * epsilon
	SWEEP_STATS.candidate_triangles = SWEEP_STATS.candidate_triangles + 1

	if
		not is_degenerate and
		is_capsule_moving_away_from_triangle(invariants, v0, nx, ny, nz, normal_len_sq)
	then
		SWEEP_STATS.plane_rejected = SWEEP_STATS.plane_rejected + 1
		return nil
	end

	if not is_capsule_sweep_reachable(invariants, max_fraction, v0, v1, v2) then
		SWEEP_STATS.reach_rejected = SWEEP_STATS.reach_rejected + 1
		return nil
	end

	-- the unit normal is only needed by triangles that survived both
	-- rejections; those ran on the unnormalized cross product
	local face_normal = nil

	if not is_degenerate then
		face_normal = Vec3(nx, ny, nz) * (1 / math.sqrt(normal_len_sq))
	end

	local hit_radius_sq = (radius + epsilon) * (radius + epsilon)
	SWEEP_STATS.distance_calls = SWEEP_STATS.distance_calls + 1
	local low_distance_sq, low_sx, low_sy, low_sz, low_qx, low_qy, low_qz = eval_capsule_triangle_distance_sq(invariants, 0, v0, v1, v2, face_normal)

	if low_distance_sq and low_distance_sq <= hit_radius_sq then
		SWEEP_STATS.start_hits = SWEEP_STATS.start_hits + 1
		SWEEP_STATS.hits = SWEEP_STATS.hits + 1

		if not face_normal then
			return build_capsule_triangle_sweep_hit_vec3(invariants, v0, v1, v2, nil, 0)
		end

		return build_capsule_triangle_sweep_hit(
			invariants,
			face_normal,
			0,
			low_sx,
			low_sy,
			low_sz,
			low_qx,
			low_qy,
			low_qz,
			low_distance_sq
		)
	end

	local steps = get_capsule_sweep_sample_steps(invariants, max_fraction)
	local low = 0
	local hit_t = nil
	local segment_x
	local segment_y
	local segment_z
	local triangle_x
	local triangle_y
	local triangle_z
	local distance_sq

	for i = 1, steps do
		local t = max_fraction * (i / steps)
		SWEEP_STATS.distance_calls = SWEEP_STATS.distance_calls + 1
		distance_sq, segment_x, segment_y, segment_z, triangle_x, triangle_y, triangle_z = eval_capsule_triangle_distance_sq(invariants, t, v0, v1, v2, face_normal)

		if distance_sq and distance_sq <= hit_radius_sq then
			hit_t = t

			break
		end

		low = t
		low_distance_sq = distance_sq
		low_sx = segment_x
		low_sy = segment_y
		low_sz = segment_z
		low_qx = triangle_x
		low_qy = triangle_y
		low_qz = triangle_z
	end

	if not hit_t then return nil end

	SWEEP_STATS.hits = SWEEP_STATS.hits + 1
	-- refine the first penetration time in (low, high]. the squared distance
	-- along the sweep is a smooth near-quadratic function of t, so Newton
	-- with the velocity-projection derivative converges in a few steps. the
	-- step is only taken from a bracket end where the capsule is still
	-- approaching the triangle (closing < 0); anything that would leave the
	-- bracket (kinks, tangential approach, flat regions) falls back to
	-- bisection, so progress is guaranteed.
	local high = hit_t
	local high_sx = segment_x
	local high_sy = segment_y
	local high_sz = segment_z
	local high_qx = triangle_x
	local high_qy = triangle_y
	local high_qz = triangle_z
	local high_distance_sq = distance_sq
	local consecutive_bisects = 0
	-- 1/4096 of the sample bracket matches the precision of the old 12-step
	-- bisection; 12 iterations is the worst case if every step bisects
	local tol_width = (high - low) * 2.4e-4

	for _ = 1, 12 do
		if high - low <= tol_width then break end

		local next_t = nil

		if consecutive_bisects < 3 then
			local closing = (
					low_sx - low_qx
				) * movement.x + (
					low_sy - low_qy
				) * movement.y + (
					low_sz - low_qz
				) * movement.z

			if closing < -1e-9 then
				SWEEP_STATS.low_newton_available = SWEEP_STATS.low_newton_available + 1
				next_t = low - (low_distance_sq - hit_radius_sq) / (2 * closing)
			end

			if not next_t or next_t <= low or next_t >= high then
				closing = (
						high_sx - high_qx
					) * movement.x + (
						high_sy - high_qy
					) * movement.y + (
						high_sz - high_qz
					) * movement.z

				if closing < -1e-9 then
					SWEEP_STATS.high_newton_available = SWEEP_STATS.high_newton_available + 1
					next_t = high - (high_distance_sq - hit_radius_sq) / (2 * closing)
				end
			end
		end

		if not next_t or next_t <= low or next_t >= high then
			next_t = (low + high) * 0.5
			consecutive_bisects = consecutive_bisects + 1
			SWEEP_STATS.bisect_steps = SWEEP_STATS.bisect_steps + 1
		else
			consecutive_bisects = 0
			SWEEP_STATS.newton_steps = SWEEP_STATS.newton_steps + 1
		end

		SWEEP_STATS.distance_calls = SWEEP_STATS.distance_calls + 1
		distance_sq, segment_x, segment_y, segment_z, triangle_x, triangle_y, triangle_z = eval_capsule_triangle_distance_sq(invariants, next_t, v0, v1, v2, face_normal)

		if distance_sq <= hit_radius_sq then
			high = next_t
			high_sx = segment_x
			high_sy = segment_y
			high_sz = segment_z
			high_qx = triangle_x
			high_qy = triangle_y
			high_qz = triangle_z
			high_distance_sq = distance_sq
		else
			low = next_t
			low_sx = segment_x
			low_sy = segment_y
			low_sz = segment_z
			low_qx = triangle_x
			low_qy = triangle_y
			low_qz = triangle_z
			low_distance_sq = distance_sq
		end
	end

	-- final polish: one Newton step from the current best estimate, accepted
	-- only if it stays inside the radius
	local closing = (
			high_sx - high_qx
		) * movement.x + (
			high_sy - high_qy
		) * movement.y + (
			high_sz - high_qz
		) * movement.z

	if closing < -1e-9 then
		local polish_t = high - (high_distance_sq - hit_radius_sq) / (2 * closing)

		if polish_t > low and polish_t < high then
			SWEEP_STATS.distance_calls = SWEEP_STATS.distance_calls + 1
			local polish_distance_sq = eval_capsule_triangle_distance_sq(invariants, polish_t, v0, v1, v2, face_normal)

			if polish_distance_sq and polish_distance_sq <= hit_radius_sq then
				high = polish_t
			end
		end
	end

	if not face_normal then
		return build_capsule_triangle_sweep_hit_vec3(invariants, v0, v1, v2, nil, high)
	end

	-- one final scalar evaluation at the accepted t so the contact pair
	-- matches the t the polish may have moved
	SWEEP_STATS.distance_calls = SWEEP_STATS.distance_calls + 1
	local hit_distance_sq, sp_x, sp_y, sp_z, tp_x, tp_y, tp_z = eval_capsule_triangle_distance_sq(invariants, high, v0, v1, v2, face_normal)

	if not hit_distance_sq then return nil end

	return build_capsule_triangle_sweep_hit(
		invariants,
		face_normal,
		high,
		sp_x,
		sp_y,
		sp_z,
		tp_x,
		tp_y,
		tp_z,
		hit_distance_sq
	)
end

local function sweep_capsule_against_planes(
	collider,
	start_position,
	rotation,
	movement,
	planes,
	max_fraction,
	world_to_local,
	local_to_world
)
	if not (planes and planes[1]) then return nil end

	local epsilon = EPSILON
	local start_a, start_b, radius = get_capsule_segment_world(collider, start_position, rotation)
	local start_local_a = world_to_local and world_to_local:TransformVector(start_a) or start_a
	local start_local_b = world_to_local and world_to_local:TransformVector(start_b) or start_b
	local end_position = start_position + movement * max_fraction
	local end_a, end_b = get_capsule_segment_world(collider, end_position, rotation)
	local end_local_a = world_to_local and world_to_local:TransformVector(end_a) or end_a
	local end_local_b = world_to_local and world_to_local:TransformVector(end_b) or end_b
	local delta_a = end_local_a - start_local_a
	local delta_b = end_local_b - start_local_b
	local t_enter = 0
	local t_exit = max_fraction
	local enter_normal = nil
	local origin_inside = true
	local nearest_inside_normal = nil
	local nearest_inside_distance = -math.huge

	for _, plane in ipairs(planes) do
		local start_distance = math.max(start_local_a:Dot(plane.normal), start_local_b:Dot(plane.normal)) - plane.dist - radius
		local delta_distance = math.max(delta_a:Dot(plane.normal), delta_b:Dot(plane.normal))

		if start_distance > epsilon then
			origin_inside = false
		elseif start_distance > nearest_inside_distance then
			nearest_inside_distance = start_distance
			nearest_inside_normal = plane.normal
		end

		if math.abs(delta_distance) <= epsilon then
			if start_distance > epsilon then return nil end
		else
			local hit_t = -start_distance / delta_distance

			if delta_distance < 0 then
				if hit_t > t_enter then
					t_enter = hit_t
					enter_normal = plane.normal
				end
			else
				if hit_t < t_exit then t_exit = hit_t end
			end

			if t_enter - t_exit > epsilon then return nil end
		end
	end

	local hit_t = origin_inside and 0 or t_enter

	if hit_t < 0 or hit_t > max_fraction + epsilon then return nil end

	local hit_a = start_a + (end_a - start_a) * hit_t
	local hit_b = start_b + (end_b - start_b) * hit_t
	local local_normal = origin_inside and nearest_inside_normal or enter_normal

	if not local_normal then return nil end

	local point_world = hit_a:Dot(
			local_to_world and
				transform_direction(local_to_world, local_normal) or
				local_normal
		) > hit_b:Dot(
			local_to_world and
				transform_direction(local_to_world, local_normal) or
				local_normal
		) and
		hit_a or
		hit_b
	local point_local = world_to_local and world_to_local:TransformVector(point_world) or point_world
	local normal_world = local_to_world and
		transform_direction(local_to_world, local_normal) or
		local_normal
	local contact_local = point_local - local_normal * (point_local:Dot(local_normal) - planes[1].dist)
	return {
		t = math.max(0, hit_t),
		point = point_world - normal_world * radius,
		position = local_to_world and local_to_world:TransformVector(contact_local) or contact_local,
		normal = normal_world,
	}
end

local function get_point_triangle_separation(center, v0, v1, v2, movement)
	local result = triangle_contact_queries.GetPointTriangleSeparation(
		center,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			fallback_normal = ensure_normal_faces_motion(triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, EPSILON), movement),
			fallback_direction = movement and movement * -1 or nil,
		}
	)
	return result.position, result.distance, result.normal
end

function sweep_sphere_against_triangle(start_position, movement, radius, v0, v1, v2, max_fraction)
	local epsilon = EPSILON
	local end_position = start_position + movement * max_fraction
	local start_closest, start_distance, start_normal = get_point_triangle_separation(start_position, v0, v1, v2, movement)

	if start_distance <= radius + epsilon then
		return {
			t = 0,
			position = start_closest,
			normal = start_normal,
		}
	end

	local segment_separation = triangle_contact_queries.GetSegmentTriangleSeparation(
		start_position,
		end_position,
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = ensure_normal_faces_motion(triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, epsilon), movement),
		}
	)
	local segment_point = segment_separation and segment_separation.segment_point or nil
	local min_distance = segment_separation and segment_separation.distance or nil

	if not segment_point or min_distance > radius + epsilon then return nil end

	local hi = get_segment_fraction(start_position, movement, segment_point)
	local hi_closest
	local hi_distance
	local hi_normal

	if hi > max_fraction then hi = max_fraction end

	if hi <= 0 then
		hi = max_fraction
		hi_closest, hi_distance, hi_normal = get_point_triangle_separation(start_position + movement * hi, v0, v1, v2, movement)

		if hi_distance > radius + epsilon then return nil end
	else
		hi_closest, hi_distance, hi_normal = get_point_triangle_separation(start_position + movement * hi, v0, v1, v2, movement)

		if hi_distance > radius + epsilon then
			hi = max_fraction
			hi_closest, hi_distance, hi_normal = get_point_triangle_separation(start_position + movement * hi, v0, v1, v2, movement)

			if hi_distance > radius + epsilon then return nil end
		end
	end

	local lo = 0

	for _ = 1, 24 do
		local mid = (lo + hi) * 0.5
		local _, distance = get_point_triangle_separation(start_position + movement * mid, v0, v1, v2, movement)

		if distance <= radius + epsilon then hi = mid else lo = mid end
	end

	local center = start_position + movement * hi
	local position, _, normal = get_point_triangle_separation(center, v0, v1, v2, movement)
	return {
		t = hi,
		position = position,
		normal = normal,
	}
end

local function sweep_sphere_against_planes(start_position, movement, radius, planes, max_fraction)
	if not (planes and planes[1]) then return nil end

	local epsilon = EPSILON
	local t_enter = 0
	local t_exit = max_fraction
	local enter_normal = nil
	local exit_normal = nil
	local origin_inside = true
	local nearest_inside_normal = nil
	local nearest_inside_distance = -math.huge

	for _, plane in ipairs(planes) do
		local normal = plane.normal
		local plane_distance = plane.dist + radius
		local start_distance = start_position:Dot(normal) - plane_distance
		local delta_distance = movement:Dot(normal)

		if start_distance > epsilon then
			origin_inside = false
		elseif start_distance > nearest_inside_distance then
			nearest_inside_distance = start_distance
			nearest_inside_normal = normal
		end

		if math.abs(delta_distance) <= epsilon then
			if start_distance > epsilon then return nil end
		else
			local hit_t = -start_distance / delta_distance

			if delta_distance < 0 then
				if hit_t > t_enter then
					t_enter = hit_t
					enter_normal = normal
				end
			else
				if hit_t < t_exit then
					t_exit = hit_t
					exit_normal = normal
				end
			end

			if t_enter - t_exit > epsilon then return nil end
		end
	end

	local hit_t = origin_inside and 0 or t_enter

	if hit_t < 0 or hit_t > max_fraction + epsilon then return nil end

	local center = start_position + movement * hit_t
	local normal = origin_inside and (nearest_inside_normal or exit_normal) or enter_normal

	if not normal then return nil end

	local position = center - normal * radius

	if origin_inside and nearest_inside_distance > -math.huge then
		position = center - normal * (nearest_inside_distance + radius)
	end

	return {
		t = math.max(0, hit_t),
		position = position,
		normal = normal,
	}
end

sweep_mesh.CollectMeshBodyPointSweepHit = collect_mesh_body_point_sweep_hit
sweep_mesh.CollectMeshBodyColliderSweepHit = collect_mesh_body_collider_sweep_hit
sweep_mesh.MeshBodyPointSweepContext = MESH_BODY_POINT_SWEEP_CONTEXT
sweep_mesh.MeshBodyColliderSweepContext = MESH_BODY_COLLIDER_SWEEP_CONTEXT
sweep_mesh.PointCapsuleSegmentEvaluationContext = POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT
sweep_mesh.EvaluatePointAgainstCapsuleSegment = evaluate_point_against_capsule_segment
sweep_mesh.ForEachOverlappingWorldTriangle = for_each_overlapping_world_triangle
sweep_mesh.GetPrimitiveQueryAABB = get_primitive_query_aabb
sweep_mesh.GetPrimitiveLocalMotion = get_primitive_local_motion
sweep_mesh.GetPrimitiveLocalToWorld = get_primitive_local_to_world
sweep_mesh.GetPolyhedronSweepProxy = get_polyhedron_sweep_proxy
sweep_mesh.TransformDirection = transform_direction
sweep_mesh.SweepSphereAgainstTriangle = sweep_sphere_against_triangle
sweep_mesh.SweepCapsuleAgainstTriangle = sweep_capsule_against_triangle
sweep_mesh.BuildCapsuleSweepInvariants = build_capsule_sweep_invariants
sweep_mesh.SweepStats = SWEEP_STATS
sweep_mesh.SweepPolyhedronAgainstTriangle = sweep_polyhedron_against_triangle
return sweep_mesh
