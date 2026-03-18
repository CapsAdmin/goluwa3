local Vec3 = import("goluwa/structs/vec3.lua")
local brush_contacts = {}

local function sort_planes_by_preferred_direction(planes, preferred_direction)
	for i = 2, #planes do
		local plane = planes[i]
		local plane_dot = preferred_direction:Dot(plane.normal)
		local j = i - 1

		while j >= 1 and preferred_direction:Dot(planes[j].normal) > plane_dot do
			planes[j + 1] = planes[j]
			j = j - 1
		end

		planes[j + 1] = plane
	end
end

function brush_contacts.GetFeaturePlanesLocal(planes, reference_point, preferred_direction, brush_feature_epsilon, epsilon)
	if not (planes and planes[1] and reference_point) then return nil end

	local max_signed_distance = -math.huge
	local signed_distances = {}
	local active_planes = {}
	local filtered_planes = nil

	for i, plane in ipairs(planes) do
		local signed_distance = reference_point:Dot(plane.normal) - plane.dist
		signed_distances[i] = signed_distance

		if signed_distance > max_signed_distance then
			max_signed_distance = signed_distance
		end
	end

	for i, plane in ipairs(planes) do
		if signed_distances[i] >= max_signed_distance - brush_feature_epsilon then
			active_planes[#active_planes + 1] = plane
		end
	end

	if not active_planes[1] then return nil end

	if preferred_direction and preferred_direction:GetLength() > epsilon then
		filtered_planes = {}

		for _, plane in ipairs(active_planes) do
			if preferred_direction:Dot(plane.normal) <= -0.05 then
				filtered_planes[#filtered_planes + 1] = plane
			end
		end

		if filtered_planes[1] then
			sort_planes_by_preferred_direction(filtered_planes, preferred_direction)
		end
	end

	return filtered_planes and filtered_planes[1] and filtered_planes or active_planes
end

function brush_contacts.GetPolyhedronFeaturePlanes(
	collider,
	polyhedron,
	planes,
	world_to_local,
	preferred_direction,
	transform_position,
	brush_feature_epsilon,
	epsilon
)
	if
		not (
			polyhedron and
			polyhedron.vertices and
			polyhedron.vertices[1] and
			planes and
			planes[1]
		)
	then
		return nil
	end

	local max_signed_distance = -math.huge
	local plane_distances = {}
	local active_planes = {}
	local filtered_planes = nil

	for i, plane in ipairs(planes) do
		local best_signed_distance = -math.huge

		for _, local_vertex in ipairs(polyhedron.vertices) do
			local world_point = collider:LocalToWorld(local_vertex)
			local brush_local_point = world_to_local and transform_position(world_to_local, world_point) or world_point
			local signed_distance = brush_local_point:Dot(plane.normal) - plane.dist

			if signed_distance > best_signed_distance then
				best_signed_distance = signed_distance
			end
		end

		plane_distances[i] = best_signed_distance

		if best_signed_distance > max_signed_distance then
			max_signed_distance = best_signed_distance
		end
	end

	for i, plane in ipairs(planes) do
		if plane_distances[i] >= max_signed_distance - brush_feature_epsilon then
			active_planes[#active_planes + 1] = plane
		end
	end

	if not active_planes[1] then return nil end

	if preferred_direction and preferred_direction:GetLength() > epsilon then
		filtered_planes = {}

		for _, plane in ipairs(active_planes) do
			if preferred_direction:Dot(plane.normal) <= -0.05 then
				filtered_planes[#filtered_planes + 1] = plane
			end
		end

		if filtered_planes[1] then
			sort_planes_by_preferred_direction(filtered_planes, preferred_direction)
		end
	end

	return filtered_planes and filtered_planes[1] and filtered_planes or active_planes
end

function brush_contacts.BuildPointContacts(
	collider,
	world_point,
	hit,
	world_to_local,
	local_to_world,
	preferred_direction,
	brush_feature_epsilon,
	epsilon,
	get_support_contact_slop,
	bias_world_contact_depth
)
	local local_point = world_to_local and world_to_local:TransformVector(world_point) or world_point
	local local_direction = preferred_direction and
		(
			preferred_direction:GetLength() > epsilon and
			(
				world_to_local and
				world_to_local:TransformDirection(preferred_direction) or
				preferred_direction:GetNormalized()
			)
			or
			nil
		)
		or
		nil
	local planes = brush_contacts.GetFeaturePlanesLocal(hit.primitive.brush_planes, local_point, local_direction, brush_feature_epsilon, epsilon)

	if not planes then return nil end

	local contacts = {}

	for _, plane in ipairs(planes) do
		local projected_local = local_point - plane.normal * (local_point:Dot(plane.normal) - plane.dist)
		local projected_world = local_to_world and
			transform_position(local_to_world, projected_local) or
			projected_local
		local normal_world = local_to_world and
			transform_direction(local_to_world, plane.normal) or
			plane.normal
		local target = projected_world + normal_world * collider:GetCollisionMargin()
		local correction = target - world_point
		local depth = bias_world_contact_depth(correction:Dot(normal_world), get_support_contact_slop(collider, normal_world))

		if depth and depth > epsilon then
			contacts[#contacts + 1] = {
				point = world_point,
				position = projected_world,
				hit = hit,
				normal = normal_world,
				depth = depth,
			}
		end
	end

	return contacts
end

function brush_contacts.BuildSphereContact(
	collider,
	hit,
	world_to_local,
	local_to_world,
	get_support_contact_slop,
	bias_world_contact_depth,
	epsilon
)
	local shape = collider:GetPhysicsShape()

	if not (shape and shape.GetRadius) then return nil end

	local center_world = collider:GetPosition()
	local center = world_to_local and world_to_local:TransformVector(center_world) or center_world
	local radius = shape:GetRadius()
	local inflate = radius + collider:GetCollisionMargin()
	local planes = hit.primitive.brush_planes
	local closest = center:Copy()
	local changed = false

	for _ = 1, 8 do
		local pass_changed = false

		for _, plane in ipairs(planes) do
			local signed_distance = closest:Dot(plane.normal) - plane.dist

			if signed_distance > epsilon then
				closest = closest - plane.normal * signed_distance
				pass_changed = true
				changed = true
			end
		end

		if not pass_changed then break end
	end

	local normal_local = nil
	local contact_position_local = nil
	local depth = 0

	if changed then
		local delta = center - closest
		local distance = delta:GetLength()

		if distance <= epsilon or distance > inflate then return nil end

		normal_local = delta / distance
		contact_position_local = closest
		depth = inflate - distance
	else
		local max_signed_distance = -math.huge
		local signed_distances = {}

		for i, plane in ipairs(planes) do
			local signed_distance = center:Dot(plane.normal) - plane.dist
			signed_distances[i] = signed_distance

			if signed_distance > max_signed_distance then
				max_signed_distance = signed_distance
			end
		end

		if max_signed_distance <= -inflate then return nil end

		local blend_epsilon = math.max(0.02, radius * 0.1)
		local normal_sum = Vec3(0, 0, 0)
		local active_planes = {}

		for i, plane in ipairs(planes) do
			if signed_distances[i] >= max_signed_distance - blend_epsilon then
				normal_sum = normal_sum + plane.normal
				active_planes[#active_planes + 1] = plane
			end
		end

		if normal_sum:GetLength() <= epsilon then return nil end

		normal_local = normal_sum:GetNormalized()

		for _, plane in ipairs(active_planes) do
			local denom = normal_local:Dot(plane.normal)

			if denom > epsilon then
				depth = math.max(depth, (inflate + center:Dot(plane.normal) - plane.dist) / denom)
			end
		end

		depth = bias_world_contact_depth(depth, get_support_contact_slop(collider, normal_world))

		if not depth or depth <= epsilon then return nil end

		contact_position_local = center - normal_local * (inflate - depth)
	end

	local normal_world = local_to_world and
		local_to_world:TransformDirection(normal_local) or
		normal_local
	local contact_position_world = local_to_world and
		local_to_world:TransformVector(contact_position_local) or
		contact_position_local
	return {
		point = center_world - normal_world * radius,
		position = contact_position_world,
		hit = hit,
		normal = normal_world,
		depth = depth,
	}
end

return brush_contacts
