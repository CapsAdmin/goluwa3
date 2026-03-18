local physics = import("goluwa/physics.lua")
local polyhedron_triangle_contacts = import("goluwa/physics/polyhedron_triangle_contacts.lua")
local raycast = import("goluwa/physics/raycast.lua")
local world_contact_triangles = import("goluwa/physics/world_contact/triangles.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local world_contact_sampling = {}

local function append_unique_sample(
	samples,
	lookup,
	key_fn,
	body_local_point,
	world_point,
	previous_world_point,
	preferred_direction
)
	local key = key_fn(body_local_point)

	if not key or lookup[key] then return end

	lookup[key] = true
	samples[#samples + 1] = {
		local_point = body_local_point,
		point = world_point,
		previous_point = previous_world_point,
		preferred_direction = preferred_direction,
	}
end

local function add_collider_sample(samples, lookup, key_fn, body, collider, local_sample)
	local world_point = collider:GeometryLocalToWorld(local_sample)
	local previous_world_point = collider:GeometryLocalToWorld(local_sample, collider:GetPreviousPosition(), collider:GetPreviousRotation())
	local body_local_point = body:WorldToLocal(world_point)
	local delta = world_point - previous_world_point
	local preferred_direction = delta:GetLength() > physics.EPSILON and (delta / delta:GetLength()) or nil
	append_unique_sample(
		samples,
		lookup,
		key_fn,
		body_local_point,
		world_point,
		previous_world_point,
		preferred_direction
	)
end

function world_contact_sampling.BuildColliderSamples(body, collider, source, key_fn)
	local samples = {}
	local lookup = {}

	if source ~= "support" then
		for _, point in ipairs(collider:GetCollisionLocalPoints() or {}) do
			add_collider_sample(samples, lookup, key_fn, body, collider, point)
		end
	end

	if source ~= "collision" then
		for _, point in ipairs(collider:GetSupportLocalPoints() or {}) do
			add_collider_sample(samples, lookup, key_fn, body, collider, point)
		end
	end

	return samples
end

function world_contact_sampling.BuildSweepContact(body, point, hit, epsilon)
	epsilon = epsilon or physics.EPSILON
	local surface_contact = physics.GetHitSurfaceContact and physics.GetHitSurfaceContact(hit, point) or nil
	local normal = surface_contact and
		surface_contact.normal or
		hit.normal or
		hit.face_normal or
		nil
	local contact_position = surface_contact and surface_contact.position or hit.position or nil

	if not (normal and contact_position) then return nil end

	local target = contact_position + normal * body:GetCollisionMargin()
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= epsilon then return nil end

	return {
		point = point,
		position = contact_position:Copy(),
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

local function build_sphere_triangle_contact(collider, hit, v0, v1, v2, options)
	local epsilon = options.epsilon or physics.EPSILON
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local shape = collider:GetPhysicsShape()
	local radius = shape and shape.GetRadius and shape:GetRadius() or 0
	local center = collider:GetPosition()
	local closest_point = triangle_geometry.ClosestPointOnTriangle(center, v0, v1, v2)
	local delta = center - closest_point
	local distance = delta:GetLength()
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

	local normal = distance > epsilon and (delta / distance) or face_normal
	local depth = bias_world_contact_depth(
		radius + collider:GetCollisionMargin() - distance,
		get_support_contact_slop(collider, normal, hit)
	)

	if not depth or depth <= epsilon then return nil end

	return {
		point = center - normal * radius,
		position = closest_point,
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

local function build_capsule_triangle_contact(collider, hit, v0, v1, v2, options)
	local epsilon = options.epsilon or physics.EPSILON
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local shape = collider:GetPhysicsShape()

	if
		not (
			shape and
			shape.GetRadius and
			shape.GetBottomSphereCenterLocal and
			shape.GetTopSphereCenterLocal
		)
	then
		return nil
	end

	local start_point = collider:LocalToWorld(shape:GetBottomSphereCenterLocal())
	local end_point = collider:LocalToWorld(shape:GetTopSphereCenterLocal())
	local radius = shape:GetRadius()
	local segment_point, triangle_point, distance, triangle_normal = triangle_geometry.ClosestPointsOnSegmentTriangle(
		start_point,
		end_point,
		v0,
		v1,
		v2,
		{
			epsilon = epsilon,
			fallback_normal = physics.Up,
		}
	)

	if not (segment_point and triangle_point and distance) then return nil end

	local normal

	if distance > epsilon then
		normal = (segment_point - triangle_point) / distance
	else
		local center_delta = collider:GetPosition() - triangle_point
		normal = center_delta:GetLength() > epsilon and
			(
				center_delta / center_delta:GetLength()
			)
			or
			triangle_normal
	end

	local depth = bias_world_contact_depth(
		radius + collider:GetCollisionMargin() - distance,
		get_support_contact_slop(collider, normal, hit)
	)

	local function collect_sphere_swept_triangle_contact(v0, v1, v2, triangle_index, context)
		local triangle_hit = world_contact_triangles.BuildTriangleHit(
			context.model,
			context.entity,
			context.primitive,
			context.primitive_index,
			triangle_index
		)
		local contact = build_sphere_triangle_contact(context.collider, triangle_hit, v0, v1, v2, context.options)

		if contact then
			context.options.finalize_world_contact(
				context.body,
				context.kind,
				context.policy,
				context.contacts,
				contact,
				context.body:WorldToLocal(contact.point)
			)
		end
	end

	local function collect_sphere_swept_triangle_contacts(body, collider, kind, contacts, options, owner, filter, cast_up)
		local shape = collider:GetPhysicsShape()
		local radius = shape and shape.GetRadius and shape:GetRadius() or nil

		if not (physics.Sweep and radius and radius > 0) then return false end

		local previous_position = collider:GetPreviousPosition()
		local current_position = collider:GetPosition()
		local movement = current_position - previous_position
		local movement_length = movement:GetLength()

		if movement_length <= (options.epsilon or physics.EPSILON) then return false end

		local hit = physics.Sweep(
			previous_position,
			(movement / movement_length) * (movement_length + cast_up),
			radius,
			owner,
			filter
		)

		if not (hit and hit.model and hit.distance <= movement_length + cast_up) then
			return false
		end

		if not (hit.primitive and hit.primitive.polygon3d) then return false end

		local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(hit.model)
		local local_body_aabb = world_transform_utils.BuildLocalAABBFromWorldAABB(collider:GetBroadphaseAABB(), world_to_local)
		local primitive_candidates = collider.world_contact_sphere_sweep_primitives or {}
		collider.world_contact_sphere_sweep_primitives = primitive_candidates

		for i = #primitive_candidates, 1, -1 do
			primitive_candidates[i] = nil
		end

		raycast.CollectModelPrimitiveCandidatesByLocalAABB(hit.model, local_body_aabb, primitive_candidates)
		local initial_contact_count = #contacts
		local triangle_context = collider.world_contact_sphere_sweep_triangle_context or {}
		collider.world_contact_sphere_sweep_triangle_context = triangle_context
		triangle_context.body = body
		triangle_context.collider = collider
		triangle_context.contacts = contacts
		triangle_context.entity = hit.entity
		triangle_context.kind = kind
		triangle_context.model = hit.model
		triangle_context.options = options
		triangle_context.policy = options.get_contact_kind_policy(kind)

		for i = 1, #primitive_candidates do
			local candidate = primitive_candidates[i]
			local primitive = candidate and candidate.primitive or nil
			local primitive_index = candidate and candidate.primitive_idx or nil

			if primitive and primitive_index and primitive.polygon3d then
				triangle_context.primitive = primitive
				triangle_context.primitive_index = primitive_index
				world_contact_triangles.ForEachOverlappingWorldTriangle(
					primitive.polygon3d,
					local_body_aabb,
					local_to_world,
					collect_sphere_swept_triangle_contact,
					triangle_context
				)
			end
		end

		return #contacts > initial_contact_count
	end

	if not depth or depth <= epsilon then return nil end

	return {
		point = segment_point - normal * radius,
		position = triangle_point,
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

local function append_polyhedron_sweep_contacts(body, kind, policy, contacts, result, hit, options)
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local finalize_world_contact = options.finalize_world_contact
	local triangle_local_feature_key = options.triangle_local_feature_key
	local epsilon = options.epsilon or physics.EPSILON

	for _, pair in ipairs(result.contacts or {}) do
		local normal = result.normal
		local point_a = pair.point_a
		local point_b = pair.point_b
		local local_point = body:WorldToLocal(point_a)
		local depth = bias_world_contact_depth((point_a - point_b):Dot(normal), get_support_contact_slop(body, normal, hit))

		if depth and depth > epsilon then
			finalize_world_contact(
				body,
				kind,
				policy,
				contacts,
				{
					point = point_a,
					position = point_b,
					hit = hit,
					normal = normal,
					depth = depth,
					feature_key = triangle_local_feature_key and
						triangle_local_feature_key(hit, local_point, normal) or
						nil,
				},
				local_point
			)
		end
	end
end

local function collect_polyhedron_swept_triangle_contact(v0, v1, v2, triangle_index, context)
	local triangle_hit = world_contact_triangles.BuildTriangleHit(
		context.model,
		context.entity,
		context.primitive,
		context.primitive_index,
		triangle_index
	)
	local result = polyhedron_triangle_contacts.FindContact(
		context.collider,
		context.polyhedron,
		v0,
		v1,
		v2,
		{
			epsilon = context.options.epsilon,
			triangle_slop = context.options.world_contact_triangle_slop,
			manifold_merge_distance = context.options.world_manifold_merge_distance,
			face_axis_relative_tolerance = 1.05,
			face_axis_absolute_tolerance = 0.03,
		}
	)

	if result then
		append_polyhedron_sweep_contacts(
			context.body,
			context.kind,
			context.policy,
			context.contacts,
			result,
			triangle_hit,
			context.options
		)
	end
end

local function collect_polyhedron_swept_triangle_contacts(body, collider, kind, contacts, options, owner, filter, cast_up)
	if not physics.SweepCollider then return false end

	local polyhedron = collider:GetBodyPolyhedron()

	if not (polyhedron and polyhedron.vertices and polyhedron.faces) then
		return false
	end

	local previous_position = collider:GetPreviousPosition()
	local current_position = collider:GetPosition()
	local movement = current_position - previous_position
	local movement_length = movement:GetLength()

	if movement_length <= (options.epsilon or physics.EPSILON) then return false end

	local hit = physics.SweepCollider(
		collider,
		previous_position,
		(movement / movement_length) * (movement_length + cast_up),
		owner,
		filter,
		{
			Rotation = collider:GetRotation(),
		}
	)

	if not (hit and hit.model and hit.distance <= movement_length + cast_up) then
		return false
	end

	if not (hit.primitive and hit.primitive.polygon3d) then return false end

	local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(hit.model)
	local local_body_aabb = world_transform_utils.BuildLocalAABBFromWorldAABB(collider:GetBroadphaseAABB(), world_to_local)
	local primitive_candidates = collider.world_contact_sweep_primitives or {}
	collider.world_contact_sweep_primitives = primitive_candidates

	for i = #primitive_candidates, 1, -1 do
		primitive_candidates[i] = nil
	end

	raycast.CollectModelPrimitiveCandidatesByLocalAABB(hit.model, local_body_aabb, primitive_candidates)
	local initial_contact_count = #contacts
	local triangle_context = collider.world_contact_sweep_triangle_context or {}
	collider.world_contact_sweep_triangle_context = triangle_context
	triangle_context.body = body
	triangle_context.collider = collider
	triangle_context.contacts = contacts
	triangle_context.kind = kind
	triangle_context.options = options
	triangle_context.policy = options.get_contact_kind_policy(kind)
	triangle_context.polyhedron = polyhedron

	for i = 1, #primitive_candidates do
		local candidate = primitive_candidates[i]
		local primitive = candidate and candidate.primitive or nil
		local primitive_index = candidate and candidate.primitive_idx or nil

		if primitive and primitive_index and primitive.polygon3d then
			triangle_context.entity = hit.entity
			triangle_context.model = hit.model
			triangle_context.primitive = primitive
			triangle_context.primitive_index = primitive_index
			world_contact_triangles.ForEachOverlappingWorldTriangle(
				primitive.polygon3d,
				local_body_aabb,
				local_to_world,
				collect_polyhedron_swept_triangle_contact,
				triangle_context
			)
		end
	end

	return #contacts > initial_contact_count
end

local function collect_capsule_swept_triangle_contact(v0, v1, v2, triangle_index, context)
	local triangle_hit = world_contact_triangles.BuildTriangleHit(
		context.model,
		context.entity,
		context.primitive,
		context.primitive_index,
		triangle_index
	)
	local contact = build_capsule_triangle_contact(context.collider, triangle_hit, v0, v1, v2, context.options)

	if contact then
		context.options.finalize_world_contact(
			context.body,
			context.kind,
			context.policy,
			context.contacts,
			contact,
			context.body:WorldToLocal(contact.point)
		)
	end
end

local function collect_capsule_swept_triangle_contacts(body, collider, kind, contacts, options, owner, filter, cast_up)
	if not physics.SweepCollider then return false end

	local shape = collider:GetPhysicsShape()

	if
		not (
			shape and
			shape.GetRadius and
			shape.GetBottomSphereCenterLocal and
			shape.GetTopSphereCenterLocal
		)
	then
		return false
	end

	local previous_position = collider:GetPreviousPosition()
	local current_position = collider:GetPosition()
	local movement = current_position - previous_position
	local movement_length = movement:GetLength()

	if movement_length <= (options.epsilon or physics.EPSILON) then return false end

	local hit = physics.SweepCollider(
		collider,
		previous_position,
		(movement / movement_length) * (movement_length + cast_up),
		owner,
		filter,
		{
			Rotation = collider:GetRotation(),
		}
	)

	if not (hit and hit.model and hit.distance <= movement_length + cast_up) then
		return false
	end

	if not (hit.primitive and hit.primitive.polygon3d) then return false end

	local world_to_local, local_to_world = world_transform_utils.GetModelTransforms(hit.model)
	local local_body_aabb = world_transform_utils.BuildLocalAABBFromWorldAABB(collider:GetBroadphaseAABB(), world_to_local)
	local primitive_candidates = collider.world_contact_capsule_sweep_primitives or {}
	collider.world_contact_capsule_sweep_primitives = primitive_candidates

	for i = #primitive_candidates, 1, -1 do
		primitive_candidates[i] = nil
	end

	raycast.CollectModelPrimitiveCandidatesByLocalAABB(hit.model, local_body_aabb, primitive_candidates)
	local initial_contact_count = #contacts
	local policy = options.get_contact_kind_policy(kind)
	local triangle_context = collider.world_contact_capsule_sweep_triangle_context or {}
	collider.world_contact_capsule_sweep_triangle_context = triangle_context
	triangle_context.body = body
	triangle_context.collider = collider
	triangle_context.contacts = contacts
	triangle_context.entity = hit.entity
	triangle_context.kind = kind
	triangle_context.model = hit.model
	triangle_context.options = options
	triangle_context.policy = policy

	for i = 1, #primitive_candidates do
		local candidate = primitive_candidates[i]
		local primitive = candidate and candidate.primitive or nil
		local primitive_index = candidate and candidate.primitive_idx or nil

		if primitive and primitive_index and primitive.polygon3d then
			triangle_context.primitive = primitive
			triangle_context.primitive_index = primitive_index
			world_contact_triangles.ForEachOverlappingWorldTriangle(
				primitive.polygon3d,
				local_body_aabb,
				local_to_world,
				collect_capsule_swept_triangle_contact,
				triangle_context
			)
		end
	end

	return #contacts > initial_contact_count
end

function world_contact_sampling.CollectSweepContacts(body, kind, contacts, options)
	options = options or {}
	local epsilon = options.epsilon or physics.EPSILON
	local get_contact_kind_policy = options.get_contact_kind_policy
	local finalize_world_contact = options.finalize_world_contact
	local local_point_key = options.local_point_key
	local owner = body:GetOwner()
	local filter = body:GetFilterFunction()
	local cast_up = body:GetCollisionMargin() + (
			body.GetCollisionProbeDistance and
			body:GetCollisionProbeDistance() or
			0
		)
	local velocity_length = body:GetVelocity():GetLength()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local allow_sweep_sampling = not (body:GetGrounded() and velocity_length <= 0.2 and angular_speed <= 0.35)
	local policy = get_contact_kind_policy(kind)

	for _, collider in ipairs(body:GetColliders() or {}) do
		local polyhedron = collider:GetBodyPolyhedron()
		local sample_source = polyhedron and nil or "collision"
		local shape_type = collider:GetShapeType()

		if allow_sweep_sampling then
			if
				collect_polyhedron_swept_triangle_contacts(body, collider, kind, contacts, options, owner, filter, cast_up)
			then
				goto continue_collider
			end

			if
				shape_type == "capsule" and
				collect_capsule_swept_triangle_contacts(body, collider, kind, contacts, options, owner, filter, cast_up)
			then
				goto continue_collider
			end

			for _, sample in ipairs(world_contact_sampling.BuildColliderSamples(body, collider, sample_source, local_point_key)) do
				local previous_point = sample.previous_point or sample.point
				local sweep = sample.point - previous_point
				local sweep_distance = sweep:GetLength()

				if sweep_distance > epsilon then
					local hit = physics.Sweep(
						previous_point,
						sample.preferred_direction and
							(
								sample.preferred_direction * (
									sweep_distance + cast_up
								)
							)
							or
							sweep,
						0,
						owner,
						filter
					)

					if
						hit and
						hit.distance <= sweep_distance + cast_up and
						not (
							polyhedron and
							hit.primitive and
							hit.primitive.brush_planes
						)
					then
						local contact = world_contact_sampling.BuildSweepContact(body, sample.point, hit, epsilon)

						if contact then
							finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
						end
					end
				end
			end
		end

		::continue_collider::
	end
end

return world_contact_sampling
