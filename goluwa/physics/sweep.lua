local physics = import("goluwa/physics.lua")
local BVH = import("goluwa/physics/bvh.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron_cache.lua")
local polyhedron_geometry = import("goluwa/physics/polyhedron_geometry.lua")
local polyhedron_triangle_contacts = import("goluwa/physics/polyhedron_triangle_contacts.lua")
local raycast = import("goluwa/physics/raycast.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local triangle_contact_kernels = import("goluwa/physics/triangle_contact_kernels.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local world_static_query = import("goluwa/physics/world_static_query.lua")
local world_mesh_body = import("goluwa/physics/world_mesh_body.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local RigidBodyComponent = import("goluwa/physics/rigid_body.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS = 4
local POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS = 18
local POLYHEDRON_SWEEP_REFINE_STEPS = 10
local convex_manifold = nil
local convex_sat = nil
local get_polyhedron_sweep_proxy

local function build_triangle_hit(model, entity, primitive, primitive_index, triangle_index)
	return {
		entity = entity,
		model = model,
		primitive = primitive,
		primitive_index = primitive_index,
		triangle_index = triangle_index,
	}
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

local function get_epsilon()
	return physics.EPSILON or 0.000001
end

local function ensure_convex_helpers()
	if convex_manifold and convex_sat then return end

	convex_manifold = import("goluwa/physics/convex_manifold.lua")
	convex_sat = import("goluwa/physics/convex_sat.lua")
end

local function normalize_query_options(options)
	options = options or {}

	if options.IncludeRigidBodies ~= nil and options.IgnoreRigidBodies == nil then
		options.IgnoreRigidBodies = not options.IncludeRigidBodies
	end

	if options.IncludeKinematicBodies ~= nil and options.IgnoreKinematicBodies == nil then
		options.IgnoreKinematicBodies = not options.IncludeKinematicBodies
	end

	if options.IncludeWorld ~= nil and options.IgnoreWorld == nil then
		options.IgnoreWorld = not options.IncludeWorld
	end

	return options
end

local function clamp01(value)
	return math.max(0, math.min(1, value or 0))
end

local function get_sweep_alpha(t, max_fraction)
	if not max_fraction or math.abs(max_fraction) <= get_epsilon() then return 0 end

	return clamp01(t / max_fraction)
end

local function interpolate_rotation(previous_rotation, current_rotation, t, max_fraction)
	previous_rotation = previous_rotation or current_rotation
	current_rotation = current_rotation or previous_rotation

	if not previous_rotation then return current_rotation end

	local alpha = get_sweep_alpha(t, max_fraction)
	local target_rotation = current_rotation

	if previous_rotation:Dot(target_rotation) < 0 then
		target_rotation = target_rotation * -1
	end

	return previous_rotation:GetLerped(alpha, target_rotation):GetNormalized()
end

local function interpolate_position(previous_position, movement, t)
	return previous_position + movement * t
end

local function build_target_motion_state(target)
	local previous_position = target.GetPreviousPosition and
		target:GetPreviousPosition() or
		target:GetPosition()
	local previous_rotation = target.GetPreviousRotation and
		target:GetPreviousRotation() or
		target:GetRotation()
	local current_position = target.GetPosition and target:GetPosition() or previous_position
	local current_rotation = target.GetRotation and target:GetRotation() or previous_rotation
	local movement = current_position and
		previous_position and
		(
			current_position - previous_position
		)
		or
		Vec3()
	return {
		previous_position = previous_position,
		previous_rotation = previous_rotation,
		current_position = current_position,
		current_rotation = current_rotation,
		movement = movement,
	}
end

local function get_target_pose(state, t, max_fraction)
	return interpolate_position(state.previous_position, state.movement, t),
	interpolate_rotation(state.previous_rotation, state.current_rotation, t, max_fraction)
end

local function passes_entity_filter(entity, ignore_entity, filter_fn, options)
	if not entity or entity == ignore_entity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if (options and options.IgnoreRigidBodies ~= false) and entity.rigid_body then
		return false
	end

	if
		(
			options and
			options.IgnoreKinematicBodies ~= false
		)
		and
		entity.rigid_body and
		entity.rigid_body.IsKinematic and
		entity.rigid_body:IsKinematic()
	then
		return false
	end

	if filter_fn and not filter_fn(entity) then return false end

	return true
end

local function build_swept_aabb(start_position, end_position, radius)
	radius = math.max(radius or 0, 0)
	return AABB(
		math.min(start_position.x, end_position.x) - radius,
		math.min(start_position.y, end_position.y) - radius,
		math.min(start_position.z, end_position.z) - radius,
		math.max(start_position.x, end_position.x) + radius,
		math.max(start_position.y, end_position.y) + radius,
		math.max(start_position.z, end_position.z) + radius
	)
end

local function get_segment_fraction(start_position, movement, point)
	local movement_length_sq = movement:Dot(movement)

	if movement_length_sq <= get_epsilon() * get_epsilon() then return 0 end

	return clamp01((point - start_position):Dot(movement) / movement_length_sq)
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

local function ensure_normal_faces_motion(normal, movement)
	if not normal then return nil end

	if movement and normal:Dot(movement) > 0 then return normal * -1 end

	return normal
end

local function merge_aabb(a, b)
	if not a then return b end

	if not b then return a end

	return AABB(
		math.min(a.min_x, b.min_x),
		math.min(a.min_y, b.min_y),
		math.min(a.min_z, b.min_z),
		math.max(a.max_x, b.max_x),
		math.max(a.max_y, b.max_y),
		math.max(a.max_z, b.max_z)
	)
end

local function get_average_contact_positions(contacts)
	if not (contacts and contacts[1]) then return nil, nil end

	local point = Vec3(0, 0, 0)
	local position = Vec3(0, 0, 0)
	local count = 0

	for _, pair in ipairs(contacts) do
		if pair.point_a and pair.point_b then
			point = point + pair.point_a
			position = position + pair.point_b
			count = count + 1
		end
	end

	if count == 0 then return nil, nil end

	return point / count, position / count
end

local function get_support_point(vertices, direction)
	if not (vertices and vertices[1] and direction) then return nil end

	local best_point = vertices[1]
	local best_dot = best_point:Dot(direction)

	for i = 2, #vertices do
		local point = vertices[i]
		local dot = point:Dot(direction)

		if dot > best_dot then
			best_dot = dot
			best_point = point
		end
	end

	return best_point
end

local function get_polyhedron_pair_contact_positions(result, scratch)
	if not result then return nil, nil end

	local point, position = get_average_contact_positions(result.contacts)

	if point and position then return point, position end

	local normal = result.normal
	local vertices_a = scratch and scratch.vertices_a or nil
	local vertices_b = scratch and scratch.vertices_b or nil
	point = point or get_support_point(vertices_a, normal * -1)
	position = position or get_support_point(vertices_b, normal)
	return point, position
end

local function get_polyhedron_extent(polyhedron)
	if not (polyhedron and polyhedron.vertices and polyhedron.vertices[1]) then
		return 1
	end

	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, point in ipairs(polyhedron.vertices) do
		min_x = math.min(min_x, point.x)
		min_y = math.min(min_y, point.y)
		min_z = math.min(min_z, point.z)
		max_x = math.max(max_x, point.x)
		max_y = math.max(max_y, point.y)
		max_z = math.max(max_z, point.z)
	end

	return Vec3(max_x - min_x, max_y - min_y, max_z - min_z):GetLength()
end

local function get_polyhedron_sweep_sample_steps(polyhedron, movement_length, max_fraction)
	local extent = math.max(get_polyhedron_extent(polyhedron), 0.25)
	local scaled_length = math.max(0, movement_length * math.max(0, max_fraction or 1))
	return math.max(
		POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS,
		math.min(POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS, math.ceil(scaled_length / (extent * 0.35)))
	)
end

local function evaluate_polyhedron_triangle_contact(collider, polyhedron, position, rotation, v0, v1, v2)
	return polyhedron_triangle_contacts.FindContact(
		get_polyhedron_sweep_proxy(collider, position, rotation),
		polyhedron,
		v0,
		v1,
		v2,
		{
			epsilon = get_epsilon(),
			triangle_slop = 0,
			manifold_merge_distance = 0.08,
			face_axis_relative_tolerance = 1.05,
			face_axis_absolute_tolerance = 0.03,
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

local function sweep_polyhedron_against_triangle(
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
	local start_result = evaluate_polyhedron_triangle_contact(collider, polyhedron, start_position, rotation, v0, v1, v2)

	if start_result then
		return build_polyhedron_triangle_sweep_hit(collider, polyhedron, start_position, rotation, v0, v1, v2, start_result, 0)
	end

	local steps = get_polyhedron_sweep_sample_steps(polyhedron, movement:GetLength(), max_fraction)
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

	local epsilon = get_epsilon()
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

local function build_collider_swept_aabb(collider, start_position, rotation, movement)
	local shape = collider:GetPhysicsShape()
	local end_position = start_position + movement
	local start_aabb = shape.GetBroadphaseAABB and
		shape:GetBroadphaseAABB(collider, start_position, rotation) or
		nil
	local end_aabb = shape.GetBroadphaseAABB and
		shape:GetBroadphaseAABB(collider, end_position, rotation) or
		nil
	return merge_aabb(start_aabb, end_aabb) or
		build_swept_aabb(start_position, end_position, 0)
end

local function get_capsule_segment_world(collider, position, rotation)
	return capsule_geometry.GetSegmentWorld(collider, position, rotation)
end

local function get_capsule_triangle_separation(position, rotation, collider, v0, v1, v2, movement)
	local segment_a, segment_b = get_capsule_segment_world(collider, position, rotation)
	local result = triangle_contact_kernels.GetCapsuleTriangleSeparation(
		segment_a,
		segment_b,
		position,
		v0,
		v1,
		v2,
		{
			epsilon = get_epsilon(),
			fallback_normal = movement and movement:GetLength() > get_epsilon() and (movement * -1):GetNormalized() or physics.Up,
			zero_distance_normal = ensure_normal_faces_motion(triangle_geometry.GetTriangleNormal(v0, v1, v2), movement),
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
	return math.max(4, math.min(20, math.ceil(scaled_length / distance_scale) * 2))
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

local function sweep_capsule_against_triangle(collider, start_position, rotation, movement, v0, v1, v2, max_fraction)
	local epsilon = get_epsilon()
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

	local epsilon = get_epsilon()
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
	local result = triangle_contact_kernels.GetPointTriangleSeparation(
		center,
		v0,
		v1,
		v2,
		{
			epsilon = get_epsilon(),
			fallback_normal = ensure_normal_faces_motion(triangle_geometry.GetTriangleNormal(v0, v1, v2), movement),
			fallback_direction = movement and movement * -1 or nil,
		}
	)
	return result.position, result.distance, result.normal
end

local function sweep_sphere_against_triangle(start_position, movement, radius, v0, v1, v2, max_fraction)
	local epsilon = get_epsilon()
	local end_position = start_position + movement * max_fraction
	local start_closest, start_distance, start_normal = get_point_triangle_separation(start_position, v0, v1, v2, movement)

	if start_distance <= radius + epsilon then
		return {
			t = 0,
			position = start_closest,
			normal = start_normal,
		}
	end

	local segment_point, _, min_distance = triangle_geometry.ClosestPointsOnSegmentTriangle(
		start_position,
		end_position,
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = ensure_normal_faces_motion(triangle_geometry.GetTriangleNormal(v0, v1, v2), movement),
		}
	)

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

	local epsilon = get_epsilon()
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

local function should_skip_model(model, ignore_entity, filter_fn, options)
	if not (model and model.Visible and model.Primitives and model.Primitives[1]) then
		return true
	end

	return not passes_entity_filter(model.Owner, ignore_entity, filter_fn, options)
end

local function should_skip_rigid_body(body, ignore_entity, filter_fn, options)
	if not physics.IsActiveRigidBody(body) then return true end

	local owner = body.Owner

	if not owner or owner == ignore_entity then return true end

	if owner.PhysicsNoCollision or owner.NoPhysicsCollision then return true end

	if
		(
			options and
			options.IgnoreKinematicBodies ~= false
		)
		and
		body.IsKinematic and
		body:IsKinematic()
	then
		return true
	end

	if filter_fn and not filter_fn(owner) then return true end

	return false
end

local function get_rigid_body_candidate_aabb(body)
	if not body.GetBroadphaseAABB then return nil end

	local current_position = body.GetPosition and body:GetPosition() or nil
	local current_rotation = body.GetRotation and body:GetRotation() or nil
	local bounds = body:GetBroadphaseAABB(current_position, current_rotation)
	local previous_position = body.GetPreviousPosition and body:GetPreviousPosition() or nil
	local previous_rotation = body.GetPreviousRotation and body:GetPreviousRotation() or nil

	if
		not bounds or
		not previous_position or
		not previous_rotation or
		not current_position or
		not current_rotation
	then
		return bounds
	end

	if previous_position == current_position and previous_rotation == current_rotation then
		return bounds
	end

	local previous_bounds = body:GetBroadphaseAABB(previous_position, previous_rotation)

	if not previous_bounds then return bounds end

	local swept_bounds = AABB(
		bounds.min_x,
		bounds.min_y,
		bounds.min_z,
		bounds.max_x,
		bounds.max_y,
		bounds.max_z
	)
	swept_bounds:Expand(previous_bounds)
	return swept_bounds
end

local function get_collider_candidate_aabb(collider)
	if not collider.GetBroadphaseAABB then return nil end

	local current_position = collider.GetPosition and collider:GetPosition() or nil
	local current_rotation = collider.GetRotation and collider:GetRotation() or nil
	local bounds = collider:GetBroadphaseAABB(current_position, current_rotation)
	local previous_position = collider.GetPreviousPosition and collider:GetPreviousPosition() or nil
	local previous_rotation = collider.GetPreviousRotation and collider:GetPreviousRotation() or nil

	if
		not bounds or
		not previous_position or
		not previous_rotation or
		not current_position or
		not current_rotation
	then
		return bounds
	end

	local previous_bounds = collider:GetBroadphaseAABB(previous_position, previous_rotation)

	if not previous_bounds then return bounds end

	local swept_bounds = AABB(
		bounds.min_x,
		bounds.min_y,
		bounds.min_z,
		bounds.max_x,
		bounds.max_y,
		bounds.max_z
	)
	swept_bounds:Expand(previous_bounds)
	return swept_bounds
end

local function collect_rigid_body_candidates(world_aabb, ignore_entity, filter_fn, options, out)
	out = out or {}

	if options and options.IgnoreRigidBodies ~= false then return out end

	for _, body in ipairs(RigidBodyComponent.Instances or {}) do
		if not should_skip_rigid_body(body, ignore_entity, filter_fn, options) then
			local bounds = get_rigid_body_candidate_aabb(body)

			if bounds and AABB.IsBoxIntersecting(world_aabb, bounds) then
				out[#out + 1] = body
			end
		end
	end

	return out
end

local function build_rigid_body_hit(base_hit, movement, movement_length, body, collider)
	if not base_hit then return nil end

	return {
		entity = body and body.Owner or nil,
		rigid_body = body,
		collider = collider,
		position = base_hit.position,
		point = base_hit.point,
		normal = ensure_normal_faces_motion(base_hit.normal, movement),
		face_normal = ensure_normal_faces_motion(base_hit.normal, movement),
		fraction = base_hit.t,
		distance = movement_length * base_hit.t,
	}
end

local function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius)
	local movement = end_world - start_world
	local movement_length = movement:GetLength()

	if movement_length <= get_epsilon() then return nil end

	local function evaluate(t)
		local point = start_world + movement * t
		local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, point, get_epsilon())
		local delta = point - closest
		local distance = delta:GetLength()
		return point, closest, delta, distance
	end

	local _, _, _, start_distance = evaluate(0)

	if start_distance <= radius then return nil end

	local sample_steps = math.max(12, math.min(64, math.ceil(movement_length / math.max(radius, 0.125)) * 2))
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, _, _, distance = evaluate(t)

		if distance <= radius then
			local low = previous_t
			local high = t

			for _ = 1, 14 do
				local mid = (low + high) * 0.5
				local _, _, _, mid_distance = evaluate(mid)

				if mid_distance <= radius then high = mid else low = mid end
			end

			local point, closest, delta, final_distance = evaluate(high)
			local normal = final_distance > get_epsilon() and
				(
					delta / final_distance
				)
				or
				ensure_normal_faces_motion((point - ((segment_a + segment_b) * 0.5)):GetNormalized(), movement)

			if not normal or normal:GetLength() <= get_epsilon() then return nil end

			return {
				t = high,
				point = point - normal * radius,
				position = closest,
				normal = normal,
			}
		end

		previous_t = t
	end

	return nil
end

local function sweep_point_against_box_body(box_collider, start_world, end_world, extra_radius, position, rotation)
	local movement_world = end_world - start_world

	if movement_world:GetLength() <= get_epsilon() then return nil end

	local start_local = box_collider:WorldToLocal(start_world, position, rotation)
	local end_local = box_collider:WorldToLocal(end_world, position, rotation)
	local movement_local = end_local - start_local
	local extents = box_collider:GetPhysicsShape():GetExtents()
	extra_radius = math.max(extra_radius or 0, 0)
	local t_enter = 0
	local t_exit = 1
	local hit_normal_local = nil
	local axis_data = {
		{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
		{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
		{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
	}

	for _, axis in ipairs(axis_data) do
		local name = axis[1]
		local s = start_local[name]
		local d = movement_local[name]
		local min_value = -extents[name] - extra_radius
		local max_value = extents[name] + extra_radius

		if math.abs(d) <= get_epsilon() then
			if s < min_value or s > max_value then return nil end
		else
			local enter_t
			local exit_t
			local enter_normal

			if d > 0 then
				enter_t = (min_value - s) / d
				exit_t = (max_value - s) / d
				enter_normal = axis[2]
			else
				enter_t = (max_value - s) / d
				exit_t = (min_value - s) / d
				enter_normal = axis[3]
			end

			if enter_t > t_enter then
				t_enter = enter_t
				hit_normal_local = enter_normal
			end

			if exit_t < t_exit then t_exit = exit_t end

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	local normal = rotation:VecMul(hit_normal_local):GetNormalized()
	local center = start_world + movement_world * t_enter
	return {
		t = t_enter,
		point = center - normal * extra_radius,
		position = center - normal * extra_radius,
		normal = normal,
	}
end

local function get_box_contact_for_point_at_pose(box_collider, point, radius, position, rotation, movement_world)
	local local_point = box_collider:WorldToLocal(point, position, rotation)
	local extents = box_collider:GetPhysicsShape():GetExtents()
	local closest_local = Vec3(
		math.clamp(local_point.x, -extents.x, extents.x),
		math.clamp(local_point.y, -extents.y, extents.y),
		math.clamp(local_point.z, -extents.z, extents.z)
	)
	local closest_world = box_collider:LocalToWorld(closest_local, position, rotation)
	local delta = point - closest_world
	local distance = delta:GetLength()
	local overlap = radius - distance
	local normal

	if distance > get_epsilon() then
		normal = delta / distance
	elseif
		math.abs(local_point.x) <= extents.x and
		math.abs(local_point.y) <= extents.y and
		math.abs(local_point.z) <= extents.z
	then
		local movement_local = movement_world and rotation:GetConjugated():VecMul(movement_world) or Vec3()
		local candidates = {
			{
				name = "x",
				axis = Vec3(1, 0, 0),
				center = local_point.x,
				movement = movement_local.x,
				overlap = extents.x - math.abs(local_point.x),
			},
			{
				name = "y",
				axis = Vec3(0, 1, 0),
				center = local_point.y,
				movement = movement_local.y,
				overlap = extents.y - math.abs(local_point.y),
			},
			{
				name = "z",
				axis = Vec3(0, 0, 1),
				center = local_point.z,
				movement = movement_local.z,
				overlap = extents.z - math.abs(local_point.z),
			},
		}
		local best

		for _, candidate in ipairs(candidates) do
			local sign = math.sign(candidate.center)

			if sign == 0 then
				if math.abs(candidate.movement) > get_epsilon() then
					sign = math.sign(-candidate.movement)
				else
					sign = 1
				end
			end

			candidate.axis = candidate.axis * sign
			candidate.motion_weight = math.abs(candidate.movement)

			if
				not best or
				candidate.overlap < best.overlap - get_epsilon()
				or
				(
					math.abs(candidate.overlap - best.overlap) <= get_epsilon() and
					candidate.motion_weight > best.motion_weight + get_epsilon()
				)
			then
				best = candidate
			end
		end

		if best.name == "x" then
			closest_local = Vec3(best.axis.x * extents.x, local_point.y, local_point.z)
		elseif best.name == "y" then
			closest_local = Vec3(local_point.x, best.axis.y * extents.y, local_point.z)
		else
			closest_local = Vec3(local_point.x, local_point.y, best.axis.z * extents.z)
		end

		closest_world = box_collider:LocalToWorld(closest_local, position, rotation)
		normal = rotation:VecMul(best.axis):GetNormalized()
		overlap = radius + best.overlap
	else
		return nil
	end

	if overlap <= 0 or not normal then return nil end

	return {
		normal = normal,
		position = closest_world,
		point = point - normal * radius,
	}
end

local function get_sphere_contact_for_point_at_pose(collider, point, radius, position, _, movement_world)
	local target_radius = collider:GetSphereRadius()
	local delta = point - position
	local combined_radius = radius + target_radius
	local distance = delta:GetLength()

	if distance > combined_radius then return nil end

	local normal = distance > get_epsilon() and
		(
			delta / distance
		)
		or
		ensure_normal_faces_motion((point - position):GetNormalized(), movement_world)

	if not normal then return nil end

	return {
		normal = normal,
		position = position + normal * target_radius,
		point = point - normal * radius,
	}
end

local function get_capsule_contact_for_point_at_pose(collider, point, radius, position, rotation, movement_world)
	local segment_a, segment_b, capsule_radius = get_capsule_segment_world(collider, position, rotation)
	local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, point, get_epsilon())
	local delta = point - closest
	local distance = delta:GetLength()
	local combined_radius = radius + capsule_radius

	if distance > combined_radius then return nil end

	local normal = distance > get_epsilon() and
		(
			delta / distance
		)
		or
		ensure_normal_faces_motion((point - ((segment_a + segment_b) * 0.5)):GetNormalized(), movement_world)

	if not normal then return nil end

	return {
		normal = normal,
		position = closest + normal * capsule_radius,
		point = point - normal * radius,
	}
end

local function get_polyhedron_contact_for_point_at_pose(collider, polyhedron, point, radius, position, rotation, movement_world)
	local scratch = collider.point_polyhedron_contact_scratch or {}
	collider.point_polyhedron_contact_scratch = scratch
	local vertices = polyhedron_cache.FillPolyhedronWorldVertices(polyhedron, position, rotation, scratch.vertices)
	scratch.vertices = vertices
	local best_distance = -math.huge
	local best_normal = nil

	for _, face in ipairs(polyhedron.faces or {}) do
		local plane_point = vertices[face.indices[1]]
		local normal = rotation:VecMul(face.normal):GetNormalized()
		local distance = normal:Dot(point - plane_point)

		if distance > radius + get_epsilon() then return nil end

		if distance > best_distance then
			best_distance = distance
			best_normal = normal
		end
	end

	if not best_normal then return nil end

	if best_normal:GetLength() <= get_epsilon() then
		best_normal = ensure_normal_faces_motion((point - position):GetNormalized(), movement_world)
	end

	if not best_normal then return nil end

	return {
		normal = best_normal,
		position = get_support_point(vertices, best_normal),
		point = point - best_normal * radius,
	}
end

local function get_point_contact_for_target_at_pose(collider, point, radius, position, rotation, movement_world, polyhedron)
	local shape_type = collider:GetShapeType()

	if shape_type == "box" then
		return get_box_contact_for_point_at_pose(collider, point, radius, position, rotation, movement_world)
	end

	if shape_type == "sphere" then
		return get_sphere_contact_for_point_at_pose(collider, point, radius, position, rotation, movement_world)
	end

	if shape_type == "capsule" then
		return get_capsule_contact_for_point_at_pose(collider, point, radius, position, rotation, movement_world)
	end

	polyhedron = polyhedron or collider:GetBodyPolyhedron()

	if polyhedron and polyhedron.vertices and polyhedron.faces then
		return get_polyhedron_contact_for_point_at_pose(collider, polyhedron, point, radius, position, rotation, movement_world)
	end

	return nil
end

local function find_first_sampled_hit(max_fraction, steps, evaluate_hit)
	local start_hit = evaluate_hit(0)

	if start_hit then return 0, start_hit end

	local low = 0
	local high = nil
	local best = nil
	steps = math.max(1, steps or 1)

	for i = 1, steps do
		local t = max_fraction * (i / steps)
		local hit = evaluate_hit(t)

		if hit then
			high = t
			best = hit

			break
		end

		low = t
	end

	if not best then return nil end

	for _ = 1, 12 do
		local mid = (low + high) * 0.5
		local mid_hit = evaluate_hit(mid)

		if mid_hit then
			best = mid_hit
			high = mid
		else
			low = mid
		end
	end

	return high, best
end

local function sweep_point_against_rotating_target(start_world, movement, radius, max_fraction, steps, evaluate_contact)
	local t, hit = find_first_sampled_hit(max_fraction, math.max(6, steps or 12), evaluate_contact)

	if not hit then return nil end

	hit.t = t
	return hit
end

local function sweep_point_against_target_motion(
	start_world,
	movement,
	radius,
	target_state,
	max_fraction,
	steps,
	evaluate_contact
)
	return sweep_point_against_rotating_target(
		start_world,
		movement,
		radius,
		max_fraction,
		steps,
		function(t)
			local point = start_world + movement * t
			local position, rotation = get_target_pose(target_state, t, max_fraction)
			return evaluate_contact(point, position, rotation, t)
		end
	)
end

local function get_point_sweep_sample_steps(movement_length, radius, max_fraction)
	local travel = math.max(0, movement_length * math.max(max_fraction or 0, 0))
	return math.max(8, math.min(40, math.ceil(travel / math.max(radius, 0.125)) * 2))
end

local function test_rigid_body_sweep(origin, movement, radius, body, ignore_entity, filter_fn, options, best_fraction)
	if should_skip_rigid_body(body, ignore_entity, filter_fn, options) then
		return nil
	end

	if not (body.GetColliders and body:GetColliders()) then return nil end

	local movement_length = movement:GetLength()
	local target_state = build_target_motion_state(body)
	local relative_movement = movement - target_state.movement
	local end_position = origin + relative_movement * best_fraction
	local world_aabb = build_swept_aabb(origin, end_position, radius)
	local body_bounds = get_rigid_body_candidate_aabb(body)

	if body_bounds and not AABB.IsBoxIntersecting(world_aabb, body_bounds) then
		return nil
	end

	local best_hit = nil

	for _, collider in ipairs(body:GetColliders()) do
		local collider_bounds = get_collider_candidate_aabb(collider)

		if not collider_bounds or AABB.IsBoxIntersecting(world_aabb, collider_bounds) then
			local shape_type = collider:GetShapeType()
			local hit = nil

			if shape_type == "box" or shape_type == "capsule" then
				hit = sweep_point_against_target_motion(
					origin,
					movement,
					radius,
					target_state,
					best_fraction,
					get_point_sweep_sample_steps(
						movement_length,
						radius + (
								shape_type == "capsule" and
								(
									(
										collider:GetPhysicsShape() and
										collider:GetPhysicsShape().GetRadius and
										collider:GetPhysicsShape():GetRadius()
									) or
									0
								)
								or
								0
							),
						best_fraction
					),
					function(point, position, rotation)
						return get_point_contact_for_target_at_pose(collider, point, radius, position, rotation, relative_movement)
					end
				)
			elseif shape_type == "sphere" then
				local target_radius = collider:GetSphereRadius()
				local target_position = target_state.previous_position
				local delta = origin - target_position
				local combined_radius = radius + target_radius
				local a = relative_movement:Dot(relative_movement)
				local b = 2 * delta:Dot(relative_movement)
				local c = delta:Dot(delta) - combined_radius * combined_radius

				if a > get_epsilon() and c > get_epsilon() then
					local discriminant = b * b - 4 * a * c

					if discriminant >= 0 then
						local t = (-b - math.sqrt(discriminant)) / (2 * a)

						if t >= 0 and t <= best_fraction then
							local center = origin + relative_movement * t
							local normal = (center - target_position):GetNormalized()
							hit = {
								t = t,
								position = target_position + normal * target_radius,
								point = center - normal * radius,
								normal = normal,
							}
						end
					end
				end
			else
				local polyhedron = collider:GetBodyPolyhedron()

				if polyhedron and polyhedron.vertices and polyhedron.faces then
					hit = sweep_point_against_target_motion(
						origin,
						movement,
						radius,
						target_state,
						best_fraction,
						get_point_sweep_sample_steps(movement_length, radius, best_fraction),
						function(point, position, rotation)
							return get_point_contact_for_target_at_pose(collider, point, radius, position, rotation, relative_movement, polyhedron)
						end
					)
				end
			end

			local world_hit = build_rigid_body_hit(hit, movement, movement_length, body, collider)

			if world_hit and (not best_hit or world_hit.fraction < best_hit.fraction) then
				best_hit = world_hit
				best_fraction = world_hit.fraction
			end
		end
	end

	return best_hit
end

local function collect_polyhedron_axes(poly_a, rotation_a, poly_b, rotation_b, axes)
	ensure_convex_helpers()
	axes = axes or {}

	for i = #axes, 1, -1 do
		axes[i] = nil
	end

	for _, face in ipairs(poly_a.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_a:VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_b:VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b))
			convex_sat.AddUniqueAxis(axes, dir_a:GetCross(dir_b))
		end
	end

	return axes
end

local function has_separating_axis(vertices_a, vertices_b, axes)
	for _, axis in ipairs(axes) do
		if convex_sat.GetProjectedOverlap(vertices_a, vertices_b, axis) <= 0 then
			return true
		end
	end

	return false
end

local function update_face_axis_candidates(best, vertices_a, vertices_b, poly_data, rotation, center_delta, reference_body)
	for face_index, face in ipairs(poly_data.faces or {}) do
		convex_sat.TryUpdateAxis(
			best,
			vertices_a,
			vertices_b,
			rotation:VecMul(face.normal),
			center_delta,
			{
				kind = "face",
				reference_body = reference_body,
				face_index = face_index,
			},
			nil,
			false,
			get_epsilon()
		)
	end

	return best
end

local function update_edge_axis_candidates(
	best,
	vertices_a,
	vertices_b,
	poly_a,
	rotation_a,
	poly_b,
	rotation_b,
	center_delta
)
	for edge_index_a, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for edge_index_b, edge_b in ipairs(poly_b.edges or {}) do
			convex_sat.TryUpdateAxis(
				best,
				vertices_a,
				vertices_b,
				dir_a:GetCross(rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b))),
				center_delta,
				{
					kind = "edge",
					edge_index_a = edge_index_a,
					edge_index_b = edge_index_b,
				},
				nil,
				true,
				get_epsilon()
			)
		end
	end

	return best
end

local function evaluate_polyhedron_pair_contact(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	ensure_convex_helpers()
	scratch = scratch or {}
	local axes = collect_polyhedron_axes(poly_a, rotation_a, poly_b, rotation_b, scratch.axes)
	scratch.axes = axes

	if not axes[1] then return nil end

	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b

	if has_separating_axis(vertices_a, vertices_b, axes) then return nil end

	local best = convex_sat.CreateBestAxisTracker()
	local center_delta = position_b - position_a
	update_face_axis_candidates(best, vertices_a, vertices_b, poly_a, rotation_a, center_delta, "a")
	update_face_axis_candidates(best, vertices_a, vertices_b, poly_b, rotation_b, center_delta, "b")
	update_edge_axis_candidates(
		best,
		vertices_a,
		vertices_b,
		poly_a,
		rotation_a,
		poly_b,
		rotation_b,
		center_delta
	)
	local chosen = convex_sat.ChoosePreferredAxis(best, 1.05, 0.03)

	if not (chosen and chosen.normal and chosen.overlap and chosen.overlap < math.huge) then
		return nil
	end

	return {
		normal = chosen.normal,
		overlap = chosen.overlap,
		contacts = convex_manifold.BuildSupportPairContacts(
			vertices_a,
			vertices_b,
			chosen.normal,
			{
				merge_distance = 0.1,
				max_contacts = 4,
			}
		),
	}
end

local function collect_capsule_segment_samples(collider, position, rotation, out)
	local a, b, radius = get_capsule_segment_world(collider, position, rotation)
	local count = math.max(3, math.min(9, math.ceil((b - a):GetLength() / math.max(radius, 0.25)) + 1))
	out = out or {}

	for i = 0, count - 1 do
		local t = count == 1 and 0 or i / (count - 1)
		out[i + 1] = a + (b - a) * t
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out, radius
end

local function get_capsule_motion_samples(
	collider,
	start_position,
	start_rotation,
	end_position,
	end_rotation,
	previous_cache_key,
	current_cache_key
)
	local previous_samples = collider[previous_cache_key] or {}
	local current_samples = collider[current_cache_key] or {}
	collider[previous_cache_key] = previous_samples
	collider[current_cache_key] = current_samples
	local start_samples, radius = collect_capsule_segment_samples(collider, start_position, start_rotation, previous_samples)
	local end_samples = collect_capsule_segment_samples(collider, end_position, end_rotation, current_samples)
	return start_samples, end_samples, radius
end

local function find_best_capsule_sample_hit(start_samples, end_samples, radius, fallback_delta, select_hit)
	local best = nil

	for i, end_sample in ipairs(end_samples) do
		local start_sample = start_samples[i] or (end_sample - fallback_delta)
		local hit = select_hit(start_sample, end_sample, radius, i)

		if hit and (not best or hit.t < best.t) then best = hit end
	end

	return best
end

local function sweep_polyhedron_against_body_polyhedron(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	target_collider,
	target_polyhedron,
	target_state,
	max_fraction
)
	local scratch = collider.polyhedron_body_sweep_scratch or {}
	collider.polyhedron_body_sweep_scratch = scratch
	local hit_t, hit_result = find_first_sampled_hit(max_fraction, get_polyhedron_sweep_sample_steps(polyhedron, movement:GetLength(), max_fraction), function(t)
		local target_position_t, target_rotation_t = get_target_pose(target_state, t, max_fraction)
		return evaluate_polyhedron_pair_contact(
			polyhedron,
			start_position + movement * t,
			rotation,
			target_polyhedron,
			target_position_t,
			target_rotation_t,
			scratch
		)
	end)

	if not hit_result then return nil end

	local point, position = get_polyhedron_pair_contact_positions(hit_result, scratch)
	return point and
		position and
		{
			t = hit_t,
			point = point,
			position = position,
			normal = hit_result.normal * -1,
		} or
		nil
end

local function sweep_polyhedron_against_sphere_body(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	target_collider,
	target_state,
	max_fraction
)
	local radius = target_collider:GetSphereRadius()
	local center = target_state.previous_position
	local relative_movement = movement - target_state.movement
	local raw_hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
		collider,
		polyhedron,
		center,
		center - relative_movement * max_fraction,
		radius,
		start_position,
		rotation
	)

	if not raw_hit then return nil end

	local normal = raw_hit.normal * -1
	local hit_fraction = raw_hit.t * max_fraction
	local hit_center = center + target_state.movement * hit_fraction
	return {
		t = hit_fraction,
		point = raw_hit.position or (hit_center + normal * radius),
		position = hit_center + normal * radius,
		normal = normal,
	}
end

local function sweep_polyhedron_against_capsule_body(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	target_collider,
	target_state,
	max_fraction
)
	local start_samples, end_samples, radius = get_capsule_motion_samples(
		target_collider,
		target_state.previous_position,
		target_state.previous_rotation,
		target_state.current_position,
		target_state.current_rotation,
		"polyhedron_body_capsule_previous_samples",
		"polyhedron_body_capsule_current_samples"
	)
	return find_best_capsule_sample_hit(
		start_samples,
		end_samples,
		radius,
		target_state.movement * max_fraction,
		function(start_sample, end_sample)
			local raw_hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
				collider,
				polyhedron,
				start_sample,
				end_sample - movement * max_fraction,
				radius,
				start_position,
				rotation
			)

			if not raw_hit then return nil end

			local normal = raw_hit.normal * -1
			local hit_fraction = raw_hit.t * max_fraction
			local center = start_sample + (end_sample - start_sample) * raw_hit.t
			return {
				t = hit_fraction,
				point = raw_hit.position or (center + normal * radius),
				position = center + normal * radius,
				normal = normal,
			}
		end
	)
end

local function sweep_capsule_against_sphere_body(
	collider,
	start_position,
	rotation,
	movement,
	target_collider,
	target_state,
	max_fraction
)
	local sphere_radius = target_collider:GetSphereRadius()
	local segment_a, segment_b, capsule_radius = get_capsule_segment_world(collider, start_position, rotation)
	local center = target_state.previous_position
	local raw_hit = sweep_point_against_capsule_segment(
		center,
		center - (movement - target_state.movement) * max_fraction,
		segment_a,
		segment_b,
		capsule_radius + sphere_radius
	)

	if not raw_hit then return nil end

	local normal = raw_hit.normal * -1
	local hit_fraction = raw_hit.t * max_fraction
	return {
		t = hit_fraction,
		point = raw_hit.point,
		position = center + target_state.movement * hit_fraction + normal * sphere_radius,
		normal = normal,
	}
end

local function sweep_capsule_against_polyhedron_body(
	collider,
	start_position,
	rotation,
	movement,
	target_collider,
	target_polyhedron,
	target_state,
	max_fraction
)
	local start_points, end_points, radius = get_capsule_motion_samples(
		collider,
		start_position,
		rotation,
		start_position + movement * max_fraction,
		rotation,
		"capsule_body_sweep_previous",
		"capsule_body_sweep_current"
	)
	return find_best_capsule_sample_hit(
		start_points,
		end_points,
		radius,
		movement * max_fraction,
		function(start_sample, end_sample)
			local raw_hit = sweep_point_against_rotating_target(
				start_sample,
				end_sample - start_sample,
				radius,
				max_fraction,
				get_point_sweep_sample_steps((end_sample - start_sample):GetLength(), radius, max_fraction),
				function(t)
					local point = start_sample + (end_sample - start_sample) * get_sweep_alpha(t, max_fraction)
					local position, rotation_t = get_target_pose(target_state, t, max_fraction)
					return get_polyhedron_contact_for_point_at_pose(
						target_collider,
						target_polyhedron,
						point,
						radius,
						position,
						rotation_t,
						end_sample - start_sample
					)
				end
			)

			if not raw_hit then return nil end

			return {
				t = raw_hit.t,
				point = raw_hit.point,
				position = raw_hit.position,
				normal = raw_hit.normal,
			}
		end
	)
end

local function sweep_capsule_against_capsule_body(
	collider,
	start_position,
	rotation,
	movement,
	target_collider,
	target_state,
	max_fraction
)
	local start_a, start_b, radius_a = get_capsule_segment_world(collider, start_position, rotation)
	local end_a, end_b = get_capsule_segment_world(collider, start_position + movement * max_fraction, rotation)
	local target_start_a, target_start_b, radius_b = get_capsule_segment_world(target_collider, target_state.previous_position, target_state.previous_rotation)
	local combined_radius = radius_a + radius_b

	local function evaluate(t)
		local query_a = start_a + (end_a - start_a) * t
		local query_b = start_b + (end_b - start_b) * t
		local target_position_t, target_rotation_t = get_target_pose(target_state, t, max_fraction)
		local target_a, target_b = get_capsule_segment_world(target_collider, target_position_t, target_rotation_t)
		local point_a, point_b = segment_geometry.ClosestPointsBetweenSegments(query_a, query_b, target_a, target_b, get_epsilon())
		local delta = point_a - point_b
		return point_a, point_b, delta, delta:GetLength()
	end

	local hit_t, hit_data = find_first_sampled_hit(max_fraction, math.max(
		8,
		math.min(
			32,
			math.ceil((movement:GetLength() * max_fraction) / math.max(combined_radius, 0.2)) * 2
		)
	), function(t)
		local point_a, point_b, delta, distance = evaluate(t)

		if distance <= combined_radius then
			return {point_a = point_a, point_b = point_b, delta = delta, distance = distance}
		end

		return nil
	end)

	if not hit_data then return nil end

	local point_a = hit_data.point_a
	local point_b = hit_data.point_b
	local delta = hit_data.delta
	local distance = hit_data.distance
	local normal = distance > get_epsilon() and
		(
			delta / distance
		)
		or
		ensure_normal_faces_motion(
			(start_position - target_state.previous_position):GetNormalized(),
			movement - target_state.movement
		)
	return {
		t = hit_t,
		point = point_a - normal * radius_a,
		position = point_b + normal * radius_b,
		normal = normal,
	}
end

local function test_rigid_body_collider_sweep(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	body,
	ignore_entity,
	filter_fn,
	options,
	best_fraction
)
	if should_skip_rigid_body(body, ignore_entity, filter_fn, options) then
		return nil
	end

	local movement_length = movement:GetLength()
	local target_state = build_target_motion_state(body)
	local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement * best_fraction)
	local body_bounds = get_rigid_body_candidate_aabb(body)

	if body_bounds and not AABB.IsBoxIntersecting(world_aabb, body_bounds) then
		return nil
	end

	local query_shape_type = collider:GetShapeType()
	local best_hit

	for _, target_collider in ipairs(body:GetColliders() or {}) do
		local target_bounds = get_collider_candidate_aabb(target_collider)

		if not target_bounds or AABB.IsBoxIntersecting(world_aabb, target_bounds) then
			local target_shape_type = target_collider:GetShapeType()
			local hit = nil

			if query_shape_type == "capsule" then
				if target_shape_type == "sphere" then
					hit = sweep_capsule_against_sphere_body(
						collider,
						start_position,
						rotation,
						movement,
						target_collider,
						target_state,
						best_fraction
					)
				elseif target_shape_type == "capsule" then
					hit = sweep_capsule_against_capsule_body(
						collider,
						start_position,
						rotation,
						movement,
						target_collider,
						target_state,
						best_fraction
					)
				else
					local target_polyhedron = target_collider:GetBodyPolyhedron()

					if target_polyhedron and target_polyhedron.vertices and target_polyhedron.faces then
						hit = sweep_capsule_against_polyhedron_body(
							collider,
							start_position,
							rotation,
							movement,
							target_collider,
							target_polyhedron,
							target_state,
							best_fraction
						)
					end
				end
			elseif polyhedron and polyhedron.vertices and polyhedron.faces then
				if target_shape_type == "sphere" then
					hit = sweep_polyhedron_against_sphere_body(
						collider,
						polyhedron,
						start_position,
						rotation,
						movement,
						target_collider,
						target_state,
						best_fraction
					)
				elseif target_shape_type == "capsule" then
					hit = sweep_polyhedron_against_capsule_body(
						collider,
						polyhedron,
						start_position,
						rotation,
						movement,
						target_collider,
						target_state,
						best_fraction
					)
				else
					local target_polyhedron = target_collider:GetBodyPolyhedron()

					if target_polyhedron and target_polyhedron.vertices and target_polyhedron.faces then
						hit = sweep_polyhedron_against_body_polyhedron(
							collider,
							polyhedron,
							start_position,
							rotation,
							movement,
							target_collider,
							target_polyhedron,
							target_state,
							best_fraction
						)
					end
				end
			end

			local world_hit = build_rigid_body_hit(hit, movement, movement_length, body, target_collider)

			if world_hit and (not best_hit or world_hit.fraction < best_hit.fraction) then
				best_hit = world_hit
				best_fraction = world_hit.fraction
			end
		end
	end

	return best_hit
end

local function build_world_hit(
	base_hit,
	movement,
	movement_length,
	model,
	entity,
	primitive,
	primitive_index,
	triangle_index
)
	if not base_hit then return nil end

	return {
		entity = entity,
		model = model,
		primitive = primitive,
		primitive_index = primitive_index,
		triangle_index = triangle_index,
		point = base_hit.point,
		position = base_hit.position,
		normal = ensure_normal_faces_motion(base_hit.normal, movement),
		face_normal = ensure_normal_faces_motion(base_hit.normal, movement),
		fraction = base_hit.t,
		distance = movement_length * base_hit.t,
	}
end

local function collect_polyhedron_triangle_sweep_hit(v0, v1, v2, triangle_index, context)
	local hit = sweep_polyhedron_against_triangle(
		context.collider,
		context.polyhedron,
		context.start_position,
		context.rotation,
		context.movement,
		v0,
		v1,
		v2,
		context.max_fraction
	)

	if not hit then return end

	local world_hit = build_world_hit(
		hit,
		context.movement,
		context.movement_length,
		context.model,
		context.entity,
		context.primitive,
		context.primitive_index,
		triangle_index
	)

	if
		world_hit and
		(
			not context.best_hit or
			world_hit.fraction < context.best_hit.fraction
		)
	then
		context.best_hit = world_hit
		context.max_fraction = world_hit.fraction
	end
end

local function test_polyhedron_primitive_sweep(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	primitive,
	primitive_index,
	model,
	entity,
	local_to_world,
	local_aabb,
	max_fraction
)
	if primitive.aabb and not BVH.AABBIntersects(local_aabb, primitive.aabb) then
		return nil
	end

	local movement_length = movement:GetLength()
	local poly = world_mesh_body.GetPrimitivePolygon(primitive)

	if not poly then return nil end

	local triangle_context = primitive.polyhedron_sweep_triangle_context or {}
	primitive.polyhedron_sweep_triangle_context = triangle_context
	triangle_context.best_hit = nil
	triangle_context.collider = collider
	triangle_context.entity = entity
	triangle_context.max_fraction = max_fraction
	triangle_context.model = model
	triangle_context.movement = movement
	triangle_context.movement_length = movement_length
	triangle_context.polyhedron = polyhedron
	triangle_context.primitive = primitive
	triangle_context.primitive_index = primitive_index
	triangle_context.rotation = rotation
	triangle_context.start_position = start_position
	for_each_overlapping_world_triangle(
		poly,
		local_aabb,
		local_to_world,
		collect_polyhedron_triangle_sweep_hit,
		triangle_context
	)
	return triangle_context.best_hit
end

local function collect_capsule_triangle_sweep_hit(v0, v1, v2, triangle_index, context)
	local hit = sweep_capsule_against_triangle(
		context.collider,
		context.start_position,
		context.rotation,
		context.movement,
		v0,
		v1,
		v2,
		context.max_fraction
	)

	if not hit then return end

	local world_hit = build_world_hit(
		hit,
		context.movement,
		context.movement_length,
		context.model,
		context.entity,
		context.primitive,
		context.primitive_index,
		triangle_index
	)

	if
		world_hit and
		(
			not context.best_hit or
			world_hit.fraction < context.best_hit.fraction
		)
	then
		context.best_hit = world_hit
		context.max_fraction = world_hit.fraction
	end
end

local function test_capsule_primitive_sweep(
	collider,
	start_position,
	rotation,
	movement,
	primitive,
	primitive_index,
	model,
	entity,
	local_to_world,
	local_aabb,
	max_fraction
)
	if primitive.aabb and not BVH.AABBIntersects(local_aabb, primitive.aabb) then
		return nil
	end

	local movement_length = movement:GetLength()
	local poly = world_mesh_body.GetPrimitivePolygon(primitive)

	if not poly then return nil end

	local triangle_context = primitive.capsule_sweep_triangle_context or {}
	primitive.capsule_sweep_triangle_context = triangle_context
	triangle_context.best_hit = nil
	triangle_context.collider = collider
	triangle_context.entity = entity
	triangle_context.max_fraction = max_fraction
	triangle_context.model = model
	triangle_context.movement = movement
	triangle_context.movement_length = movement_length
	triangle_context.primitive = primitive
	triangle_context.primitive_index = primitive_index
	triangle_context.rotation = rotation
	triangle_context.start_position = start_position
	for_each_overlapping_world_triangle(
		poly,
		local_aabb,
		local_to_world,
		collect_capsule_triangle_sweep_hit,
		triangle_context
	)
	return triangle_context.best_hit
end

local function collect_triangle_sweep_hit(v0, v1, v2, triangle_index, context)
	local local_hit = sweep_sphere_against_triangle(
		context.start_local,
		context.movement_local,
		context.radius,
		v0,
		v1,
		v2,
		context.max_fraction
	)

	if not local_hit then return end

	local world_position = context.local_to_world and
		context.local_to_world:TransformVector(local_hit.position) or
		local_hit.position
	local world_normal = context.local_to_world and
		transform_direction(context.local_to_world, local_hit.normal) or
		local_hit.normal
	local hit = build_world_hit(
		{
			position = world_position,
			normal = world_normal,
			t = local_hit.t,
		},
		context.world_movement,
		context.movement_length,
		context.model,
		context.entity,
		context.primitive,
		context.primitive_index,
		triangle_index
	)

	if hit and (not context.best_hit or hit.fraction < context.best_hit.fraction) then
		context.best_hit = hit
		context.max_fraction = hit.fraction
	end
end

local function test_primitive_sweep(
	start_local,
	movement_local,
	radius,
	primitive,
	primitive_index,
	model,
	entity,
	local_to_world,
	local_aabb,
	max_fraction
)
	local best_hit
	local movement_length = movement_local:GetLength()
	local world_movement = local_to_world and
		(
			local_to_world:TransformVector(start_local + movement_local) - local_to_world:TransformVector(start_local)
		)
		or
		movement_local

	if primitive.aabb and not BVH.AABBIntersects(local_aabb, primitive.aabb) then
		return nil
	end
	local poly = world_mesh_body.GetPrimitivePolygon(primitive)

	if not poly then return nil end

	local triangle_context = primitive.sweep_triangle_context or {}
	primitive.sweep_triangle_context = triangle_context
	triangle_context.best_hit = best_hit
	triangle_context.entity = entity
	triangle_context.local_to_world = local_to_world
	triangle_context.max_fraction = max_fraction
	triangle_context.model = model
	triangle_context.movement_length = movement_length
	triangle_context.movement_local = movement_local
	triangle_context.primitive = primitive
	triangle_context.primitive_index = primitive_index
	triangle_context.radius = radius
	triangle_context.start_local = start_local
	triangle_context.world_movement = world_movement
	for_each_overlapping_world_triangle(poly, local_aabb, nil, collect_triangle_sweep_hit, triangle_context)
	return triangle_context.best_hit
end

local function test_model_sweep(
	start_position,
	movement,
	radius,
	model,
	ignore_entity,
	filter_fn,
	options,
	best_fraction
)
	if should_skip_model(model, ignore_entity, filter_fn, options) then
		return nil
	end

	local model_aabb = model.GetWorldAABB and model:GetWorldAABB() or model.AABB
	local end_position = start_position + movement * best_fraction
	local world_aabb = build_swept_aabb(start_position, end_position, radius)

	if model_aabb and not AABB.IsBoxIntersecting(world_aabb, model_aabb) then
		return nil
	end

	local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(model)
	local start_local = world_to_local and
		world_to_local:TransformVector(start_position) or
		start_position
	local end_local = world_to_local and world_to_local:TransformVector(end_position) or end_position
	local movement_local = end_local - start_local
	local local_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, world_to_local)
	local primitive_candidates = model.sweep_primitive_candidates or {}
	model.sweep_primitive_candidates = primitive_candidates
	local best_hit

	for i = #primitive_candidates, 1, -1 do
		primitive_candidates[i] = nil
	end

	raycast.CollectModelPrimitiveCandidatesByLocalAABB(model, local_aabb, primitive_candidates)

	for i = 1, #primitive_candidates do
		local candidate = primitive_candidates[i]
		local primitive = candidate and candidate.primitive or nil
		local primitive_index = candidate and candidate.primitive_idx or nil

		if primitive and primitive_index then
			local hit = test_primitive_sweep(
				start_local,
				movement_local,
				radius,
				primitive,
				primitive_index,
				model,
				model.Owner,
				local_to_world,
				local_aabb,
				best_hit and best_hit.fraction or 1
			)

			if hit and (not best_hit or hit.fraction < best_hit.fraction) then
				best_hit = hit
			end
		end
	end

	return best_hit
end

function physics.SweepFromSource(source, origin, movement, radius, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	radius = math.max(radius or 0, 0)
	movement = movement or Vec3(0, 0, 0)
	local movement_length = movement:GetLength()

	if movement_length <= get_epsilon() then return nil end

	local world_aabb = build_swept_aabb(origin, origin + movement, radius)
	local model_candidates = {}
	local body_candidates = {}
	local best_hit = nil
	local best_fraction = 1

	if options.IgnoreWorld ~= true then
		world_static_query.CollectWorldModelCandidates(source, world_aabb, model_candidates)
	end

	collect_rigid_body_candidates(world_aabb, ignore_entity, filter_fn, options, body_candidates)

	for i = 1, #model_candidates do
		local item = model_candidates[i]
		local model = item and item.model or nil

		if model then
			local hit = test_model_sweep(origin, movement, radius, model, ignore_entity, filter_fn, options, best_fraction)

			if hit and hit.fraction < best_fraction then
				best_hit = hit
				best_fraction = hit.fraction
			end
		end
	end

	for i = 1, #body_candidates do
		local body = body_candidates[i]
		local hit = test_rigid_body_sweep(origin, movement, radius, body, ignore_entity, filter_fn, options, best_fraction)

		if hit and hit.fraction < best_fraction then
			best_hit = hit
			best_fraction = hit.fraction
		end
	end

	return best_hit
end

function physics.SweepColliderFromSource(source, collider, start_position, movement, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local polyhedron = collider:GetBodyPolyhedron()
	local rotation = options.Rotation or collider:GetRotation()
	local shape = collider:GetPhysicsShape()
	local shape_type = collider:GetShapeType()

	if
		shape_type == "capsule" and
		shape and
		shape.GetBottomSphereCenterLocal and
		shape.GetTopSphereCenterLocal and
		shape.GetRadius
	then
		local movement_length = movement:GetLength()

		if movement_length <= get_epsilon() then return nil end

		local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement)
		local model_candidates = {}
		local body_candidates = {}
		local best_hit = nil
		local best_fraction = 1

		if options.IgnoreWorld ~= true then
			world_static_query.CollectWorldModelCandidates(source, world_aabb, model_candidates)
		end

		collect_rigid_body_candidates(world_aabb, ignore_entity, filter_fn, options, body_candidates)

		for i = 1, #model_candidates do
			local model = model_candidates[i] and model_candidates[i].model or nil

			if model and not should_skip_model(model, ignore_entity, filter_fn, options) then
				local model_aabb = model.GetWorldAABB and model:GetWorldAABB() or model.AABB

				if not model_aabb or AABB.IsBoxIntersecting(world_aabb, model_aabb) then
					local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(model)
					local local_body_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, world_to_local)
					local primitive_candidates = collider.polyhedron_sweep_primitive_candidates or {}
					collider.polyhedron_sweep_primitive_candidates = primitive_candidates

					for j = #primitive_candidates, 1, -1 do
						primitive_candidates[j] = nil
					end

					raycast.CollectModelPrimitiveCandidatesByLocalAABB(model, local_body_aabb, primitive_candidates)

					for j = 1, #primitive_candidates do
						local candidate = primitive_candidates[j]
						local primitive = candidate and candidate.primitive or nil
						local primitive_index = candidate and candidate.primitive_idx or nil

						if primitive and primitive_index then
							local hit = test_capsule_primitive_sweep(
								collider,
								start_position,
								rotation,
								movement,
								primitive,
								primitive_index,
								model,
								model.Owner,
								local_to_world,
								local_body_aabb,
								best_fraction
							)

							if hit and hit.fraction < best_fraction then
								best_hit = hit
								best_fraction = hit.fraction
							end
						end
					end
				end
			end
		end

		for i = 1, #body_candidates do
			local body_hit = test_rigid_body_collider_sweep(
				collider,
				nil,
				start_position,
				rotation,
				movement,
				body_candidates[i],
				ignore_entity,
				filter_fn,
				options,
				best_fraction
			)

			if body_hit and body_hit.fraction < best_fraction then
				best_hit = body_hit
				best_fraction = body_hit.fraction
			end
		end

		return best_hit
	end

	if not (polyhedron and polyhedron.vertices and polyhedron.vertices[1]) then
		local radius = shape and shape.GetRadius and shape:GetRadius() or 0
		return physics.SweepFromSource(source, start_position, movement, radius, ignore_entity, filter_fn, options)
	end

	local movement_length = movement:GetLength()

	if movement_length <= get_epsilon() then return nil end

	local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement)
	local model_candidates = {}
	local body_candidates = {}
	local best_hit = nil
	local best_fraction = 1

	if options.IgnoreWorld ~= true then
		world_static_query.CollectWorldModelCandidates(source, world_aabb, model_candidates)
	end

	collect_rigid_body_candidates(world_aabb, ignore_entity, filter_fn, options, body_candidates)

	for i = 1, #model_candidates do
		local model = model_candidates[i] and model_candidates[i].model or nil

		if model and not should_skip_model(model, ignore_entity, filter_fn, options) then
			local model_aabb = model.GetWorldAABB and model:GetWorldAABB() or model.AABB

			if not model_aabb or AABB.IsBoxIntersecting(world_aabb, model_aabb) then
				local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(model)
				local local_body_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, world_to_local)
				local primitive_candidates = collider.capsule_sweep_primitive_candidates or {}
				collider.capsule_sweep_primitive_candidates = primitive_candidates

				for j = #primitive_candidates, 1, -1 do
					primitive_candidates[j] = nil
				end

				raycast.CollectModelPrimitiveCandidatesByLocalAABB(model, local_body_aabb, primitive_candidates)

				for j = 1, #primitive_candidates do
					local candidate = primitive_candidates[j]
					local primitive = candidate and candidate.primitive or nil
					local primitive_index = candidate and candidate.primitive_idx or nil

					if primitive and primitive_index then
						local hit = test_polyhedron_primitive_sweep(
							collider,
							polyhedron,
							start_position,
							rotation,
							movement,
							primitive,
							primitive_index,
							model,
							model.Owner,
							local_to_world,
							local_body_aabb,
							best_fraction
						)

						if hit and hit.fraction < best_fraction then
							best_hit = hit
							best_fraction = hit.fraction
						end
					end
				end
			end
		end
	end

	for i = 1, #body_candidates do
		local body_hit = test_rigid_body_collider_sweep(
			collider,
			polyhedron,
			start_position,
			rotation,
			movement,
			body_candidates[i],
			ignore_entity,
			filter_fn,
			options,
			best_fraction
		)

		if body_hit and body_hit.fraction < best_fraction then
			best_hit = body_hit
			best_fraction = body_hit.fraction
		end
	end

	return best_hit
end

function physics.SweepCollider(collider, start_position, movement, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local source = options.WorldSource
	local use_render_meshes = options.UseRenderMeshes
	source, use_render_meshes = world_static_query.ResolveWorldSource(source, use_render_meshes, options.IgnoreRigidBodies ~= false)
	if source == nil then return nil end

	return physics.SweepColliderFromSource(source, collider, start_position, movement, ignore_entity, filter_fn, options)
end

function physics.Sweep(origin, movement, radius, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local source = options.WorldSource
	local use_render_meshes = options.UseRenderMeshes
	source, use_render_meshes = world_static_query.ResolveWorldSource(source, use_render_meshes, options.IgnoreRigidBodies ~= false)
	if source == nil then return nil end

	return physics.SweepFromSource(source, origin, movement, radius, ignore_entity, filter_fn, options)
end

physics.SphereCast = physics.Sweep
physics.ShapeCast = physics.SweepCollider
