local physics_constants = import("goluwa/physics/constants.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local convex_manifold = {}

function convex_manifold.CollectSupportVertices(vertices, axis, want_max, tolerance, support)
	support = support or {}
	local best = want_max and -math.huge or math.huge
	tolerance = tolerance or 0.06
	local count = 0

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)

		if want_max then
			if projection > best + tolerance then
				best = projection
				count = 1
				support[1] = point
			elseif math.abs(projection - best) <= tolerance then
				count = count + 1
				support[count] = point
			end
		else
			if projection < best - tolerance then
				best = projection
				count = 1
				support[1] = point
			elseif math.abs(projection - best) <= tolerance then
				count = count + 1
				support[count] = point
			end
		end
	end

	return list.clear_from_index(support, count + 1), best
end

function convex_manifold.AverageWorldPoints(points)
	if not points or not points[1] then return nil end

	local sum = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		sum = sum + point
	end

	return sum / #points
end

function convex_manifold.AverageSupportPoint(vertices, axis, want_max, tolerance)
	local best = want_max and -math.huge or math.huge
	tolerance = tolerance or 0.06
	local sum = nil
	local count = 0

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)

		if want_max then
			if projection > best + tolerance then
				best = projection
				sum = point
				count = 1
			elseif math.abs(projection - best) <= tolerance then
				sum = sum + point
				count = count + 1
			end
		else
			if projection < best - tolerance then
				best = projection
				sum = point
				count = 1
			elseif math.abs(projection - best) <= tolerance then
				sum = sum + point
				count = count + 1
			end
		end
	end

	if count == 0 then return nil end

	return sum / count
end

function convex_manifold.FillContactPair(contacts, index, point_a, point_b)
	local contact = contacts[index] or {}
	contact.point_a = point_a
	contact.point_b = point_b
	contacts[index] = contact
	return contact
end

function convex_manifold.TrimContacts(contacts, count)
	return list.clear_from_index(contacts, (count or 0) + 1)
end

function convex_manifold.BuildSingleContact(contacts, point_a, point_b)
	convex_manifold.FillContactPair(contacts, 1, point_a, point_b)
	return convex_manifold.TrimContacts(contacts, 1)
end

function convex_manifold.AddContactPointReused(contacts, count, point_a, point_b, merge_distance, separation)
	local midpoint = (point_a + point_b) * 0.5
	merge_distance = merge_distance or 0.1

	for i = 1, count do
		local existing = contacts[i]
		local existing_midpoint = (existing.point_a + existing.point_b) * 0.5

		if (existing_midpoint - midpoint):GetLength() <= merge_distance then
			return count
		end
	end

	count = count + 1
	local contact = convex_manifold.FillContactPair(contacts, count, point_a, point_b)

	if separation ~= nil then contact.separation = separation end

	return count
end

function convex_manifold.AddContactPoint(contacts, point_a, point_b, merge_distance, separation)
	convex_manifold.AddContactPointReused(contacts, #contacts, point_a, point_b, merge_distance, separation)
end

function convex_manifold.MergeContacts(contacts, additional_contacts, max_contacts)
	if not contacts then return additional_contacts end

	if not (additional_contacts and additional_contacts[1]) then return contacts end

	max_contacts = max_contacts or 4

	for _, pair in ipairs(additional_contacts) do
		contacts[#contacts + 1] = pair

		if #contacts >= max_contacts then break end
	end

	return contacts
end

function convex_manifold.BuildSupportPairContacts(vertices_a, vertices_b, normal, options)
	options = options or {}
	local scratch = options.scratch or {}
	local contacts = scratch.contacts or {}
	scratch.contacts = list.clear(contacts)
	scratch.support_a = scratch.support_a or {}
	scratch.support_b = scratch.support_b or {}
	contacts = scratch.contacts
	local support_a = convex_manifold.CollectSupportVertices(vertices_a, normal, true, options.support_tolerance, scratch.support_a)
	local support_b = convex_manifold.CollectSupportVertices(vertices_b, normal, false, options.support_tolerance, scratch.support_b)

	if not support_a[1] or not support_b[1] then return contacts end

	local primary = #support_a <= #support_b and support_a or support_b
	local secondary = primary == support_a and support_b or support_a
	local primary_is_a = primary == support_a
	local max_contacts = options.max_contacts or 4

	for _, point in ipairs(primary) do
		local closest_other = nil
		local closest_distance = math.huge

		for _, other in ipairs(secondary) do
			local tangent_delta = other - point
			tangent_delta = tangent_delta - normal * tangent_delta:Dot(normal)
			local tangent_distance = tangent_delta:GetLength()

			if tangent_distance < closest_distance then
				closest_distance = tangent_distance
				closest_other = other
			end
		end

		if closest_other then
			if primary_is_a then
				convex_manifold.AddContactPoint(contacts, point, closest_other, options.merge_distance)
			else
				convex_manifold.AddContactPoint(contacts, closest_other, point, options.merge_distance)
			end
		end

		if #contacts >= max_contacts then break end
	end

	return contacts
end

function convex_manifold.BuildAndMergeSupportPairContacts(contacts, vertices_a, vertices_b, normal, options)
	local support_contacts = convex_manifold.BuildSupportPairContacts(vertices_a, vertices_b, normal, options)

	if not contacts then return support_contacts end

	return convex_manifold.MergeContacts(contacts, support_contacts, options and options.max_contacts)
end

function convex_manifold.ClosestPointsOnSegments(start_a, end_a, start_b, end_b)
	return segment_geometry.ClosestPointsBetweenSegments(start_a, end_a, start_b, end_b, physics_constants.EPSILON)
end

return convex_manifold
