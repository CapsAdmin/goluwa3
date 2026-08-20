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
	target_position = nil,
	target_rotation = nil,
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

local function collect_mesh_body_point_sweep_hit(v0, v1, v2, triangle_index, context)
	local shape = context.collider:GetPhysicsShape()
	local wv0, wv1, wv2 = shape:GetTriangleWorldVertices(context.collider, context.target_position, context.target_rotation, v0, v1, v2)
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
	local shape = context.target_collider:GetPhysicsShape()
	local wv0, wv1, wv2 = shape:GetTriangleWorldVertices(
		context.target_collider,
		context.target_position,
		context.target_rotation,
		v0,
		v1,
		v2
	)
	local hit = nil

	if context.query_shape_type == "capsule" then
		hit = sweep_capsule_against_triangle(
			context.collider,
			context.start_position,
			context.rotation,
			context.movement,
			wv0,
			wv1,
			wv2,
			context.max_fraction
		)
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
			(collider.GetCollisionMargin and collider:GetCollisionMargin() or 0),
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
				(collider.GetCollisionMargin and collider:GetCollisionMargin() or 0) * 0.5,
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
					{
						initial_direction = scratch.last_normal or (position - triangle_center),
						simplex = scratch.simplex,
					}
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


local function get_capsule_triangle_separation(position, rotation, collider, v0, v1, v2, movement)
	local physics = collider:GetPhysics()
	local segment_a, segment_b = get_capsule_segment_world(collider, position, rotation)
	local result = triangle_contact_queries.GetCapsuleTriangleSeparation(
		segment_a,
		segment_b,
		position,
		v0,
		v1,
		v2,
		{
			epsilon = EPSILON,
			fallback_normal = movement and
				movement:GetLength() > EPSILON and
				(
					movement * -1
				):GetNormalized() or
				physics_constants.UP,
			zero_distance_normal = ensure_normal_faces_motion(triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, EPSILON), movement),
		}
	)

	if not result then return nil end

	return result.segment_point, result.position, result.distance, result.normal
end

local function get_capsule_sweep_sample_steps(collider, movement_length, max_fraction)
	local segment_a, segment_b, radius = get_capsule_segment_world(collider, collider:GetPosition(), collider:GetRotation())
	local segment_length = segment_a and segment_b and (segment_b - segment_a):GetLength() or 0
	local distance_scale = math.max(radius * 0.5 + segment_length * 0.25, 0.2)
	local scaled_length = math.max(0, movement_length * math.max(max_fraction or 1, 0))
	return math.max(4, math.min(64, math.ceil(scaled_length / distance_scale) * 2))
end

local function build_capsule_triangle_sweep_hit(collider, position, rotation, v0, v1, v2, movement, t)
	local segment_point, triangle_point, _, normal = get_capsule_triangle_separation(position, rotation, collider, v0, v1, v2, movement)
	local shape = collider:GetPhysicsShape()
	local radius = shape and shape.GetRadius and shape:GetRadius() or 0

	if not (segment_point and triangle_point and normal) then return nil end

	return {
		t = t,
		point = segment_point - normal * radius,
		position = triangle_point,
		normal = normal,
	}
end

function sweep_capsule_against_triangle(collider, start_position, rotation, movement, v0, v1, v2, max_fraction)
	local epsilon = EPSILON
	local shape = collider:GetPhysicsShape()
	local radius = shape and shape.GetRadius and shape:GetRadius() or 0
	local _, _, start_distance = get_capsule_triangle_separation(start_position, rotation, collider, v0, v1, v2, movement)

	if start_distance and start_distance <= radius + epsilon then
		return build_capsule_triangle_sweep_hit(collider, start_position, rotation, v0, v1, v2, movement, 0)
	end

	local steps = get_capsule_sweep_sample_steps(collider, movement:GetLength(), max_fraction)
	local low = 0
	local hit_t = nil

	for i = 1, steps do
		local t = max_fraction * (i / steps)
		local position = start_position + movement * t
		local _, _, distance = get_capsule_triangle_separation(position, rotation, collider, v0, v1, v2, movement)

		if distance and distance <= radius + epsilon then
			hit_t = t

			break
		end

		low = t
	end

	if not hit_t then return nil end

	local high = hit_t

	for _ = 1, 12 do
		local mid = (low + high) * 0.5
		local position = start_position + movement * mid
		local _, _, distance = get_capsule_triangle_separation(position, rotation, collider, v0, v1, v2, movement)

		if distance and distance <= radius + epsilon then
			high = mid
		else
			low = mid
		end
	end

	return build_capsule_triangle_sweep_hit(collider, start_position + movement * high, rotation, v0, v1, v2, movement, high)
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
sweep_mesh.SweepPolyhedronAgainstTriangle = sweep_polyhedron_against_triangle

return sweep_mesh
