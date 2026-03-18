local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local physics = import("goluwa/physics.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = {}

local function get_component(vec, axis_index)
	if axis_index == 1 then return vec.x end

	if axis_index == 2 then return vec.y end

	return vec.z
end

local function set_component(vec, axis_index, value)
	if axis_index == 1 then return Vec3(value, vec.y, vec.z) end

	if axis_index == 2 then return Vec3(vec.x, value, vec.z) end

	return Vec3(vec.x, vec.y, value)
end

local function get_plane_basis(normal)
	local tangent

	if math.abs(normal.x) < 0.8 then
		tangent = normal:GetCross(Vec3(1, 0, 0))
	else
		tangent = normal:GetCross(Vec3(0, 1, 0))
	end

	if tangent:GetLength() <= physics.EPSILON then
		tangent = normal:GetCross(Vec3(0, 0, 1))
	end

	tangent = tangent:GetNormalized()
	return tangent, normal:GetCross(tangent):GetNormalized()
end

local function get_edge_side(a, b, point)
	return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
end

local function clip_polygon_to_edge(points, edge_a, edge_b, inside_sign, out)
	out = out or {}

	if not points[1] then return list.clear(out) end

	local previous = points[#points]
	local previous_distance = inside_sign * get_edge_side(edge_a, edge_b, previous)
	local previous_inside = previous_distance >= -physics.EPSILON
	local count = 0

	for _, point in ipairs(points) do
		local distance = inside_sign * get_edge_side(edge_a, edge_b, point)
		local inside = distance >= -physics.EPSILON

		if inside ~= previous_inside then
			local delta = point - previous
			local denominator = previous_distance - distance

			if math.abs(denominator) > physics.EPSILON then
				local t = previous_distance / denominator
				count = count + 1
				out[count] = previous + delta * t
			end
		end

		if inside then
			count = count + 1
			out[count] = point
		end

		previous = point
		previous_distance = distance
		previous_inside = inside
	end

	return list.clear_from_index(out, count + 1)
end

local function clip_polygon_component(points, axis_index, limit, keep_less_equal, out)
	out = out or {}

	if not points[1] then return list.clear(out) end

	local previous = points[#points]
	local previous_distance = get_component(previous, axis_index) - limit
	local previous_inside = keep_less_equal and previous_distance <= 0 or previous_distance >= 0
	local count = 0

	for _, point in ipairs(points) do
		local distance = get_component(point, axis_index) - limit
		local inside = keep_less_equal and distance <= 0 or distance >= 0

		if inside ~= previous_inside then
			local delta = point - previous
			local denominator = previous_distance - distance

			if math.abs(denominator) > physics.EPSILON then
				local t = previous_distance / denominator
				count = count + 1
				out[count] = previous + delta * t
			end
		end

		if inside then
			count = count + 1
			out[count] = point
		end

		previous = point
		previous_distance = distance
		previous_inside = inside
	end

	return list.clear_from_index(out, count + 1)
end

function convex_face_clipping.ClipFacePolygonToReference(reference_body, reference_face, incident_points, scratch)
	scratch = scratch or {}
	local polygon_a = scratch.polygon_a or {}
	local polygon_b = scratch.polygon_b or {}
	scratch.polygon_a = polygon_a
	scratch.polygon_b = polygon_b
	local count = 0

	for i, point in ipairs(incident_points or {}) do
		polygon_a[i] = reference_body:WorldToLocal(point)
		count = i
	end

	list.clear_from_index(polygon_a, count + 1)
	local polygon = polygon_a
	local out = polygon_b
	polygon = clip_polygon_component(
		polygon,
		reference_face.tangent_u_index,
		reference_face.tangent_u_extent,
		true,
		out
	)
	out = polygon == polygon_a and polygon_b or polygon_a
	polygon = clip_polygon_component(
		polygon,
		reference_face.tangent_u_index,
		-reference_face.tangent_u_extent,
		false,
		out
	)
	out = polygon == polygon_a and polygon_b or polygon_a
	polygon = clip_polygon_component(
		polygon,
		reference_face.tangent_v_index,
		reference_face.tangent_v_extent,
		true,
		out
	)
	out = polygon == polygon_a and polygon_b or polygon_a
	polygon = clip_polygon_component(
		polygon,
		reference_face.tangent_v_index,
		-reference_face.tangent_v_extent,
		false,
		out
	)

	for i, point in ipairs(polygon) do
		local clamped_u = math.max(
			-reference_face.tangent_u_extent,
			math.min(reference_face.tangent_u_extent, get_component(point, reference_face.tangent_u_index))
		)
		local clamped_v = math.max(
			-reference_face.tangent_v_extent,
			math.min(reference_face.tangent_v_extent, get_component(point, reference_face.tangent_v_index))
		)
		polygon[i] = set_component(
			set_component(point, reference_face.tangent_u_index, clamped_u),
			reference_face.tangent_v_index,
			clamped_v
		)
	end

	return polygon
end

function convex_face_clipping.BuildReferenceFace(points, normal, tangent_u, tangent_v, scratch)
	if not points or not points[1] then return nil end

	scratch = scratch or {}
	normal = normal:GetNormalized()
	local center = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		center = center + point
	end

	center = center / #points

	if tangent_u then
		tangent_u = (tangent_u - normal * tangent_u:Dot(normal))

		if tangent_u:GetLength() > physics.EPSILON then
			tangent_u = tangent_u:GetNormalized()
		end
	end

	if tangent_v then
		tangent_v = (tangent_v - normal * tangent_v:Dot(normal))

		if tangent_v:GetLength() > physics.EPSILON then
			tangent_v = tangent_v:GetNormalized()
		end
	end

	if not tangent_u or tangent_u:GetLength() <= physics.EPSILON then
		for i = 1, #points do
			local next_point = points[i % #points + 1]
			local edge = next_point - points[i]
			edge = edge - normal * edge:Dot(normal)

			if edge:GetLength() > physics.EPSILON then
				tangent_u = edge:GetNormalized()

				break
			end
		end
	end

	if tangent_u and (not tangent_v or tangent_v:GetLength() <= physics.EPSILON) then
		tangent_v = normal:GetCross(tangent_u)

		if tangent_v:GetLength() > physics.EPSILON then
			tangent_v = tangent_v:GetNormalized()
		end
	end

	if
		not tangent_u or
		tangent_u:GetLength() <= physics.EPSILON or
		not tangent_v or
		tangent_v:GetLength() <= physics.EPSILON
	then
		tangent_u, tangent_v = get_plane_basis(normal)
	end

	local projected_points = scratch.projected_points or {}
	scratch.projected_points = projected_points

	for i, point in ipairs(points) do
		local relative = point - center
		local projected_point = projected_points[i] or {}
		projected_point.x = relative:Dot(tangent_u)
		projected_point.y = relative:Dot(tangent_v)
		projected_points[i] = projected_point
	end

	list.clear_from_index(projected_points, #points + 1)
	local reference_face = scratch.reference_face or {}
	scratch.reference_face = reference_face
	reference_face.center = center
	reference_face.normal = normal
	reference_face.tangent_u = tangent_u
	reference_face.tangent_v = tangent_v
	reference_face.points = points
	reference_face.projected_points = projected_points
	return reference_face
end

function convex_face_clipping.ClipIncidentPolygonToReferenceFace(reference_face, incident_points, scratch)
	scratch = scratch or {}
	local polygon_a = scratch.polygon_a or {}
	local polygon_b = scratch.polygon_b or {}
	scratch.polygon_a = polygon_a
	scratch.polygon_b = polygon_b
	local count = 0

	for i, point in ipairs(incident_points or {}) do
		local relative = point - reference_face.center
		polygon_a[i] = Vec3(
			relative:Dot(reference_face.tangent_u),
			relative:Dot(reference_face.tangent_v),
			relative:Dot(reference_face.normal)
		)
		count = i
	end

	list.clear_from_index(polygon_a, count + 1)
	local inside_point = {x = 0, y = 0}
	local polygon = polygon_a
	local out = polygon_b

	for i, edge_a in ipairs(reference_face.projected_points or {}) do
		local edge_b = reference_face.projected_points[i % #reference_face.projected_points + 1]
		local inside_sign = get_edge_side(edge_a, edge_b, inside_point) >= 0 and 1 or -1
		polygon = clip_polygon_to_edge(polygon, edge_a, edge_b, inside_sign, out)
		out = polygon == polygon_a and polygon_b or polygon_a

		if not polygon[1] then break end
	end

	return polygon
end

function convex_face_clipping.BuildFaceContactEntries(reference_face, incident_points, separation_tolerance, scratch)
	scratch = scratch or {}
	local entries = scratch.entries or {}
	scratch.entries = entries
	local clipped = convex_face_clipping.ClipIncidentPolygonToReferenceFace(reference_face, incident_points, scratch)
	separation_tolerance = separation_tolerance or 0.08
	local count = 0

	for _, local_point in ipairs(clipped) do
		local separation = local_point.z

		if separation <= separation_tolerance then
			local reference_point = reference_face.center + reference_face.tangent_u * local_point.x + reference_face.tangent_v * local_point.y
			count = count + 1
			local entry = entries[count] or {}
			entry.separation = separation
			entry.local_point = local_point
			entry.point_reference = reference_point
			entry.point_incident = reference_point + reference_face.normal * separation
			entries[count] = entry
		end
	end

	return list.clear_from_index(entries, count + 1)
end

local function compare_entry_separation(left, right)
	return left.separation < right.separation
end

local function add_selected_entry(selected, chosen, entry)
	if not entry or chosen[entry] then return end

	chosen[entry] = true
	selected[#selected + 1] = entry
end

local function pick_extreme_entry(entries, component_name, want_max)
	local best_entry
	local best_value = want_max and -math.huge or math.huge

	for _, entry in ipairs(entries) do
		local value = entry.local_point[component_name]

		if (want_max and value > best_value) or (not want_max and value < best_value) then
			best_value = value
			best_entry = entry
		end
	end

	return best_entry
end

function convex_face_clipping.SelectFaceContactEntries(entries, reference_face, max_contacts, scratch)
	max_contacts = max_contacts or 4

	if #entries <= max_contacts then
		table.sort(entries, compare_entry_separation)
		return entries
	end

	scratch = scratch or {}
	local selected = scratch.selected or {}
	local chosen = scratch.chosen or {}
	scratch.selected = selected
	scratch.chosen = chosen

	for i = 1, #selected do
		selected[i] = nil
	end

	local tangent_u_name = reference_face and
		reference_face.tangent_u_index == 1 and
		"x" or
		reference_face and
		reference_face.tangent_u_index == 2 and
		"y" or
		"z"
	local tangent_v_name = reference_face and
		reference_face.tangent_v_index == 1 and
		"x" or
		reference_face and
		reference_face.tangent_v_index == 2 and
		"y" or
		(
			reference_face and
			reference_face.tangent_v_index and
			"z" or
			"y"
		)
	add_selected_entry(selected, chosen, pick_extreme_entry(entries, tangent_u_name, false))
	add_selected_entry(selected, chosen, pick_extreme_entry(entries, tangent_u_name, true))
	add_selected_entry(selected, chosen, pick_extreme_entry(entries, tangent_v_name, false))
	add_selected_entry(selected, chosen, pick_extreme_entry(entries, tangent_v_name, true))

	if #selected < math.min(max_contacts, #entries) then
		table.sort(entries, compare_entry_separation)

		for _, entry in ipairs(entries) do
			add_selected_entry(selected, chosen, entry)

			if #selected >= max_contacts then break end
		end
	end

	for entry in pairs(chosen) do
		chosen[entry] = nil
	end

	return selected
end

function convex_face_clipping.BuildFaceContactPairs(reference_points, reference_normal, incident_points, options)
	options = options or {}
	local scratch = options.scratch or {}
	local out = options.out or {}
	local reference_face = convex_face_clipping.BuildReferenceFace(
		reference_points,
		reference_normal,
		options.tangent_u,
		options.tangent_v,
		scratch
	)

	if not reference_face then return list.clear(out) end

	local entries = convex_face_clipping.BuildFaceContactEntries(reference_face, incident_points, options.separation_tolerance, scratch)
	entries = convex_face_clipping.SelectFaceContactEntries(entries, reference_face, options.max_contacts, scratch)
	local count = 0

	for _, entry in ipairs(entries or {}) do
		local point_a = options.swap and entry.point_incident or entry.point_reference
		local point_b = options.swap and entry.point_reference or entry.point_incident
		count = convex_manifold.AddContactPointReused(out, count, point_a, point_b, options.merge_distance)
	end

	return list.clear_from_index(out, count + 1)
end

return convex_face_clipping
