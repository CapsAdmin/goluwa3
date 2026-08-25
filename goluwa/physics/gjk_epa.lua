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
-- shared temporaries: GJK/EPA runs sequentially and every temporary is fully
-- consumed before the code path that reuses it
local TEMP_A = Vec3()
local TEMP_B = Vec3()
local TEMP_C = Vec3()
local TEMP_D = Vec3()
local TEMP_E = Vec3()
local TEMP_F = Vec3()
local TEMP_NEG = Vec3()
local TEMP_DIFF = Vec3()
local AXIS_X = Vec3(1, 0, 0)
local AXIS_Y = Vec3(0, 1, 0)
local AXIS_Z = Vec3(0, 0, 1)
local SUPPORT_DIRECTIONS = {
	Vec3(1, 0, 0),
	Vec3(0, 1, 0),
	Vec3(0, 0, 1),
	Vec3(-1, 0, 0),
	Vec3(0, -1, 0),
	Vec3(0, 0, -1),
}

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

local function get_vertices_centroid(vertices, out)
	out = out or Vec3(0, 0, 0)
	out:Zero()
	local count = #vertices

	for i = 1, count do
		out:Add(vertices[i])
	end

	if count == 0 then return out end

	out:Scale(1 / count)
	return out
end

local function get_any_perpendicular(direction)
	local axis = math.abs(direction.x) < 0.577 and
		AXIS_X or
		math.abs(direction.y) < 0.577 and
		AXIS_Y or
		AXIS_Z
	-- TEMP_D is dedicated here: direction may alias TEMP_A/B/C at the call sites
	Vec3.SetCross(TEMP_D, direction, axis)

	if TEMP_D:GetLength() <= EPSILON then
		axis = axis.x == 0 and AXIS_X or AXIS_Y
		Vec3.SetCross(TEMP_D, direction, axis)
	end

	if TEMP_D:GetLength() <= EPSILON then return AXIS_X end

	TEMP_D:Normalize()
	return TEMP_D
end

local function get_perpendicular_towards(edge, toward)
	Vec3.SetCross(TEMP_B, edge, toward)
	Vec3.SetCross(TEMP_C, TEMP_B, edge)

	if TEMP_C:GetLength() <= EPSILON then return get_any_perpendicular(edge) end

	return TEMP_C
end

local function same_direction(direction, toward)
	return direction:Dot(toward) > 0
end

local function get_farthest_vertex(vertices, direction)
	local best_index = nil
	local best_projection = -math.huge

	for i = 1, #vertices do
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

local function make_support_slot()
	return {
		point = Vec3(),
		point_a = nil,
		point_b = nil,
		index_a = nil,
		index_b = nil,
	}
end

-- GJK simplexes hold at most 4 supports, so support tables are pooled in
-- fixed slots owned by the simplex instead of being allocated per
-- iteration. A slot is free when no entry of its simplex references it;
-- the pool holds 5 slots so a free slot always exists.
local function get_simplex_slots(simplex)
	local slots = simplex._slots

	if slots then return slots end

	slots = {}

	for i = 1, 5 do
		slots[i] = make_support_slot()
	end

	simplex._slots = slots
	return slots
end

local function get_support_slot(simplex)
	local slots = get_simplex_slots(simplex)

	for i = 1, 5 do
		local slot = slots[i]
		local taken = false

		for j = 1, #simplex do
			if simplex[j] == slot then
				taken = true

				break
			end
		end

		if not taken then return slot end
	end

	return make_support_slot()
end

local function get_support(vertices_a, vertices_b, direction, simplex)
	local point_a, index_a = get_farthest_vertex(vertices_a, direction)
	local point_b, index_b = get_farthest_vertex(vertices_b, direction * -1)

	if not (point_a and point_b) then return nil end

	local support

	if simplex then
		support = get_support_slot(simplex)
	else
		support = make_support_slot()
	end

	Vec3.SetSub(support.point, point_a, point_b)
	support.point_a = point_a
	support.point_b = point_b
	support.index_a = index_a
	support.index_b = index_b
	return support
end

local function solve_line(simplex, a, b)
	local ao = TEMP_NEG:CopyFrom(a.point):Scale(-1)
	local ab = Vec3.SetSub(TEMP_A, b.point, a.point)

	if same_direction(ab, ao) then
		return false, set_simplex(simplex, b, a), get_perpendicular_towards(ab, ao)
	end

	return false, set_simplex(simplex, a), ao
end

local function solve_triangle(simplex, a, b, c)
	local ao = TEMP_NEG:CopyFrom(a.point):Scale(-1)
	local ab = Vec3.SetSub(TEMP_A, b.point, a.point)
	local ac = Vec3.SetSub(TEMP_B, c.point, a.point)
	local abc = Vec3.SetCross(TEMP_C, ab, ac)
	local ab_perpendicular = Vec3.SetCross(TEMP_D, ab, abc)

	if same_direction(ab_perpendicular, ao) then
		return solve_line(simplex, a, b)
	end

	local ac_perpendicular = Vec3.SetCross(TEMP_E, abc, ac)

	if same_direction(ac_perpendicular, ao) then
		return solve_line(simplex, a, c)
	end

	if same_direction(abc, ao) then
		return false, set_simplex(simplex, c, b, a), abc
	end

	TEMP_NEG:CopyFrom(abc):Scale(-1)
	return false, set_simplex(simplex, b, c, a), TEMP_NEG
end

local function handle_simplex(simplex)
	local count = #simplex

	if count == 1 then
		return false, TEMP_NEG:CopyFrom(simplex[1].point):Scale(-1)
	end

	if count == 2 then return solve_line(simplex, simplex[2], simplex[1]) end

	if count == 3 then
		return solve_triangle(simplex, simplex[3], simplex[2], simplex[1])
	end

	local a = simplex[4]
	local b = simplex[3]
	local c = simplex[2]
	local d = simplex[1]
	local ao = TEMP_NEG:CopyFrom(a.point):Scale(-1)
	local ab = Vec3.SetSub(TEMP_A, b.point, a.point)
	local ac = Vec3.SetSub(TEMP_B, c.point, a.point)
	local ad = Vec3.SetSub(TEMP_C, d.point, a.point)
	local abc = Vec3.SetCross(TEMP_D, ab, ac)
	local acd = Vec3.SetCross(TEMP_E, ac, ad)
	local adb = Vec3.SetCross(TEMP_F, ad, ab)

	if abc:Dot(ad) > 0 then abc:Scale(-1) end

	if acd:Dot(ab) > 0 then acd:Scale(-1) end

	if adb:Dot(ac) > 0 then adb:Scale(-1) end

	if same_direction(abc, ao) then return solve_triangle(simplex, a, b, c) end

	if same_direction(acd, ao) then return solve_triangle(simplex, a, c, d) end

	if same_direction(adb, ao) then return solve_triangle(simplex, a, d, b) end

	return true, simplex, nil
end

local function build_epa_face(vertices, ia, ib, ic)
	local a = vertices[ia]
	local b = vertices[ib]
	local c = vertices[ic]
	Vec3.SetSub(TEMP_A, b.point, a.point)
	Vec3.SetSub(TEMP_B, c.point, a.point)
	local normal = Vec3.SetCross(TEMP_C, TEMP_A, TEMP_B)
	local length = normal:GetLength()

	if length <= EPA_FACE_EPSILON then return nil end

	normal:Scale(1 / length)
	local distance = normal:Dot(a.point)

	if distance < 0 then
		normal:Scale(-1)
		distance = -distance
		ib, ic = ic, ib
	end

	-- face tables outlive this call, so the normal is owned by the face
	return {
		a = ia,
		b = ib,
		c = ic,
		normal = normal:Copy(),
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
	local v0 = Vec3.SetSub(TEMP_A, b, a)
	local v1 = Vec3.SetSub(TEMP_B, c, a)
	local v2 = Vec3.SetSub(TEMP_C, point, a)
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
	local closest_point = TEMP_D:CopyFrom(face.normal):Scale(face.distance)
	local wa, wb, wc = get_triangle_barycentric(closest_point, a.point, b.point, c.point)
	-- witnesses are stored in the result, so they are owned vecs
	local point_a = Vec3()
	local point_b = Vec3()
	point_a:AddScaled(a.point_a, wa)
	point_a:AddScaled(b.point_a, wb)
	point_a:AddScaled(c.point_a, wc)
	point_b:AddScaled(a.point_b, wa)
	point_b:AddScaled(b.point_b, wb)
	point_b:AddScaled(c.point_b, wc)
	return point_a, point_b
end

local function simplex_contains_support(simplex, support)
	for i = 1, #simplex do
		if Vec3.SetSub(TEMP_DIFF, simplex[i].point, support.point):GetLength() <= EPSILON then
			return true
		end
	end

	return false
end

local function combine_simplex_witness(simplex, weights)
	local point_a = Vec3(0, 0, 0)
	local point_b = Vec3(0, 0, 0)

	for i = 1, #weights do
		local weight = weights[i]

		if weight and weight > 0 then
			point_a:AddScaled(simplex[i].point_a, weight)
			point_b:AddScaled(simplex[i].point_b, weight)
		end
	end

	return point_a, point_b
end

local function rebuild_simplex_from_weights(simplex, weights)
	local write_index = 0

	for i = 1, #weights do
		if (weights[i] or 0) > EPSILON then
			write_index = write_index + 1
			simplex[write_index] = simplex[i]
		end
	end

	if write_index == 0 then write_index = 1 end

	clear_array(simplex, write_index + 1)
	return simplex
end

-- weight buffers are shared: distance queries run sequentially and weights
-- are only consumed within a single get_distance_simplex_closest call
local DISTANCE_WEIGHTS = {}

local function set_weights(w1, w2, w3)
	DISTANCE_WEIGHTS[1] = w1
	DISTANCE_WEIGHTS[2] = w2
	DISTANCE_WEIGHTS[3] = w3
	return DISTANCE_WEIGHTS
end

local function set_two_weights(w1, w2)
	DISTANCE_WEIGHTS[1] = w1
	DISTANCE_WEIGHTS[2] = w2
	DISTANCE_WEIGHTS[3] = nil
	return DISTANCE_WEIGHTS
end

local function get_segment_closest_to_origin(a, b)
	local ab = Vec3.SetSub(TEMP_A, b, a)
	local denominator = ab:Dot(ab)

	if denominator <= EPSILON then return a, set_two_weights(1, 0) end

	local t = math.clamp(-a:Dot(ab) / denominator, 0, 1)
	return TEMP_B:CopyFrom(a):AddScaled(ab, t), set_two_weights(1 - t, t)
end

local function get_triangle_closest_to_origin(a, b, c)
	local ab = Vec3.SetSub(TEMP_A, b, a)
	local ac = Vec3.SetSub(TEMP_C, c, a)
	local ap = TEMP_NEG:CopyFrom(a):Scale(-1)
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a, set_weights(1, 0, 0) end

	local bp = TEMP_NEG:CopyFrom(b):Scale(-1)
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b, set_weights(0, 1, 0) end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return TEMP_B:CopyFrom(a):AddScaled(ab, v), set_weights(1 - v, v, 0)
	end

	local cp = TEMP_NEG:CopyFrom(c):Scale(-1)
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c, set_weights(0, 0, 1) end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return TEMP_B:CopyFrom(a):AddScaled(ac, w), set_weights(1 - w, 0, w)
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		local bc = Vec3.SetSub(TEMP_C, c, b)
		return TEMP_B:CopyFrom(b):AddScaled(bc, w), set_weights(0, 1 - w, w)
	end

	local denominator = 1 / (va + vb + vc)
	local v = vb * denominator
	local w = vc * denominator
	return TEMP_B:CopyFrom(a):AddScaled(ab, v):AddScaled(ac, w),
	set_weights(1 - v - w, v, w)
end

local function get_distance_simplex_closest(simplex)
	if #simplex == 1 then return simplex[1].point, set_weights(1) end

	if #simplex == 2 then
		return get_segment_closest_to_origin(simplex[1].point, simplex[2].point)
	end

	return get_triangle_closest_to_origin(simplex[1].point, simplex[2].point, simplex[3].point)
end

local function try_add_support(simplex, vertices_a, vertices_b, direction)
	if direction:GetLength() <= EPSILON then return false end

	local support = get_support(vertices_a, vertices_b, direction, simplex)

	if not support or simplex_contains_support(simplex, support) then
		return false
	end

	simplex[#simplex + 1] = support
	return true
end

local function expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
	if #simplex >= 4 then return true end

	if #simplex == 3 then
		local ab = Vec3.SetSub(TEMP_A, simplex[2].point, simplex[1].point)
		local ac = Vec3.SetSub(TEMP_B, simplex[3].point, simplex[1].point)
		local normal = Vec3.SetCross(TEMP_C, ab, ac)

		if normal:GetLength() <= EPSILON then normal = get_any_perpendicular(ab) end

		return try_add_support(simplex, vertices_a, vertices_b, normal) or
			try_add_support(simplex, vertices_a, vertices_b, Vec3.SetScaled(TEMP_NEG, normal, -1))
	end

	if #simplex == 2 then
		local edge = Vec3.SetSub(TEMP_A, simplex[2].point, simplex[1].point)
		local perpendicular = get_any_perpendicular(edge)

		if
			try_add_support(simplex, vertices_a, vertices_b, perpendicular) or
			try_add_support(simplex, vertices_a, vertices_b, Vec3.SetScaled(TEMP_NEG, perpendicular, -1))
		then
			return expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
		end

		return false
	end

	if #simplex == 1 then
		for i = 1, #SUPPORT_DIRECTIONS do
			if try_add_support(simplex, vertices_a, vertices_b, SUPPORT_DIRECTIONS[i]) then
				break
			end
		end

		if #simplex == 1 then return false end

		return expand_simplex_to_tetrahedron(simplex, vertices_a, vertices_b)
	end

	return false
end

local DEFAULT_SIMPLEX = {}

function gjk_epa.Intersect(vertices_a, vertices_b, initial_direction, simplex)
	if not (vertices_a and vertices_a[1] and vertices_b and vertices_b[1]) then
		return nil
	end

	simplex = simplex or DEFAULT_SIMPLEX
	clear_array(simplex)

	if not initial_direction then
		local centroid_a = get_vertices_centroid(vertices_a, TEMP_A)
		local centroid_b = get_vertices_centroid(vertices_b, TEMP_B)
		initial_direction = Vec3.SetSub(TEMP_C, centroid_b, centroid_a)
	end

	local direction = initial_direction

	if direction:GetLength() <= EPSILON then direction = AXIS_X end

	local support = get_support(vertices_a, vertices_b, direction, simplex)

	if not support then return nil end

	simplex[1] = support
	direction = TEMP_NEG:CopyFrom(support.point):Scale(-1)

	if direction:GetLength() <= EPSILON then
		direction = initial_direction:GetLength() > EPSILON and initial_direction or AXIS_Y
	end

	for iteration = 1, GJK_MAX_ITERATIONS do
		support = get_support(vertices_a, vertices_b, direction, simplex)

		if not support then return nil end

		if support.point:Dot(direction) <= EPSILON then
			return {
				intersect = false,
				simplex = simplex,
				iterations = iteration,
			}
		end

		simplex[#simplex + 1] = support
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
		iterations = GJK_MAX_ITERATIONS,
	}
end

function gjk_epa.Penetration(vertices_a, vertices_b, initial_direction, simplex)
	local gjk_result = gjk_epa.Intersect(vertices_a, vertices_b, initial_direction, simplex)

	if not gjk_result then return nil end

	if not (gjk_result.intersect and gjk_result.simplex) then
		local distance_result = gjk_epa.Distance(vertices_a, vertices_b, initial_direction, gjk_result.simplex)

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

	for iteration = 1, EPA_MAX_ITERATIONS do
		if #faces > EPA_MAX_FACES or #vertices > EPA_MAX_VERTICES then break end

		local face = get_closest_face(faces)

		if not face then break end

		local support = get_support(vertices_a, vertices_b, face.normal)

		if not support then break end

		local support_distance = support.point:Dot(face.normal)

		if support_distance - face.distance <= EPA_CONVERGENCE_EPSILON then
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
			Vec3.SetSub(TEMP_DIFF, support.point, candidate_vertex.point)

			if candidate.normal:Dot(TEMP_DIFF) > EPA_FACE_EPSILON then
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

function gjk_epa.Distance(vertices_a, vertices_b, initial_direction, simplex)
	if not (vertices_a and vertices_a[1] and vertices_b and vertices_b[1]) then
		return nil
	end

	simplex = simplex or DEFAULT_SIMPLEX
	clear_array(simplex)

	if not initial_direction then
		local centroid_a = get_vertices_centroid(vertices_a, TEMP_A)
		local centroid_b = get_vertices_centroid(vertices_b, TEMP_B)
		initial_direction = Vec3.SetSub(TEMP_C, centroid_b, centroid_a)
	end

	local direction = initial_direction

	if direction:GetLength() <= EPSILON then direction = AXIS_X end

	local support = get_support(vertices_a, vertices_b, direction, simplex)

	if not support then return nil end

	simplex[1] = support
	local closest = support.point
	local weights = set_weights(1)

	for iteration = 1, GJK_MAX_ITERATIONS do
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

		direction = TEMP_NEG:CopyFrom(closest):Scale(-1 / distance)
		support = get_support(vertices_a, vertices_b, direction, simplex)

		if not support or simplex_contains_support(simplex, support) then break end

		local support_distance = support.point:Dot(direction)

		-- the closest point on the simplex is the true minimum distance only when
		-- the farthest support in the search direction does not extend past the
		-- hyperplane through the origin perpendicular to it: support.dot(u) <= -|c|
		if support_distance + distance <= EPA_CONVERGENCE_EPSILON then break end

		simplex[#simplex + 1] = support

		if #simplex >= 4 then
			local contains_origin, updated_simplex = handle_simplex(simplex)
			simplex = updated_simplex or simplex

			if contains_origin then
				local point_a, point_b = combine_simplex_witness(simplex, set_weights(1, 0, 0))
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
