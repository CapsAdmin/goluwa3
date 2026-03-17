local physics = import("goluwa/physics.lua")
local brush_contacts = import("goluwa/physics/brush_contacts.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local world_contact_sampling = import("goluwa/physics/world_contact_sampling.lua")
local world_contact_triangles = import("goluwa/physics/world_contact_triangles.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local polyhedron_triangle_contacts = import("goluwa/physics/polyhedron_triangle_contacts.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_contact_collectors = {}

local function build_triangle_point_contact(collider, world_point, hit, v0, v1, v2, options)
	local epsilon = options.epsilon
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local face_normal = triangle_geometry.GetTriangleNormal(v0, v1, v2)

	if face_normal:GetLength() <= epsilon then return nil end

	local signed_distance = (world_point - v0):Dot(face_normal)
	local projected_point = world_point - face_normal * signed_distance

	if
		face_normal.y >= collider:GetMinGroundNormalY() and
		triangle_geometry.PointInTriangle(projected_point, v0, v1, v2, face_normal)
	then
		local depth = bias_world_contact_depth(
			collider:GetCollisionMargin() - signed_distance,
			get_support_contact_slop(collider, face_normal, hit)
		)

		if not depth or depth <= epsilon then return nil end

		return {
			point = world_point,
			position = projected_point,
			hit = hit,
			normal = face_normal,
			depth = depth,
		}
	end

	local closest_point = triangle_geometry.ClosestPointOnTriangle(world_point, v0, v1, v2)
	local delta = world_point - closest_point
	local distance = delta:GetLength()
	local normal = distance > epsilon and (delta / distance) or face_normal
	local depth = bias_world_contact_depth(
		collider:GetCollisionMargin() - distance,
		get_support_contact_slop(collider, normal, hit)
	)

	if not depth or depth <= epsilon then return nil end

	return {
		point = world_point,
		position = closest_point,
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

local function build_sphere_triangle_contact(collider, hit, v0, v1, v2, options)
	local epsilon = options.epsilon
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
	local epsilon = options.epsilon
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

	if not depth or depth <= epsilon then return nil end

	return {
		point = segment_point - normal * radius,
		position = triangle_point,
		hit = hit,
		normal = normal,
		depth = depth,
	}
end

local function append_polyhedron_triangle_contacts(body, kind, policy, contacts, result, local_point, hit, options)
	local bias_world_contact_depth = options.bias_world_contact_depth
	local get_support_contact_slop = options.get_support_contact_slop
	local finalize_world_contact = options.finalize_world_contact
	local triangle_local_feature_key = options.triangle_local_feature_key
	local epsilon = options.epsilon

	for _, pair in ipairs(result.contacts or {}) do
		local normal = result.normal
		local point_a = pair.point_a
		local point_b = pair.point_b
		local resolved_local_point = local_point or body:WorldToLocal(point_a)
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
					feature_key = triangle_local_feature_key(hit, resolved_local_point, normal),
				},
				resolved_local_point
			)
		end
	end
end

local function collect_brush_contacts_for_collider(body, collider, hit, world_to_local, local_to_world, contacts, policy, kind, options)
	local epsilon = options.epsilon
	local brush_feature_epsilon = options.brush_feature_epsilon
	local finalize_world_contact = options.finalize_world_contact
	local get_support_contact_slop = options.get_support_contact_slop
	local bias_world_contact_depth = options.bias_world_contact_depth
	local local_point_key = options.local_point_key

	if collider:GetShapeType() == "sphere" then
		local contact = brush_contacts.BuildSphereContact(
			collider,
			hit,
			world_to_local,
			local_to_world,
			world_transform_utils.TransformPosition,
			world_transform_utils.TransformDirection,
			get_support_contact_slop,
			bias_world_contact_depth,
			epsilon
		)

		if contact then
			finalize_world_contact(body, kind, policy, contacts, contact, body:WorldToLocal(contact.point))
		end

		return
	end

	local body_polyhedron = shape_accessors.GetBodyPolyhedron(collider)

	if body_polyhedron and body_polyhedron.vertices and body_polyhedron.vertices[1] then
		local initial_contact_count = #contacts
		local velocity = collider.GetVelocity and collider:GetVelocity() or Vec3()
		local preferred_direction = velocity:GetLength() > epsilon and
			(
				world_to_local and
				world_transform_utils.TransformDirection(world_to_local, velocity) or
				velocity:GetNormalized()
			)
			or
			nil
		local planes = brush_contacts.GetPolyhedronFeaturePlanes(
			collider,
			body_polyhedron,
			hit.primitive.brush_planes,
			world_to_local,
			preferred_direction,
			world_transform_utils.TransformPosition,
			brush_feature_epsilon,
			epsilon
		)
		local plane_vertex_tolerance = 0.05
		local plane_sample_tolerance = 0.08

		if not planes then return end

		for _, plane in ipairs(planes) do
			local best_signed_distance = -math.huge
			local candidates = {}

			for _, local_vertex in ipairs(body_polyhedron.vertices) do
				local world_point = collider:LocalToWorld(local_vertex)
				local brush_local_point = world_to_local and world_transform_utils.TransformPosition(world_to_local, world_point) or world_point
				local signed_distance = brush_local_point:Dot(plane.normal) - plane.dist

				if signed_distance > best_signed_distance + plane_vertex_tolerance then
					best_signed_distance = signed_distance
					candidates = {
						{
							world_point = world_point,
							brush_local_point = brush_local_point,
						},
					}
				elseif math.abs(signed_distance - best_signed_distance) <= plane_vertex_tolerance then
					candidates[#candidates + 1] = {
						world_point = world_point,
						brush_local_point = brush_local_point,
					}
				end
			end

			for _, candidate in ipairs(candidates) do
				local projected_local = candidate.brush_local_point - plane.normal * (
						candidate.brush_local_point:Dot(plane.normal) - plane.dist
					)
				local projected_world = local_to_world and
					world_transform_utils.TransformPosition(local_to_world, projected_local) or
					projected_local
				local normal_world = local_to_world and
					world_transform_utils.TransformDirection(local_to_world, plane.normal) or
					plane.normal
				local target = projected_world + normal_world * collider:GetCollisionMargin()
				local correction = target - candidate.world_point
				local depth = bias_world_contact_depth(correction:Dot(normal_world), get_support_contact_slop(body, normal_world))

				if depth and depth > epsilon then
					finalize_world_contact(
						body,
						kind,
						policy,
						contacts,
						{
							point = candidate.world_point,
							position = projected_world,
							hit = hit,
							normal = normal_world,
							depth = depth,
						},
						body:WorldToLocal(candidate.world_point)
					)
				end
			end
		end

		for _, sample in ipairs(world_contact_sampling.BuildColliderSamples(body, collider, nil, local_point_key)) do
			local brush_local_point = world_to_local and
				world_transform_utils.TransformPosition(world_to_local, sample.point) or
				sample.point

			for _, plane in ipairs(planes) do
				local signed_distance = brush_local_point:Dot(plane.normal) - plane.dist

				if signed_distance >= -plane_sample_tolerance then
					local projected_local = brush_local_point - plane.normal * signed_distance
					local projected_world = local_to_world and
						world_transform_utils.TransformPosition(local_to_world, projected_local) or
						projected_local
					local normal_world = local_to_world and
						world_transform_utils.TransformDirection(local_to_world, plane.normal) or
						plane.normal
					local target = projected_world + normal_world * collider:GetCollisionMargin()
					local correction = target - sample.point
					local depth = bias_world_contact_depth(correction:Dot(normal_world), get_support_contact_slop(body, normal_world))

					if depth and depth > epsilon then
						finalize_world_contact(
							body,
							kind,
							policy,
							contacts,
							{
								point = sample.point,
								position = projected_world,
								hit = hit,
								normal = normal_world,
								depth = depth,
							},
							sample.local_point
						)
					end
				end
			end
		end

		if #contacts - initial_contact_count < 3 then
			for _, sample in ipairs(world_contact_sampling.BuildColliderSamples(body, collider, "support", local_point_key)) do
				local built_contacts = brush_contacts.BuildPointContacts(
					collider,
					sample.point,
					hit,
					world_to_local,
					local_to_world,
					sample.preferred_direction,
					world_transform_utils.TransformPosition,
					world_transform_utils.TransformDirection,
					brush_feature_epsilon,
					epsilon,
					get_support_contact_slop,
					bias_world_contact_depth
				)

				for _, contact in ipairs(built_contacts or {}) do
					finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
				end
			end
		end

		return
	end

	for _, sample in ipairs(world_contact_sampling.BuildColliderSamples(body, collider, nil, local_point_key)) do
		local built_contacts = brush_contacts.BuildPointContacts(
			collider,
			sample.point,
			hit,
			world_to_local,
			local_to_world,
			sample.preferred_direction,
			world_transform_utils.TransformPosition,
			world_transform_utils.TransformDirection,
			brush_feature_epsilon,
			epsilon,
			get_support_contact_slop,
			bias_world_contact_depth
		)

		for _, contact in ipairs(built_contacts or {}) do
			finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
		end
	end
end

local function collect_triangle_contacts_for_collider(body, collider, model, entity, primitive, primitive_index, local_body_aabb, local_to_world, contacts, policy, kind, options)
	local epsilon = options.epsilon
	local triangle_slop = options.world_contact_triangle_slop
	local manifold_merge_distance = options.world_manifold_merge_distance
	local finalize_world_contact = options.finalize_world_contact
	local local_point_key = options.local_point_key
	local poly = primitive and primitive.polygon3d or nil
	local local_vertices = world_contact_triangles.GetPolygonLocalVertices(poly)
	local indices, triangle_count = world_contact_triangles.GetPolygonIndexBuffer(poly)

	if not (poly and local_vertices and indices and triangle_count > 0) then
		return
	end

	local shape_type = collider:GetShapeType()
	local body_polyhedron = shape_accessors.GetBodyPolyhedron(collider)

	if shape_type == "sphere" then
		world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, function(v0, v1, v2, triangle_index)
			local hit = world_contact_triangles.BuildTriangleHit(model, entity, primitive, primitive_index, triangle_index)
			local contact = build_sphere_triangle_contact(collider, hit, v0, v1, v2, options)

			if contact then
				finalize_world_contact(body, kind, policy, contacts, contact, body:WorldToLocal(contact.point))
			end
		end)

		return
	end

	if shape_type == "capsule" then
		world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, function(v0, v1, v2, triangle_index)
			local hit = world_contact_triangles.BuildTriangleHit(model, entity, primitive, primitive_index, triangle_index)
			local contact = build_capsule_triangle_contact(collider, hit, v0, v1, v2, options)

			if contact then
				finalize_world_contact(body, kind, policy, contacts, contact, body:WorldToLocal(contact.point))
			end
		end)

		return
	end

	if body_polyhedron and body_polyhedron.vertices and body_polyhedron.faces then
		local samples = world_contact_sampling.BuildColliderSamples(body, collider, nil, local_point_key)

		world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, function(v0, v1, v2, triangle_index)
			local hit = world_contact_triangles.BuildTriangleHit(model, entity, primitive, primitive_index, triangle_index)
			local result = polyhedron_triangle_contacts.FindContact(
				collider,
				body_polyhedron,
				v0,
				v1,
				v2,
				{
					epsilon = epsilon,
					triangle_slop = triangle_slop,
					manifold_merge_distance = manifold_merge_distance,
					face_axis_relative_tolerance = 1.05,
					face_axis_absolute_tolerance = 0.03,
				}
			)

			if result then
				append_polyhedron_triangle_contacts(body, kind, policy, contacts, result, nil, hit, options)
			elseif samples[1] then
				for _, sample in ipairs(samples) do
					local contact = build_triangle_point_contact(collider, sample.point, hit, v0, v1, v2, options)

					if contact then
						finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
					end
				end
			end
		end)

		return
	end

	local samples = world_contact_sampling.BuildColliderSamples(body, collider, nil, local_point_key)

	if not samples[1] then return end

	world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, function(v0, v1, v2, triangle_index)
		local hit = world_contact_triangles.BuildTriangleHit(model, entity, primitive, primitive_index, triangle_index)

		for _, sample in ipairs(samples) do
			local contact = build_triangle_point_contact(collider, sample.point, hit, v0, v1, v2, options)

			if contact then
				finalize_world_contact(body, kind, policy, contacts, contact, sample.local_point)
			end
		end
	end)
end

function world_contact_collectors.CollectWorldPrimitiveContactsCallback(
	model,
	entity,
	primitive,
	primitive_index,
	local_body_aabb,
	world_to_local,
	local_to_world,
	body,
	contacts,
	policy,
	options
)
	local base_hit = {
		entity = entity,
		model = model,
		primitive = primitive,
		primitive_index = primitive_index,
	}
	local kind = options.kind

	for _, collider in ipairs(body:GetColliders() or {}) do
		if primitive.brush_planes then
			collect_brush_contacts_for_collider(body, collider, base_hit, world_to_local, local_to_world, contacts, policy, kind, options)
		elseif primitive.polygon3d then
			collect_triangle_contacts_for_collider(
				body,
				collider,
				model,
				entity,
				primitive,
				primitive_index,
				local_body_aabb,
				local_to_world,
				contacts,
				policy,
				kind,
				options
			)
		end
	end
end

return world_contact_collectors
