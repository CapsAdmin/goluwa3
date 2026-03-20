local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_mesh = import("goluwa/physics/triangle_mesh.lua")
local triangle_contact_queries = import("goluwa/physics/triangle_contact_queries.lua")
local primitive_polygon_query = import("goluwa/physics/primitive_polygon_query.lua")
local mesh_surface_contact = {}
local MESH_FEATURE_EPSILON = 0.0001
local MESH_SEAM_DISTANCE_EPSILON = 0.0001
local MESH_SEAM_NORMAL_DOT = 0.5

local function get_hit_polygon(hit)
	if not (hit and hit.primitive) then return nil end

	return primitive_polygon_query.GetPrimitivePolygon(hit.primitive)
end

local function get_entity_world_matrix(entity)
	local transform = entity and entity.transform or nil
	return transform and transform.GetWorldMatrix and transform:GetWorldMatrix() or nil
end

local function get_polygon_feature_cache(poly)
	return triangle_mesh.GetPolygonFeatureCache(poly, MESH_FEATURE_EPSILON)
end

local function get_mesh_face_world_vertices(poly, face_index, world_matrix)
	local v0, v1, v2, i0, i1, i2 = triangle_mesh.GetPolygonTriangleLocalVertices(poly, face_index)

	if not (v0 and v1 and v2) then return nil end

	if world_matrix then
		v0 = world_matrix:TransformVector(v0)
		v1 = world_matrix:TransformVector(v1)
		v2 = world_matrix:TransformVector(v2)
	end

	return v0, v1, v2, i0, i1, i2
end

function mesh_surface_contact.GetHitFaceNormal(hit)
	if hit and hit.face_normal then return hit.face_normal end

	local poly = get_hit_polygon(hit)

	if not (hit and poly and hit.triangle_index ~= nil) then
		return hit and hit.normal or nil
	end

	local v0, v1, v2 = get_mesh_face_world_vertices(poly, hit.triangle_index, get_entity_world_matrix(hit.entity))

	if not (v0 and v1 and v2) then return hit.normal end

	return triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, MESH_FEATURE_EPSILON) or
		hit.normal
end

local function on_segment(a, b, point)
	local ab = b - a
	local length_squared = ab:Dot(ab)

	if length_squared <= MESH_FEATURE_EPSILON then return false end

	local t = (point - a):Dot(ab) / length_squared

	if t <= MESH_FEATURE_EPSILON or t >= 1 - MESH_FEATURE_EPSILON then
		return false
	end

	local projected = a + ab * t
	return (projected - point):GetLength() <= MESH_FEATURE_EPSILON
end

local function get_mesh_feature_indices(closest_point, v0, v1, v2, i0, i1, i2)
	if (closest_point - v0):GetLength() <= MESH_FEATURE_EPSILON then
		return "vertex", {i0}
	end

	if (closest_point - v1):GetLength() <= MESH_FEATURE_EPSILON then
		return "vertex", {i1}
	end

	if (closest_point - v2):GetLength() <= MESH_FEATURE_EPSILON then
		return "vertex", {i2}
	end

	if on_segment(v0, v1, closest_point) then return "edge", {i0, i1} end

	if on_segment(v1, v2, closest_point) then return "edge", {i1, i2} end

	if on_segment(v2, v0, closest_point) then return "edge", {i2, i0} end

	return "face", nil
end

local function get_mesh_feature_local_positions(poly, feature_indices)
	if not feature_indices then return nil end

	local cache = get_polygon_feature_cache(poly)

	if not cache then return nil end

	local positions = {}

	for _, index in ipairs(feature_indices) do
		local position = cache.local_vertices[index]

		if not position then return nil end

		positions[#positions + 1] = position
	end

	return positions
end

local function append_unique_normal(normals, candidate_normal)
	if not candidate_normal or candidate_normal:GetLength() <= MESH_FEATURE_EPSILON then
		return
	end

	for _, normal in ipairs(normals) do
		if normal:Dot(candidate_normal) >= 1 - MESH_FEATURE_EPSILON then return end
	end

	normals[#normals + 1] = candidate_normal
end

local function sum_candidate_normals(candidate_normals, fallback_normal)
	local summed_normal = Vec3(0, 0, 0)

	for _, normal in ipairs(candidate_normals) do
		if normal then summed_normal = summed_normal + normal end
	end

	if summed_normal:GetLength() <= MESH_FEATURE_EPSILON then
		return fallback_normal and fallback_normal:GetNormalized() or nil
	end

	return summed_normal:GetNormalized()
end

local function reset_best_face_candidate(state, position, face_normal, distance_squared)
	state.best_position = position
	state.best_face_normal = face_normal
	state.best_distance_squared = distance_squared
	state.candidate_normals = {}
	append_unique_normal(state.candidate_normals, face_normal)
end

local function build_face_search_state(best_position, best_face_normal, best_distance_squared)
	local state = {
		best_position = best_position,
		best_face_normal = best_face_normal,
		best_distance_squared = best_distance_squared or math.huge,
		candidate_normals = {},
	}
	append_unique_normal(state.candidate_normals, best_face_normal)
	return state
end

local function consider_face_candidate(state, reference_point, v0, v1, v2, face_normal)
	local separation = triangle_contact_queries.GetPointTriangleSeparation(reference_point, v0, v1, v2, {
		epsilon = MESH_FEATURE_EPSILON,
	})
	local candidate_position = separation and separation.position or nil

	if not candidate_position then return end

	local delta = reference_point - candidate_position
	local distance_squared = delta:Dot(delta)
	face_normal = face_normal or separation.face_normal

	if distance_squared + MESH_SEAM_DISTANCE_EPSILON < state.best_distance_squared then
		reset_best_face_candidate(state, candidate_position, face_normal, distance_squared)
	elseif
		math.abs(distance_squared - state.best_distance_squared) <= MESH_SEAM_DISTANCE_EPSILON
	then
		append_unique_normal(state.candidate_normals, face_normal)
	end
end

local function consider_seam_face_candidate(state, reference_point, primary_face_normal, v0, v1, v2)
	local candidate_face_normal = triangle_contact_queries.GetTriangleFaceNormal(v0, v1, v2, MESH_FEATURE_EPSILON)

	if not (candidate_face_normal and primary_face_normal) then return end

	if primary_face_normal:Dot(candidate_face_normal) < MESH_SEAM_NORMAL_DOT then
		return
	end

	consider_face_candidate(state, reference_point, v0, v1, v2, candidate_face_normal)
end

local function finalize_surface_contact(hit, reference_point, position, surface_normal)
	if not (reference_point and position) then return nil end

	local delta = reference_point - position
	local distance = delta:GetLength()
	local normal = distance > 0.00001 and (delta / distance) or surface_normal

	if not normal or normal:GetLength() <= 0.00001 then return nil end

	if hit and hit.normal then
		if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
	elseif (reference_point - position):Dot(normal) < 0 then
		normal = normal * -1
	end

	return {
		position = position,
		normal = normal,
	}
end

local function get_polygon_closest_contact(poly, world_matrix, hit, reference_point)
	if not (poly and reference_point) then return nil end

	local cache = get_polygon_feature_cache(poly)
	local face_count = cache and cache.face_count or 0

	if face_count <= 0 then return nil end

	local state = build_face_search_state(nil, nil, math.huge)

	for face_index = 0, face_count - 1 do
		local v0, v1, v2 = get_mesh_face_world_vertices(poly, face_index, world_matrix)

		if v0 and v1 and v2 then
			consider_face_candidate(state, reference_point, v0, v1, v2)
		end
	end

	if not state.best_position then return nil end

	return finalize_surface_contact(
		hit,
		reference_point,
		state.best_position,
		sum_candidate_normals(state.candidate_normals, state.best_face_normal)
	)
end

local function iterate_matching_feature_faces(poly, world_matrix, feature_indices, callback, skip_face_index)
	if not feature_indices then return end

	local cache = get_polygon_feature_cache(poly)

	if not cache then return end

	local matches = nil

	for _, feature_index in ipairs(feature_indices) do
		local face_indices = cache.faces_by_vertex_index[feature_index]

		if not face_indices then return end

		if not matches then
			matches = {}

			for i = 1, #face_indices do
				matches[face_indices[i]] = true
			end
		else
			local next_matches = {}

			for i = 1, #face_indices do
				local face_index = face_indices[i]

				if matches[face_index] then next_matches[face_index] = true end
			end

			matches = next_matches
		end
	end

	for face_index in pairs(matches or {}) do
		if face_index ~= skip_face_index then
			local v0, v1, v2 = get_mesh_face_world_vertices(poly, face_index, world_matrix)

			if v0 and v1 and v2 then callback(v0, v1, v2, face_index) end
		end
	end
end

local function iterate_matching_feature_position_faces(poly, world_matrix, local_feature_positions, callback)
	if not local_feature_positions then return end

	local cache = get_polygon_feature_cache(poly)

	if not cache then return end

	local matches = {}

	for _, position in ipairs(local_feature_positions) do
		local face_indices = cache.faces_by_position_key[triangle_mesh.GetFeaturePositionKey(position, MESH_FEATURE_EPSILON)]

		if face_indices then
			for i = 1, #face_indices do
				matches[face_indices[i]] = true
			end
		end
	end

	for face_index in pairs(matches) do
		local v0, v1, v2 = get_mesh_face_world_vertices(poly, face_index, world_matrix)

		if v0 and v1 and v2 then callback(v0, v1, v2, face_index) end
	end
end

local function get_mesh_hit_feature_contact(hit, reference_point)
	local poly = get_hit_polygon(hit)
	local world_matrix = get_entity_world_matrix(hit and hit.entity)

	if not (reference_point and hit and poly and hit.triangle_index ~= nil) then
		return nil
	end

	local v0, v1, v2, i0, i1, i2 = get_mesh_face_world_vertices(poly, hit.triangle_index, world_matrix)

	if not (v0 and v1 and v2 and i0 and i1 and i2) then return nil end

	local primary_face_normal = mesh_surface_contact.GetHitFaceNormal(hit)
	local primary_separation = triangle_contact_queries.GetPointTriangleSeparation(reference_point, v0, v1, v2, {
		epsilon = MESH_FEATURE_EPSILON,
	})
	local primary_closest_point = primary_separation and primary_separation.position or nil

	if not primary_closest_point then return nil end

	local feature_kind, feature_indices = get_mesh_feature_indices(primary_closest_point, v0, v1, v2, i0, i1, i2)
	local local_feature_positions = get_mesh_feature_local_positions(poly, feature_indices)
	local state = build_face_search_state(
		primary_closest_point,
		primary_face_normal,
		(
			reference_point - primary_closest_point
		):Dot(reference_point - primary_closest_point)
	)

	if feature_kind == "face" or not feature_indices then
		return finalize_surface_contact(hit, reference_point, state.best_position, primary_face_normal)
	end

	iterate_matching_feature_faces(
		poly,
		world_matrix,
		feature_indices,
		function(av0, av1, av2)
			consider_seam_face_candidate(state, reference_point, primary_face_normal, av0, av1, av2)
		end,
		hit.triangle_index
	)

	local model = hit.model

	if model and model.Primitives and local_feature_positions then
		for _, primitive in ipairs(model.Primitives) do
			local primitive_poly = primitive_polygon_query.GetPrimitivePolygon(primitive)

			if primitive ~= hit.primitive and primitive_poly then
				iterate_matching_feature_position_faces(
					primitive_poly,
					world_matrix,
					local_feature_positions,
					function(av0, av1, av2)
						consider_seam_face_candidate(state, reference_point, primary_face_normal, av0, av1, av2)
					end
				)
			end
		end
	end

	return finalize_surface_contact(
		hit,
		reference_point,
		state.best_position,
		sum_candidate_normals(state.candidate_normals, state.best_face_normal)
	)
end

function mesh_surface_contact.GetHitSurfaceContact(hit, reference_point)
	local contact = get_mesh_hit_feature_contact(hit, reference_point)

	if contact then return contact end

	if not hit then return nil end

	local world_matrix = get_entity_world_matrix(hit and hit.entity)
	return get_polygon_closest_contact(get_hit_polygon(hit), world_matrix, hit, reference_point) or
		finalize_surface_contact(
			hit,
			reference_point or hit.position,
			hit.position,
			mesh_surface_contact.GetHitFaceNormal(hit)
		)
end

return mesh_surface_contact
