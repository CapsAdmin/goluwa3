local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local convex_face_clipping = {}
local EPSILON = solver.EPSILON or 0.00001

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

	if tangent:GetLength() <= EPSILON then
		tangent = normal:GetCross(Vec3(0, 0, 1))
	end

	tangent = tangent:GetNormalized()
	return tangent, normal:GetCross(tangent):GetNormalized()
end

local function get_edge_side(a, b, point)
	return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
end

local function clip_polygon_to_edge(points, edge_a, edge_b, inside_sign)
	if not points[1] then return {} end

	local clipped = {}
	local previous = points[#points]
	local previous_distance = inside_sign * get_edge_side(edge_a, edge_b, previous)
	local previous_inside = previous_distance >= -EPSILON

	for _, point in ipairs(points) do
		local distance = inside_sign * get_edge_side(edge_a, edge_b, point)
		local inside = distance >= -EPSILON

		if inside ~= previous_inside then
			local delta = point - previous
			local denominator = previous_distance - distance

			if math.abs(denominator) > EPSILON then
				local t = previous_distance / denominator
				clipped[#clipped + 1] = previous + delta * t
			end
		end

		if inside then clipped[#clipped + 1] = point end

		previous = point
		previous_distance = distance
		previous_inside = inside
	end

	return clipped
end

local function clip_polygon_component(points, axis_index, limit, keep_less_equal)
	if not points[1] then return {} end

	local clipped = {}
	local previous = points[#points]
	local previous_distance = get_component(previous, axis_index) - limit
	local previous_inside = keep_less_equal and previous_distance <= 0 or previous_distance >= 0

	for _, point in ipairs(points) do
		local distance = get_component(point, axis_index) - limit
		local inside = keep_less_equal and distance <= 0 or distance >= 0

		if inside ~= previous_inside then
			local delta = point - previous
			local denominator = previous_distance - distance

			if math.abs(denominator) > EPSILON then
				local t = previous_distance / denominator
				clipped[#clipped + 1] = previous + delta * t
			end
		end

		if inside then clipped[#clipped + 1] = point end

		previous = point
		previous_distance = distance
		previous_inside = inside
	end

	return clipped
end

function convex_face_clipping.ClipFacePolygonToReference(reference_body, reference_face, incident_points)
	local polygon = {}

	for i, point in ipairs(incident_points or {}) do
		polygon[i] = reference_body:WorldToLocal(point)
	end

	polygon = clip_polygon_component(polygon, reference_face.tangent_u_index, reference_face.tangent_u_extent, true)
	polygon = clip_polygon_component(polygon, reference_face.tangent_u_index, -reference_face.tangent_u_extent, false)
	polygon = clip_polygon_component(polygon, reference_face.tangent_v_index, reference_face.tangent_v_extent, true)
	polygon = clip_polygon_component(polygon, reference_face.tangent_v_index, -reference_face.tangent_v_extent, false)

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

function convex_face_clipping.BuildReferenceFace(points, normal, tangent_u, tangent_v)
	if not points or not points[1] then return nil end

	normal = normal:GetNormalized()
	local center = Vec3(0, 0, 0)

	for _, point in ipairs(points) do
		center = center + point
	end

	center = center / #points

	if tangent_u then
		tangent_u = (tangent_u - normal * tangent_u:Dot(normal))

		if tangent_u:GetLength() > EPSILON then tangent_u = tangent_u:GetNormalized() end
	end

	if tangent_v then
		tangent_v = (tangent_v - normal * tangent_v:Dot(normal))

		if tangent_v:GetLength() > EPSILON then tangent_v = tangent_v:GetNormalized() end
	end

	if not tangent_u or tangent_u:GetLength() <= EPSILON then
		for i = 1, #points do
			local next_point = points[i % #points + 1]
			local edge = next_point - points[i]
			edge = edge - normal * edge:Dot(normal)

			if edge:GetLength() > EPSILON then
				tangent_u = edge:GetNormalized()

				break
			end
		end
	end

	if tangent_u and (not tangent_v or tangent_v:GetLength() <= EPSILON) then
		tangent_v = normal:GetCross(tangent_u)

		if tangent_v:GetLength() > EPSILON then tangent_v = tangent_v:GetNormalized() end
	end

	if
		not tangent_u or
		tangent_u:GetLength() <= EPSILON or
		not tangent_v or
		tangent_v:GetLength() <= EPSILON
	then
		tangent_u, tangent_v = get_plane_basis(normal)
	end

	local projected_points = {}

	for i, point in ipairs(points) do
		local relative = point - center
		projected_points[i] = {
			x = relative:Dot(tangent_u),
			y = relative:Dot(tangent_v),
		}
	end

	return {
		center = center,
		normal = normal,
		tangent_u = tangent_u,
		tangent_v = tangent_v,
		points = points,
		projected_points = projected_points,
	}
end

function convex_face_clipping.ClipIncidentPolygonToReferenceFace(reference_face, incident_points)
	local polygon = {}

	for i, point in ipairs(incident_points or {}) do
		local relative = point - reference_face.center
		polygon[i] = Vec3(
			relative:Dot(reference_face.tangent_u),
			relative:Dot(reference_face.tangent_v),
			relative:Dot(reference_face.normal)
		)
	end

	local inside_point = {x = 0, y = 0}

	for i, edge_a in ipairs(reference_face.projected_points or {}) do
		local edge_b = reference_face.projected_points[i % #reference_face.projected_points + 1]
		local inside_sign = get_edge_side(edge_a, edge_b, inside_point) >= 0 and 1 or -1
		polygon = clip_polygon_to_edge(polygon, edge_a, edge_b, inside_sign)

		if not polygon[1] then break end
	end

	return polygon
end

function convex_face_clipping.BuildFaceContactEntries(reference_face, incident_points, separation_tolerance)
	local entries = {}
	local clipped = convex_face_clipping.ClipIncidentPolygonToReferenceFace(reference_face, incident_points)
	separation_tolerance = separation_tolerance or 0.08

	for _, local_point in ipairs(clipped) do
		local separation = local_point.z

		if separation <= separation_tolerance then
			local reference_point = reference_face.center + reference_face.tangent_u * local_point.x + reference_face.tangent_v * local_point.y
			entries[#entries + 1] = {
				separation = separation,
				local_point = local_point,
				point_reference = reference_point,
				point_incident = reference_point + reference_face.normal * separation,
			}
		end
	end

	return entries
end

function convex_face_clipping.SelectFaceContactEntries(entries, reference_face, max_contacts)
	max_contacts = max_contacts or 4

	if #entries <= max_contacts then
		table.sort(entries, function(left, right)
			return left.separation < right.separation
		end)

		return entries
	end

	local selected = {}
	local chosen = {}
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

	local function add_entry(entry)
		if not entry or chosen[entry] then return end

		chosen[entry] = true
		selected[#selected + 1] = entry
	end

	local function pick_extreme(component_name, want_max)
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

	add_entry(pick_extreme(tangent_u_name, false))
	add_entry(pick_extreme(tangent_u_name, true))
	add_entry(pick_extreme(tangent_v_name, false))
	add_entry(pick_extreme(tangent_v_name, true))

	if #selected < math.min(max_contacts, #entries) then
		table.sort(entries, function(left, right)
			return left.separation < right.separation
		end)

		for _, entry in ipairs(entries) do
			add_entry(entry)

			if #selected >= math.min(max_contacts, #entries) then break end
		end
	end

	return selected
end

return convex_face_clipping