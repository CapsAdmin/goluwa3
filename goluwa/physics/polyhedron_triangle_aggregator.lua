local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local polyhedron_triangle_aggregator = {}

function polyhedron_triangle_aggregator.OrientResultNormal(body, result, v0, v1, v2)
	if not (body and result and result.normal) then return nil end

	local normal = result.normal
	local triangle_center = triangle_geometry.GetTriangleCenter(v0, v1, v2)

	if (body:GetPosition() - triangle_center):Dot(normal) < 0 then
		normal = normal * -1
	end

	return normal
end

function polyhedron_triangle_aggregator.MergeContact(contacts, point_a, point_b, merge_distance)
	merge_distance = merge_distance or 0.08

	for _, existing in ipairs(contacts) do
		if
			(existing.point_a - point_a):GetLength() <= merge_distance and
			(existing.point_b - point_b):GetLength() <= merge_distance
		then
			return false
		end
	end

	contacts[#contacts + 1] = {
		point_a = point_a,
		point_b = point_b,
	}
	return true
end

function polyhedron_triangle_aggregator.AccumulateMeshContacts(state, body, result, v0, v1, v2, options)
	if not (state and body and result and result.contacts and result.contacts[1]) then return state end

	options = options or {}
	local merge_distance = options.merge_distance or 0.08
	local max_contacts = options.max_contacts or 4
	local normal = polyhedron_triangle_aggregator.OrientResultNormal(body, result, v0, v1, v2)

	if not normal then return state end

	state.best_overlap = math.max(state.best_overlap or 0, result.overlap or 0)

	if result.overlap == state.best_overlap then
		state.best_normal = normal
	elseif not state.best_normal then
		state.best_normal = normal
	end

	for _, pair in ipairs(result.contacts) do
		local point_a = pair.point_b
		local point_b = pair.point_a

		if point_a and point_b then
			polyhedron_triangle_aggregator.MergeContact(state.contacts, point_a, point_b, merge_distance)

			if #state.contacts >= max_contacts then break end
		end
	end

	return state
end

function polyhedron_triangle_aggregator.AppendWorldContacts(body, kind, policy, contacts, result, local_point, hit, options)
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

return polyhedron_triangle_aggregator