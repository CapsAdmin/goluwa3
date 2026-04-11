local physics_constants = import("goluwa/physics/constants.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local gjk_epa = {}
local EPSILON = physics_constants.EPSILON
local GJK_MAX_ITERATIONS = 32
local EPA_MAX_ITERATIONS = 48
local EPA_MAX_VERTICES = 64
local EPA_MAX_FACES = 96
local EPA_FACE_EPSILON = 0.00001
local EPA_CONVERGENCE_EPSILON = 0.0005

local function clear_array(array, start_index)
	for i = start_index or 1, #array do
		array[i] = nil
	end

	return array
end

local function set_simplex(simplex, ...)
	local count = select("#", ...)

	for i = 1, count do
		simplex[i] = select(i, ...)
	end

	return clear_array(simplex, count + 1)
end

local function get_vertices_centroid(vertices)
	local center = Vec3(0, 0, 0)
	local count = 0

	for i = 1, #(vertices or {}) do
		center = center + vertices[i]
		count = count + 1
	end

	if count == 0 then return Vec3(0, 0, 0) end

	return center / count
end

local function get_any_perpendicular(direction)
	local axis = math.abs(direction.x) < 0.577 and
		Vec3(1, 0, 0) or
		math.abs(direction.y) < 0.577 and
		Vec3(0, 1, 0)
		or
		Vec3(0, 0, 1)
	local perpendicular = direction:GetCross(axis)

	if perpendicular:GetLength() <= EPSILON then
		axis = axis.x == 0 and Vec3(1, 0, 0) or Vec3(0, 1, 0)
		perpendicular = direction:GetCross(axis)
	end

	if perpendicular:GetLength() <= EPSILON then return Vec3(1, 0, 0) end

	return perpendicular:GetNormalized()
end

local function get_perpendicular_towards(edge, toward)
	local perpendicular = edge:GetCross(toward):GetCross(edge)

	if perpendicular:GetLength() <= EPSILON then
		perpendicular = get_any_perpendicular(edge)
	end

	return perpendicular
end

local function same_direction(direction, toward)
	return direction:Dot(toward) > 0
end

local function get_farthest_vertex(vertices, direction)
	local best_index = nil
	local best_projection = -math.huge

	for i = 1, #(vertices or {}) do
		local point = vertices[i]
		local projection = point:Dot(direction)

		if projection > best_projection then
			best_projection = projection
			best_index = i
		end
	end

	if not best_index then return nil end

	return vertices[best_index], best_index, best_projection
end

local function get_support(vertices_a, vertices_b, direction)
	local point_a, index_a = get_farthest_vertex(vertices_a, direction)
	local point_b, index_b = get_farthest_vertex(vertices_b, direction * -1)

	if not (point_a and point_b) then return nil end

	return {
		point = point_a - point_b,
		point_a = point_a,
		point_b = point_b,
		index_a = index_a,
		index_b = index_b,
	}
end

local function solve_line(simplex, a, b)
	local ao = a.point * -1
	local ab = b.point - a.point

	if same_direction(ab, ao) then
		return false, set_simplex(simplex, a, b), get_perpendicular_towards(ab, ao)
	end

	return false, set_simplex(simplex, a), ao
end

local function solve_triangle(simplex, a, b, c)
	local ao = a.point * -1
	local ab = b.point - a.point
	local ac = c.point - a.point
	local abc = ab:GetCross(ac)
	local ab_perpendicular = abc:GetCross(ab)

	if same_direction(ab_perpendicular, ao) then
		return solve_line(simplex, a, b)
	end

	local ac_perpendicular = ac:GetCross(abc)

	if same_direction(ac_perpendicular, ao) then
		return solve_line(simplex, a, c)
	end

	if same_direction(abc, ao) then
		return false, set_simplex(simplex, a, b, c), abc
	end

	return false, set_simplex(simplex, a, c, b), abc * -1
end

local function handle_simplex(simplex)
	local count = #simplex

	if count == 1 then return false, simplex[1].point * -1 end

	if count == 2 then return solve_line(simplex, simplex[1], simplex[2]) end

	if count == 3 then
		return solve_triangle(simplex, simplex[1], simplex[2], simplex[3])
	end

	local a = simplex[1]
	local b = simplex[2]
	local c = simplex[3]
	local d = simplex[4]
	local ao = a.point * -1
	local ab = b.point - a.point
	local ac = c.point - a.point
	local ad = d.point - a.point
	local abc = ab:GetCross(ac)
	local acd = ac:GetCross(ad)
	local adb = ad:GetCross(ab)

	if abc:Dot(ad) > 0 then abc = abc * -1 end

	if acd:Dot(ab) > 0 then acd = acd * -1 end

	if adb:Dot(ac) > 0 then adb = adb * -1 end

	if same_direction(abc, ao) then return solve_triangle(simplex, a, b, c) end

	if same_direction(acd, ao) then return solve_triangle(simplex, a, c, d) end

	if same_direction(adb, ao) then return solve_triangle(simplex, a, d, b) end

	return true, simplex, nil
end

local function build_epa_face(vertices, ia, ib, ic)
	local a = vertices[ia]
	local b = vertices[ib]
	local c = vertices[ic]
	local normal = (b.point - a.point):GetCross(c.point - a.point)
	local length = normal:GetLength()

	if length <= EPA_FACE_EPSILON then return nil end

	normal = normal / length
	local distance = normal:Dot(a.point)

	if distance < 0 then
		normal = normal * -1
		distance = -distance
		ib, ic = ic, ib
	end

	return {
		a = ia,
		b = ib,
		c = ic,
		normal = normal,
		distance = distance,
	}
end

local function add_edge(edges, edge_rows, a, b)
	local reverse_row = edge_rows[b]
	local reverse_index = reverse_row and reverse_row[a] or nil

	if reverse_index then
		edges[reverse_index] = false
		reverse_row[a] = nil
		return
	end

	local row = edge_rows[a]

	if not row then
		row = {}
		edge_rows[a] = row
	end

	local index = #edges + 1
	edges[index] = {a, b}
	row[b] = index
end

local function compact_edges(edges)
	local write_index = 1

	for read_index = 1, #edges do
		local edge = edges[read_index]

		if edge then
			edges[write_index] = edge
			write_index = write_index + 1
		end
	end

	clear_array(edges, write_index)
	return edges
end

local function compact_faces(faces, visible_faces)
	local write_index = 1

	for read_index = 1, #faces do
		if not visible_faces[read_index] then
			faces[write_index] = faces[read_index]
			write_index = write_index + 1
		end
	end

	clear_array(faces, write_index)
	return faces
end

local function get_closest_face(faces)
	local best_face = nil
	local best_index = nil
	local best_distance = math.huge

	for i = 1, #faces do
		local face = faces[i]

		if face and face.distance < best_distance then
			best_distance = face.distance
			best_face = face
			best_index = i
		end
	end

	return best_face, best_index
end

local function get_triangle_barycentric(point, a, b, c)
	local v0 = b - a
	local v1 = c - a
	local v2 = point - a
	local d00 = v0:Dot(v0)
	local d01 = v0:Dot(v1)
	local d11 = v1:Dot(v1)
	local d20 = v2:Dot(v0)
	local d21 = v2:Dot(v1)
	local denominator = d00 * d11 - d01 * d01

	if math.abs(denominator) <= EPSILON then return 1 / 3, 1 / 3, 1 / 3 end

	local v = (d11 * d20 - d01 * d21) / denominator
	local w = (d00 * d21 - d01 * d20) / denominator
	return 1 - v - w, v, w
end

local function get_face_witness(vertices, face)
	local a = vertices[face.a]
	local b = vertices[face.b]
	local c = vertices[face.c]
	local closest_point = face.normal * face.distance
	local wa, wb, wc = get_triangle_barycentric(closest_point, a.point, b.point, c.point)
	local point_a = a.point_a * wa + b.point_a * wb + c.point_a * wc
	local point_b = a.point_b * wa + b.point_b * wb + c.point_b * wc
	return point_a, point_b
end

local function simplex_contains_support(simplex, support)
	for i = 1, #simplex do
		if (simplex[i].point - support.point):GetLength() <= EPSILON then return true end
	end

	return false
end

local function combine_simplex_witness(simplex, weights)
	local point_a = Vec3(0, 0, 0)
	local point_b = Vec3(0, 0, 0)

	for i = 1, #weights do
		local weight = weights[i]

		if weight and weight > 0 then
			point_a = point_a + simplex[i].point_a * weight
			point_b = point_b + simplex[i].point_b * weight
		end
	end

	return point_a, point_b
end

local function rebuild_simplex_from_weights(simplex, weights)
	local compact = {}

	for i = 1, #weights do
		if (weights[i] or 0) > EPSILON then compact[#compact + 1] = simplex[i] end
	end

	if not compact[1] then compact[1] = simplex[1] end

	for i = 1, #compact do
		simplex[i] = compact[i]
	end

	clear_array(simplex, #compact + 1)
	return simplex
end

local function get_segment_closest_to_origin(a, b)
	local ab = b - a
	local denominator = ab:Dot(ab)

	if denominator <= EPSILON then return a, {1, 0} end

	local t = math.clamp(-a:Dot(ab) / denominator, 0, 1)
	return a + ab * t, {1 - t, t}
end

local function get_triangle_closest_to_origin(a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = a * -1
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a, {1, 0, 0} end

	local bp = b * -1
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b, {0, 1, 0} end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v, {1 - v, v, 0}
	end

	local cp = c * -1
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c, {0, 0, 1} end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w, {1 - w, 0, w}
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w, {0, 1 - w, w}
	end

	local denominator = 1 / (va + vb + vc)
	local v = vb * denominator
	local w = vc * denominator
	return a + ab * v + ac * w, {1 - v - w, v, w}
end

local function get_distance_simplex_closest(simplex)
	if #simplex == 1 then return simplex[1].point, {1} end

	if #simplex == 2 then
		return get_segment_closest_to_origin(simplex[1].point, simplex[2].point)
	end

	return get_triangle_closest_to_origin(simplex[1].point, simplex[2].point, simplex[3].point)
end

local function try_add_support(simplex, vertices_a, vertices_b, direction)
	if direction:GetLength() <= EPSILON then return false end

	local support = get_support(vertices_a, vertices_b, direction)

	if not support or simplex_contains_support(simplex, support) then
		return false
	end

	simplex[#simplex + 1] = support
	return true
end

local function expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
	if #simplex >= 4 then return true end

	if #simplex == 3 then
		local normal = (simplex[2].point - simplex[1].point):GetCross(simplex[3].point - simplex[1].point)

		if normal:GetLength() <= EPSILON then
			normal = get_any_perpendicular(simplex[2].point - simplex[1].point)
		end

		return try_add_support(simplex, vertices_a, vertices_b, normal) or
			try_add_support(simplex, vertices_a, vertices_b, normal * -1)
	end

	if #simplex == 2 then
		local edge = simplex[2].point - simplex[1].point
		local perpendicular = get_any_perpendicular(edge)

		if
			try_add_support(simplex, vertices_a, vertices_b, perpendicular) or
			try_add_support(simplex, vertices_a, vertices_b, perpendicular * -1)
		then
			return expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
		end

		return false
	end

	if #simplex == 1 then
		local directions = {
			Vec3(1, 0, 0),
			Vec3(0, 1, 0),
			Vec3(0, 0, 1),
			Vec3(-1, 0, 0),
			Vec3(0, -1, 0),
			Vec3(0, 0, -1),
		}

		for i = 1, #directions do
			if try_add_support(simplex, vertices_a, vertices_b, directions[i]) then
				break
			end
		end

		if #simplex == 1 then return false end

		return expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
	end

	return false
end

function gjk_epa.Intersect(vertices_a, vertices_b, options)
	options = options or {}

	if not (vertices_a and vertices_a[1] and vertices_b and vertices_b[1]) then
		return nil
	end

	local simplex = options.simplex or {}
	clear_array(simplex)
	local initial_direction = options.initial_direction or
		(
			get_vertices_centroid(vertices_b) - get_vertices_centroid(vertices_a)
		)
	local direction = initial_direction

	if direction:GetLength() <= EPSILON then direction = Vec3(1, 0, 0) end

	local support = get_support(vertices_a, vertices_b, direction)

	if not support then return nil end

	simplex[1] = support
	direction = support.point * -1

	if direction:GetLength() <= EPSILON then
		direction = initial_direction:GetLength() > EPSILON and initial_direction or Vec3(0, 1, 0)
	end

	for iteration = 1, options.gjk_max_iterations or GJK_MAX_ITERATIONS do
		support = get_support(vertices_a, vertices_b, direction)

		if not support then return nil end

		if support.point:Dot(direction) <= EPSILON then
			return {
				intersect = false,
				simplex = simplex,
				iterations = iteration,
			}
		end

		table.insert(simplex, 1, support)
		local contains_origin, updated_simplex, updated_direction = handle_simplex(simplex)
		simplex = updated_simplex or simplex

		if contains_origin then
			return {
				intersect = true,
				simplex = simplex,
				iterations = iteration,
			}
		end

		direction = updated_direction or direction

		if direction:GetLength() <= EPSILON then
			return {
				intersect = true,
				simplex = simplex,
				iterations = iteration,
			}
		end
	end

	return {
		intersect = false,
		simplex = simplex,
		iterations = options.gjk_max_iterations or GJK_MAX_ITERATIONS,
	}
end

function gjk_epa.Penetration(vertices_a, vertices_b, options)
	options = options or {}
	local gjk_result = gjk_epa.Intersect(vertices_a, vertices_b, options)

	if not gjk_result then return nil end

	if not (gjk_result.intersect and gjk_result.simplex) then
		local distance_result = gjk_epa.Distance(
			vertices_a,
			vertices_b,
			{
				initial_direction = options.initial_direction,
				gjk_max_iterations = options.gjk_max_iterations,
			}
		)

		if
			not distance_result or
			(
				not distance_result.intersect and
				(
					distance_result.distance or
					math.huge
				) > EPSILON
			)
		then
			return {
				intersect = false,
				gjk = gjk_result,
				distance = distance_result,
			}
		end

		gjk_result = {
			intersect = true,
			simplex = distance_result.simplex or gjk_result.simplex,
			iterations = gjk_result.iterations,
		}
	end

	if
		not gjk_result.simplex[4] and
		not expand_simplex_to_tetrahedron(gjk_result.simplex, vertices_a, vertices_b)
	then
		return {
			intersect = false,
			gjk = gjk_result,
		}
	end

	local vertices = {}

	for i = 1, 4 do
		vertices[i] = gjk_result.simplex[i]
	end

	local faces = {
		build_epa_face(vertices, 1, 2, 3),
		build_epa_face(vertices, 1, 3, 4),
		build_epa_face(vertices, 1, 4, 2),
		build_epa_face(vertices, 2, 4, 3),
	}

	for i = #faces, 1, -1 do
		if not faces[i] then table.remove(faces, i) end
	end

	if not faces[1] then
		return {
			intersect = false,
			gjk = gjk_result,
		}
	end

	for iteration = 1, options.epa_max_iterations or EPA_MAX_ITERATIONS do
		if
			#faces > (
				options.epa_max_faces or
				EPA_MAX_FACES
			)
			or
			#vertices > (
				options.epa_max_vertices or
				EPA_MAX_VERTICES
			)
		then
			break
		end

		local face = get_closest_face(faces)

		if not face then break end

		local support = get_support(vertices_a, vertices_b, face.normal)

		if not support then break end

		local support_distance = support.point:Dot(face.normal)

		if
			support_distance - face.distance <= (
				options.epa_convergence_epsilon or
				EPA_CONVERGENCE_EPSILON
			)
		then
			local point_a, point_b = get_face_witness(vertices, face)
			return {
				intersect = true,
				normal = face.normal,
				depth = face.distance,
				point_a = point_a,
				point_b = point_b,
				gjk = gjk_result,
				iterations = iteration,
			}
		end

		local visible_faces = {}
		local border_edges = {}
		local border_edge_rows = {}

		for i = #faces, 1, -1 do
			local candidate = faces[i]
			local candidate_vertex = vertices[candidate.a]

			if
				candidate.normal:Dot(support.point - candidate_vertex.point) > (
					options.epa_face_epsilon or
					EPA_FACE_EPSILON
				)
			then
				visible_faces[i] = true
				add_edge(border_edges, border_edge_rows, candidate.a, candidate.b)
				add_edge(border_edges, border_edge_rows, candidate.b, candidate.c)
				add_edge(border_edges, border_edge_rows, candidate.c, candidate.a)
			end
		end

		compact_faces(faces, visible_faces)
		compact_edges(border_edges)

		if not border_edges[1] then break end

		local new_index = #vertices + 1
		vertices[new_index] = support

		for i = 1, #border_edges do
			local edge = border_edges[i]
			local new_face = build_epa_face(vertices, edge[1], edge[2], new_index)

			if new_face then faces[#faces + 1] = new_face end
		end
	end

	local fallback_face = get_closest_face(faces)

	if not fallback_face then
		return {
			intersect = false,
			gjk = gjk_result,
		}
	end

	local point_a, point_b = get_face_witness(vertices, fallback_face)
	return {
		intersect = true,
		normal = fallback_face.normal,
		depth = fallback_face.distance,
		point_a = point_a,
		point_b = point_b,
		gjk = gjk_result,
	}
end

function gjk_epa.Distance(vertices_a, vertices_b, options)
	options = options or {}

	if not (vertices_a and vertices_a[1] and vertices_b and vertices_b[1]) then
		return nil
	end

	local simplex = options.simplex or {}
	clear_array(simplex)
	local initial_direction = options.initial_direction or
		(
			get_vertices_centroid(vertices_b) - get_vertices_centroid(vertices_a)
		)
	local direction = initial_direction

	if direction:GetLength() <= EPSILON then direction = Vec3(1, 0, 0) end

	local support = get_support(vertices_a, vertices_b, direction)

	if not support then return nil end

	simplex[1] = support
	local closest = support.point
	local weights = {1}

	for iteration = 1, options.gjk_max_iterations or GJK_MAX_ITERATIONS do
		local distance = closest:GetLength()

		if distance <= EPSILON then
			local point_a, point_b = combine_simplex_witness(simplex, weights)
			return {
				intersect = true,
				distance = 0,
				delta = Vec3(0, 0, 0),
				point_a = point_a,
				point_b = point_b,
				normal = nil,
				simplex = simplex,
				iterations = iteration,
			}
		end

		direction = (closest * -1) / distance
		support = get_support(vertices_a, vertices_b, direction)

		if not support or simplex_contains_support(simplex, support) then break end

		local support_distance = support.point:Dot(direction)

		if
			support_distance - distance <= (
				options.distance_epsilon or
				EPA_CONVERGENCE_EPSILON
			)
		then
			break
		end

		table.insert(simplex, 1, support)

		if #simplex >= 4 then
			local contains_origin, updated_simplex = handle_simplex(simplex)
			simplex = updated_simplex or simplex

			if contains_origin then
				local point_a, point_b = combine_simplex_witness(simplex, {1, 0, 0, 0})
				return {
					intersect = true,
					distance = 0,
					delta = Vec3(0, 0, 0),
					point_a = point_a,
					point_b = point_b,
					normal = nil,
					simplex = simplex,
					iterations = iteration,
				}
			end
		end

		closest, weights = get_distance_simplex_closest(simplex)
		rebuild_simplex_from_weights(simplex, weights)
		closest, weights = get_distance_simplex_closest(simplex)
	end

	local point_a, point_b = combine_simplex_witness(simplex, weights)
	local delta = point_b - point_a
	local normal = delta:GetLength() > EPSILON and delta:GetNormalized() or nil
	return {
		intersect = false,
		distance = delta:GetLength(),
		delta = delta,
		point_a = point_a,
		point_b = point_b,
		normal = normal,
		simplex = simplex,
	}
end

return gjk_epa
