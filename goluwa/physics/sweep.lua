local physics_constants = import("goluwa/physics/constants.lua")
local stats = import("goluwa/physics/stats.lua")
local collider_index = import("goluwa/physics/collider_index.lua")
local SWEEP_COLLIDER_TARGETS = {}
local SWEEP_POINT_TARGETS = {}
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local sweep_candidates = import("goluwa/physics/sweep_candidates.lua")
local sweep_mesh = import("goluwa/physics/sweep_mesh.lua")
local primitive_polygon_query = import("goluwa/physics/primitive_polygon_query.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sweep = {}
local EPSILON = physics_constants.EPSILON
local ensure_normal_faces_motion = sweep_helpers.EnsureNormalFacesMotion
local MESH_BODY_POINT_SWEEP_CONTEXT = sweep_mesh.MeshBodyPointSweepContext
local MESH_BODY_COLLIDER_SWEEP_CONTEXT = sweep_mesh.MeshBodyColliderSweepContext
local POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT = sweep_mesh.PointCapsuleSegmentEvaluationContext
local evaluate_point_against_capsule_segment = sweep_mesh.EvaluatePointAgainstCapsuleSegment
local collect_mesh_body_point_sweep_hit = sweep_mesh.CollectMeshBodyPointSweepHit
local collect_mesh_body_collider_sweep_hit = sweep_mesh.CollectMeshBodyColliderSweepHit
local build_capsule_sweep_invariants = sweep_mesh.BuildCapsuleSweepInvariants
local get_polyhedron_contact_for_point_at_pose
local evaluate_polyhedron_pair_contact
local should_skip_rigid_body = sweep_candidates.ShouldSkipRigidBody
local get_rigid_body_candidate_aabb = sweep_candidates.GetRigidBodyCandidateAABB
local get_collider_candidate_aabb = sweep_candidates.GetColliderCandidateAABB

local function collect_rigid_body_candidates(...)
	stats:PushTime("sweep_candidates")
	sweep_candidates.CollectRigidBodyCandidates(...)
	stats:PopTime()
end

local empty_options = {}

local function normalize_query_options(options)
	if options == nil then return empty_options end

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

local build_swept_aabb = AABB.FromSegment
local ZERO_MOVEMENT = Vec3(0, 0, 0)
local swept_aabb_scratch = AABB(0, 0, 0, 0, 0, 0)
local body_candidates_scratch = {}

local function fill_swept_aabb(origin, movement, radius)
	local aabb = swept_aabb_scratch
	local end_x = origin.x + movement.x
	local end_y = origin.y + movement.y
	local end_z = origin.z + movement.z
	aabb.min_x = math.min(origin.x, end_x) - radius
	aabb.min_y = math.min(origin.y, end_y) - radius
	aabb.min_z = math.min(origin.z, end_z) - radius
	aabb.max_x = math.max(origin.x, end_x) + radius
	aabb.max_y = math.max(origin.y, end_y) + radius
	aabb.max_z = math.max(origin.z, end_z) + radius
	return aabb
end

local SWEEP_AABB_START = AABB(0, 0, 0, 0, 0, 0)
local SWEEP_AABB_END = AABB(0, 0, 0, 0, 0, 0)
local SWEEP_AABB_RESULT_A = AABB(0, 0, 0, 0, 0, 0)
local SWEEP_AABB_RESULT_B = AABB(0, 0, 0, 0, 0, 0)
local SWEEP_LOCAL_AABB = AABB(0, 0, 0, 0, 0, 0)
local sweep_aabb_toggle = false
local get_support_point = sweep_helpers.GetSupportPoint

local function build_collider_swept_aabb(collider, start_position, rotation, movement)
	local shape = collider:GetPhysicsShape()
	local end_position = start_position + movement
	local result = sweep_aabb_toggle and SWEEP_AABB_RESULT_B or SWEEP_AABB_RESULT_A
	sweep_aabb_toggle = not sweep_aabb_toggle
	local start_aabb = shape:GetBroadphaseAABB(collider, start_position, rotation, SWEEP_AABB_START)
	local end_aabb = shape:GetBroadphaseAABB(collider, end_position, rotation, SWEEP_AABB_END)
	return AABB.Union(result, start_aabb, end_aabb)
end

local function build_rigid_body_hit(base_hit, movement, movement_length, body, collider)
	if not base_hit then return nil end

	return {
		entity = body and body.Owner or nil,
		rigid_body = body,
		collider = collider,
		model = base_hit.model,
		primitive = base_hit.primitive,
		primitive_index = base_hit.primitive_index,
		triangle_index = base_hit.triangle_index,
		position = base_hit.position,
		point = base_hit.point,
		normal = ensure_normal_faces_motion(base_hit.normal, movement),
		face_normal = ensure_normal_faces_motion(base_hit.face_normal or base_hit.normal, movement),
		fraction = base_hit.t,
		distance = movement_length * base_hit.t,
	}
end

local function get_mesh_collider_shape(collider)
	local shape = collider and collider:GetPhysicsShape() or nil

	if not (shape and shape:GetTypeName() == "mesh") then return nil end

	return shape
end

local function test_mesh_body_point_sweep(origin, movement, radius, body, collider, max_fraction)
	if not (body and (body:IsStatic() or body:IsKinematic())) then return nil end

	local best_hit = nil
	local target_position = collider:GetPosition()
	local target_rotation = collider:GetRotation()
	local shape = get_mesh_collider_shape(collider)

	if not shape then return nil end

	local world_aabb = build_swept_aabb(origin, origin + movement * max_fraction, radius)
	local local_aabb = shape:BuildSweptLocalAABB(collider, target_position, target_rotation, world_aabb, SWEEP_LOCAL_AABB)
	MESH_BODY_POINT_SWEEP_CONTEXT.origin = origin
	MESH_BODY_POINT_SWEEP_CONTEXT.movement = movement
	MESH_BODY_POINT_SWEEP_CONTEXT.radius = radius
	MESH_BODY_POINT_SWEEP_CONTEXT.max_fraction = max_fraction
	MESH_BODY_POINT_SWEEP_CONTEXT.collider = collider
	MESH_BODY_POINT_SWEEP_CONTEXT.target_collider = collider
	MESH_BODY_POINT_SWEEP_CONTEXT.target_position = target_position
	MESH_BODY_POINT_SWEEP_CONTEXT.target_rotation = target_rotation
	MESH_BODY_POINT_SWEEP_CONTEXT.wv_cache = {}
	MESH_BODY_POINT_SWEEP_CONTEXT.best_hit = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.entry = nil

	if not local_aabb then
		MESH_BODY_POINT_SWEEP_CONTEXT.origin = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.movement = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.radius = 0
		MESH_BODY_POINT_SWEEP_CONTEXT.max_fraction = 0
		MESH_BODY_POINT_SWEEP_CONTEXT.collider = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.target_collider = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.target_position = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.target_rotation = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.wv_cache = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.entry = nil
		MESH_BODY_POINT_SWEEP_CONTEXT.best_hit = nil
		return nil
	end

	shape:ForEachOverlappingTriangle(
		collider,
		local_aabb,
		collect_mesh_body_point_sweep_hit,
		MESH_BODY_POINT_SWEEP_CONTEXT
	)
	best_hit = MESH_BODY_POINT_SWEEP_CONTEXT.best_hit
	MESH_BODY_POINT_SWEEP_CONTEXT.origin = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.movement = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.radius = 0
	MESH_BODY_POINT_SWEEP_CONTEXT.max_fraction = 0
	MESH_BODY_POINT_SWEEP_CONTEXT.collider = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.target_collider = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.target_position = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.target_rotation = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.wv_cache = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.entry = nil
	MESH_BODY_POINT_SWEEP_CONTEXT.best_hit = nil
	return best_hit
end

local function test_mesh_body_collider_sweep(
	collider,
	polyhedron,
	start_position,
	rotation,
	movement,
	body,
	target_collider,
	max_fraction
)
	if not (body and (body:IsStatic() or body:IsKinematic())) then return nil end

	local best_hit = nil
	local target_position = target_collider:GetPosition()
	local target_rotation = target_collider:GetRotation()
	local query_shape_type = collider:GetShapeType()
	local shape = get_mesh_collider_shape(target_collider)

	if not shape then return nil end

	local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement * max_fraction)
	local local_aabb = shape:BuildSweptLocalAABB(target_collider, target_position, target_rotation, world_aabb, SWEEP_LOCAL_AABB)
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.collider = collider
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.polyhedron = polyhedron
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.start_position = start_position
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.rotation = rotation
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.movement = movement
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.max_fraction = max_fraction
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.query_shape_type = query_shape_type
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_collider = target_collider
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_position = target_position
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_rotation = target_rotation
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.wv_cache = {}
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.best_hit = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.entry = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.capsule_invariants = query_shape_type == "capsule" and
		build_capsule_sweep_invariants(
			collider,
			start_position,
			rotation,
			movement,
			MESH_BODY_COLLIDER_SWEEP_CONTEXT.capsule_invariants
		) or
		nil

	if not local_aabb then
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.collider = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.polyhedron = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.start_position = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.rotation = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.movement = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.max_fraction = 0
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.query_shape_type = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_collider = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_position = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_rotation = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.wv_cache = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.entry = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.best_hit = nil
		MESH_BODY_COLLIDER_SWEEP_CONTEXT.capsule_invariants = nil
		return nil
	end

	shape:ForEachOverlappingTriangle(
		target_collider,
		local_aabb,
		collect_mesh_body_collider_sweep_hit,
		MESH_BODY_COLLIDER_SWEEP_CONTEXT
	)
	best_hit = MESH_BODY_COLLIDER_SWEEP_CONTEXT.best_hit
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.collider = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.polyhedron = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.start_position = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.rotation = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.movement = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.max_fraction = 0
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.query_shape_type = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_collider = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_position = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.target_rotation = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.wv_cache = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.entry = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.best_hit = nil
	MESH_BODY_COLLIDER_SWEEP_CONTEXT.capsule_invariants = nil
	return best_hit
end

local function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius)
	local movement = end_world - start_world
	local movement_length = movement:GetLength()

	if movement_length <= EPSILON then return nil end

	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.start_world = start_world
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.movement = movement
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_a = segment_a
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_b = segment_b
	local _, _, _, start_distance = evaluate_point_against_capsule_segment(POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT, 0)

	if start_distance <= radius then
		POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.start_world = nil
		POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.movement = nil
		POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_a = nil
		POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_b = nil
		return nil
	end

	local sample_steps = math.max(12, math.min(64, math.ceil(movement_length / math.max(radius, 0.125)) * 2))
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, _, _, distance = evaluate_point_against_capsule_segment(POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT, t)

		if distance <= radius then
			local low = previous_t
			local high = t

			for _ = 1, 14 do
				local mid = (low + high) * 0.5
				local _, _, _, mid_distance = evaluate_point_against_capsule_segment(POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT, mid)

				if mid_distance <= radius then high = mid else low = mid end
			end

			local point, closest, delta, final_distance = evaluate_point_against_capsule_segment(POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT, high)
			local normal = final_distance > EPSILON and
				(
					delta / final_distance
				)
				or
				ensure_normal_faces_motion((point - ((segment_a + segment_b) * 0.5)):GetNormalized(), movement)

			if not normal or normal:GetLength() <= EPSILON then
				POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.start_world = nil
				POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.movement = nil
				POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_a = nil
				POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_b = nil
				return nil
			end

			POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.start_world = nil
			POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.movement = nil
			POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_a = nil
			POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_b = nil
			return {
				t = high,
				point = point - normal * radius,
				position = closest,
				normal = normal,
			}
		end

		previous_t = t
	end

	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.start_world = nil
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.movement = nil
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_a = nil
	POINT_CAPSULE_SEGMENT_EVALUATION_CONTEXT.segment_b = nil
	return nil
end

local function sweep_point_against_box_body(box_collider, start_world, end_world, extra_radius, position, rotation)
	local movement_world = end_world - start_world

	if movement_world:GetLength() <= EPSILON then return nil end

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

		if math.abs(d) <= EPSILON then
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

	if distance > EPSILON then
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
				if math.abs(candidate.movement) > EPSILON then
					sign = math.sign(-candidate.movement)
				else
					sign = 1
				end
			end

			candidate.axis = candidate.axis * sign
			candidate.motion_weight = math.abs(candidate.movement)

			if
				not best or
				candidate.overlap < best.overlap - EPSILON or
				(
					math.abs(candidate.overlap - best.overlap) <= EPSILON and
					candidate.motion_weight > best.motion_weight + EPSILON
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

	local normal = distance > EPSILON and
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
	local segment_a, segment_b, capsule_radius = capsule_geometry.GetSegmentWorld(collider, position, rotation)
	local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	local combined_radius = radius + capsule_radius

	if distance > combined_radius then return nil end

	local normal = distance > EPSILON and
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

function get_polyhedron_contact_for_point_at_pose(collider, polyhedron, point, radius, position, rotation, movement_world)
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

		if distance > radius + EPSILON then return nil end

		if distance > best_distance then
			best_distance = distance
			best_normal = normal
		end
	end

	if not best_normal then return nil end

	if best_normal:GetLength() <= EPSILON then
		best_normal = ensure_normal_faces_motion((point - position):GetNormalized(), movement_world)
	end

	if not best_normal then return nil end

	return {
		normal = best_normal,
		position = get_support_point(vertices, best_normal),
		point = point - best_normal * radius,
	}
end

local function test_rigid_body_sweep_untimed(origin, movement, radius, body, ignore_entity, filter_fn, options, best_fraction)
	if should_skip_rigid_body(body, ignore_entity, filter_fn, options) then
		return nil
	end

	if not body:GetColliders() then return nil end

	local movement_length = movement:GetLength()
	local target_state = sweep_helpers.BuildTargetMotionState(body)
	local relative_movement = movement - target_state.movement
	local end_position = origin + relative_movement * best_fraction
	local world_aabb = build_swept_aabb(origin, end_position, radius)
	local body_bounds = get_rigid_body_candidate_aabb(body)

	if body_bounds and not AABB.IsBoxIntersecting(world_aabb, body_bounds) then
		return nil
	end

	local best_hit = nil
	local colliders, collider_count = collider_index.Query(body, world_aabb, SWEEP_POINT_TARGETS)

	for collider_index_in_list = 1, collider_count do
		local collider = colliders[collider_index_in_list]
		local collider_bounds = get_collider_candidate_aabb(collider)

		if not collider_bounds or AABB.IsBoxIntersecting(world_aabb, collider_bounds) then
			local shape = collider:GetPhysicsShape()
			local shape_type = collider:GetShapeType()
			local hit = nil

			if shape and shape.SweepPointAgainstBody then
				hit = shape:SweepPointAgainstBody(collider, origin, movement, radius, target_state, best_fraction)
			end

			if not hit and shape_type == "mesh" then
				hit = test_mesh_body_point_sweep(origin, movement, radius, body, collider, best_fraction)
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

function evaluate_polyhedron_pair_contact(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b
	local penetration = gjk_epa.Penetration(
		vertices_a,
		vertices_b,
		{
			initial_direction = scratch.last_normal or (position_b - position_a),
			simplex = scratch.simplex,
		}
	)
	scratch.simplex = penetration and penetration.gjk and penetration.gjk.simplex or scratch.simplex

	if
		not (
			penetration and
			penetration.intersect and
			penetration.normal and
			penetration.depth and
			penetration.depth > 0
		)
	then
		return nil
	end

	scratch.last_normal = penetration.normal
	return {
		normal = penetration.normal,
		overlap = penetration.depth,
		contacts = convex_manifold.BuildAndMergeSupportPairContacts(
			nil,
			vertices_a,
			vertices_b,
			penetration.normal,
			{
				merge_distance = 0.1,
				max_contacts = 4,
			}
		),
	}
end

local function test_rigid_body_collider_sweep_untimed(
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
	local target_state = sweep_helpers.BuildTargetMotionState(body)
	local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement * best_fraction)
	local body_bounds = get_rigid_body_candidate_aabb(body)

	if body_bounds and not AABB.IsBoxIntersecting(world_aabb, body_bounds) then
		return nil
	end

	local query_shape_type = collider:GetShapeType()
	local best_hit
	local target_colliders, target_count = collider_index.Query(body, world_aabb, SWEEP_COLLIDER_TARGETS)

	for target_index = 1, target_count do
		local target_collider = target_colliders[target_index]
		local target_bounds = get_collider_candidate_aabb(target_collider)

		if not target_bounds or AABB.IsBoxIntersecting(world_aabb, target_bounds) then
			local target_shape = target_collider:GetPhysicsShape()
			local hit = nil

			if target_shape and target_shape.SweepColliderAgainstBody then
				hit = target_shape:SweepColliderAgainstBody(
					target_collider,
					collider,
					polyhedron,
					start_position,
					rotation,
					movement,
					target_state,
					best_fraction
				)
			end

			if not hit and target_collider:GetShapeType() == "mesh" then
				hit = test_mesh_body_collider_sweep(
					collider,
					polyhedron,
					start_position,
					rotation,
					movement,
					body,
					target_collider,
					best_fraction
				)
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

local function test_rigid_body_sweep(...)
	stats:PushTime("sweep_bodies")
	local hit = test_rigid_body_sweep_untimed(...)
	stats:PopTime()
	return hit
end

local function test_rigid_body_collider_sweep(...)
	stats:PushTime("sweep_bodies")
	local hit = test_rigid_body_collider_sweep_untimed(...)
	stats:PopTime()
	return hit
end

local function sweep_world(physics, origin, movement, radius, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	radius = math.max(radius or 0, 0)

	if not movement then movement = ZERO_MOVEMENT end

	local movement_length = movement:GetLength()

	if movement_length <= EPSILON then return nil end

	local world_aabb = fill_swept_aabb(origin, movement, radius)
	local body_candidates = body_candidates_scratch
	table.clear(body_candidates)
	local best_hit = nil
	local best_fraction = 1
	collect_rigid_body_candidates(physics, world_aabb, ignore_entity, filter_fn, options, body_candidates)

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

local function sweep_collider_world(physics, collider, start_position, movement, ignore_entity, filter_fn, options)
	options = normalize_query_options(options)
	local polyhedron = collider:GetBodyPolyhedron()
	local rotation = options.Rotation or collider:GetRotation()
	local shape = collider:GetPhysicsShape()
	local shape_type = collider:GetShapeType()

	if shape_type == "capsule" then
		local movement_length = movement:GetLength()

		if movement_length <= EPSILON then return nil end

		local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement)
		local body_candidates = body_candidates_scratch
		table.clear(body_candidates)
		local best_hit = nil
		local best_fraction = 1
		collect_rigid_body_candidates(physics, world_aabb, ignore_entity, filter_fn, options, body_candidates)

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
		return sweep_world(physics, start_position, movement, radius, ignore_entity, filter_fn, options)
	end

	local movement_length = movement:GetLength()

	if movement_length <= EPSILON then return nil end

	local world_aabb = build_collider_swept_aabb(collider, start_position, rotation, movement)
	local body_candidates = body_candidates_scratch
	table.clear(body_candidates)
	local best_hit = nil
	local best_fraction = 1
	collect_rigid_body_candidates(physics, world_aabb, ignore_entity, filter_fn, options, body_candidates)

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

function sweep.SweepCollider(physics, collider, start_position, movement, ignore_entity, filter_fn, options)
	stats:PushTime("sweep")
	stats:Count("sweeps")
	local hit = sweep_collider_world(physics, collider, start_position, movement, ignore_entity, filter_fn, options)
	stats:PopTime()
	return hit
end

function sweep.Sweep(physics, origin, movement, radius, ignore_entity, filter_fn, options)
	stats:PushTime("sweep")
	stats:Count("sweeps")
	local hit = sweep_world(physics, origin, movement, radius, ignore_entity, filter_fn, options)
	stats:PopTime()
	return hit
end

return sweep
