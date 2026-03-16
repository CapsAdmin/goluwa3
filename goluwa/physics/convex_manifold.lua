local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local convex_manifold = {}
local EPSILON = solver.EPSILON or 0.00001

local function clear_array(array, from_index)
	from_index = from_index or 1

	for i = from_index, #array do
		array[i] = nil
	end

	return array
end

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

	return clear_array(support, count + 1), best
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

function convex_manifold.AddContactPoint(contacts, point_a, point_b, merge_distance)
	local midpoint = (point_a + point_b) * 0.5
	merge_distance = merge_distance or 0.1

	for _, existing in ipairs(contacts) do
		local existing_midpoint = (existing.point_a + existing.point_b) * 0.5

		if (existing_midpoint - midpoint):GetLength() <= merge_distance then return end
	end

	contacts[#contacts + 1] = {
		point_a = point_a,
		point_b = point_b,
	}
end

function convex_manifold.BuildSupportPairContacts(vertices_a, vertices_b, normal, options)
	options = options or {}
	local scratch = options.scratch or {}
	local contacts = scratch.contacts or {}
	scratch.contacts = clear_array(contacts)
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

local function clamp01(value)
	return math.max(0, math.min(1, value))
end

function convex_manifold.ClosestPointsOnSegments(start_a, end_a, start_b, end_b)
	local direction_a = end_a - start_a
	local direction_b = end_b - start_b
	local delta = start_a - start_b
	local a = direction_a:Dot(direction_a)
	local e = direction_b:Dot(direction_b)
	local f = direction_b:Dot(delta)
	local s
	local t

	if a <= EPSILON and e <= EPSILON then return start_a, start_b end

	if a <= EPSILON then
		s = 0
		t = clamp01(f / e)
	else
		local c = direction_a:Dot(delta)

		if e <= EPSILON then
			t = 0
			s = clamp01(-c / a)
		else
			local b = direction_a:Dot(direction_b)
			local denominator = a * e - b * b

			if math.abs(denominator) > EPSILON then
				s = clamp01((b * f - c * e) / denominator)
			else
				s = 0
			end

			t = (b * s + f) / e

			if t < 0 then
				t = 0
				s = clamp01(-c / a)
			elseif t > 1 then
				t = 1
				s = clamp01((b - c) / a)
			end
		end
	end

	return start_a + direction_a * s, start_b + direction_b * t
end

return convex_manifold