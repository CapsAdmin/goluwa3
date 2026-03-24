local AABB = import("goluwa/structs/aabb.lua")
local BVH = import("goluwa/physics/bvh.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_mesh = {}
local TRIANGLE_BVH_THRESHOLD = 24
local TRIANGLE_BVH_LEAF_COUNT = 8

local function get_polygon_cache(poly)
	if not poly then return nil end

	local cache = poly.triangle_mesh_cache

	if cache then return cache end

	cache = {}
	poly.triangle_mesh_cache = cache
	return cache
end

local function get_polygon_vertices(poly)
	if not (poly and poly.Vertices) then return nil, 0 end

	local vertices = poly.Vertices
	return vertices, #vertices
end

local function get_polygon_triangle_sources(poly)
	local vertices, vertex_count = get_polygon_vertices(poly)

	if not vertices then return nil end

	local local_vertices = triangle_mesh.GetPolygonLocalVertices(poly)
	local indices, triangle_count = triangle_mesh.GetPolygonIndexBuffer(poly)
	local index_count = indices and #indices or 0

	if not (local_vertices and indices) then return nil end

	return {
		vertices = vertices,
		vertex_count = vertex_count,
		local_vertices = local_vertices,
		indices = indices,
		index_count = index_count,
		triangle_count = triangle_count,
	}
end

local function build_triangle_record(triangle_index, v0, v1, v2)
	return {
		triangle_index = triangle_index,
		v0 = v0,
		v1 = v1,
		v2 = v2,
		min_x = math.min(v0.x, v1.x, v2.x),
		min_y = math.min(v0.y, v1.y, v2.y),
		min_z = math.min(v0.z, v1.z, v2.z),
		max_x = math.max(v0.x, v1.x, v2.x),
		max_y = math.max(v0.y, v1.y, v2.y),
		max_z = math.max(v0.z, v1.z, v2.z),
		centroid_x = (v0.x + v1.x + v2.x) / 3,
		centroid_y = (v0.y + v1.y + v2.y) / 3,
		centroid_z = (v0.z + v1.z + v2.z) / 3,
	}
end

local function bounds_from_points(points)
	if not (points and points[1]) then return nil end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		if point then bounds:ExpandVec3(point) end
	end

	return bounds
end

function triangle_mesh.GetVertexPosition(vertex)
	if not vertex then return nil end

	if vertex.pos then vertex = vertex.pos end

	if vertex.x and vertex.y and vertex.z then
		return Vec3(vertex.x, vertex.y, vertex.z)
	end

	if vertex[1] and vertex[2] and vertex[3] then
		return Vec3(vertex[1], vertex[2], vertex[3])
	end

	return nil
end

function triangle_mesh.GetPolygonLocalVertices(poly)
	local vertices, vertex_count = get_polygon_vertices(poly)

	if not vertices then return nil, 0 end

	local cache = get_polygon_cache(poly)
	local local_vertices_cache = cache.local_vertices

	if
		local_vertices_cache and
		local_vertices_cache.source == vertices and
		local_vertices_cache.count == vertex_count
	then
		return local_vertices_cache.value, vertex_count
	end

	local local_vertices = {}

	for i = 1, vertex_count do
		local_vertices[i] = triangle_mesh.GetVertexPosition(vertices[i])
	end

	cache.local_vertices = {
		value = local_vertices,
		source = vertices,
		count = vertex_count,
	}
	return local_vertices, vertex_count
end

function triangle_mesh.GetPolygonIndexBuffer(poly)
	local vertices, vertex_count = get_polygon_vertices(poly)

	if not vertices then return nil, 0 end

	if poly.indices then return poly.indices, math.floor(#poly.indices / 3) end

	local triangle_count = math.floor(vertex_count / 3)
	local cache = get_polygon_cache(poly)
	local index_buffer_cache = cache.index_buffer

	if index_buffer_cache and index_buffer_cache.count == vertex_count then
		return index_buffer_cache.value, triangle_count
	end

	local sequential = {}

	for i = 1, vertex_count do
		sequential[i] = i - 1
	end

	cache.index_buffer = {
		value = sequential,
		count = vertex_count,
	}
	return sequential, triangle_count
end

function triangle_mesh.GetPolygonLocalBounds(poly)
	local vertices, vertex_count = get_polygon_vertices(poly)

	if not vertices then return nil end

	local cache = get_polygon_cache(poly)
	local bounds_cache = cache.local_bounds

	if
		bounds_cache and
		bounds_cache.source == vertices and
		bounds_cache.count == vertex_count
	then
		return bounds_cache.value
	end

	local bounds = poly.GetAABB and poly:GetAABB() or poly.AABB

	if not bounds then
		local points = triangle_mesh.GetPolygonLocalVertices(poly)
		bounds = bounds_from_points(points)
	end

	cache.local_bounds = {
		value = bounds,
		source = vertices,
		count = vertex_count,
	}
	return bounds
end

function triangle_mesh.GetPolygonTriangleIndices(poly, triangle_index)
	if triangle_index == nil then return nil end

	local indices = triangle_mesh.GetPolygonIndexBuffer(poly)

	if not indices then return nil end

	local base = triangle_index * 3
	return indices[base + 1] + 1, indices[base + 2] + 1, indices[base + 3] + 1
end

function triangle_mesh.GetPolygonTriangleLocalVertices(poly, triangle_index)
	local local_vertices = triangle_mesh.GetPolygonLocalVertices(poly)
	local i0, i1, i2 = triangle_mesh.GetPolygonTriangleIndices(poly, triangle_index)

	if not (local_vertices and i0 and i1 and i2) then return nil end

	local v0 = local_vertices[i0]
	local v1 = local_vertices[i1]
	local v2 = local_vertices[i2]

	if not (v0 and v1 and v2) then return nil end

	return v0, v1, v2, i0, i1, i2
end

function triangle_mesh.GetFeaturePositionKey(position, epsilon)
	if not position then return nil end

	epsilon = epsilon or 0.0001
	local scale = 1 / epsilon
	return string.format(
		"%d:%d:%d",
		math.floor(position.x * scale + 0.5),
		math.floor(position.y * scale + 0.5),
		math.floor(position.z * scale + 0.5)
	)
end

local function append_unique_index(list, value)
	for i = 1, #list do
		if list[i] == value then return end
	end

	list[#list + 1] = value
end

function triangle_mesh.GetPolygonFeatureCache(poly, epsilon)
	epsilon = epsilon or 0.0001
	local sources = get_polygon_triangle_sources(poly)

	if not sources then return nil end

	local local_vertices = sources.local_vertices
	local indices = sources.indices
	local vertex_count = sources.vertex_count
	local face_count = sources.triangle_count
	local index_count = sources.index_count
	local polygon_cache = get_polygon_cache(poly)
	local feature_cache = polygon_cache.feature

	if
		feature_cache and
		feature_cache.source_a == local_vertices and
		feature_cache.source_b == indices and
		feature_cache.count_a == vertex_count and
		feature_cache.count_b == index_count and
		feature_cache.epsilon == epsilon
	then
		return feature_cache.value
	end

	local cache = {
		local_vertices = local_vertices,
		indices = indices,
		vertex_count = vertex_count,
		index_count = index_count,
		face_count = face_count,
		epsilon = epsilon,
		faces_by_vertex_index = {},
		faces_by_position_key = {},
	}

	for face_index = 0, face_count - 1 do
		local i0, i1, i2 = triangle_mesh.GetPolygonTriangleIndices(poly, face_index)
		local face_indices = {i0, i1, i2}

		for j = 1, 3 do
			local vertex_index = face_indices[j]
			local by_vertex = cache.faces_by_vertex_index[vertex_index]

			if not by_vertex then
				by_vertex = {}
				cache.faces_by_vertex_index[vertex_index] = by_vertex
			end

			by_vertex[#by_vertex + 1] = face_index
			local local_vertex = local_vertices[vertex_index]
			local key = triangle_mesh.GetFeaturePositionKey(local_vertex, epsilon)

			if key then
				local by_position = cache.faces_by_position_key[key]

				if not by_position then
					by_position = {}
					cache.faces_by_position_key[key] = by_position
				end

				append_unique_index(by_position, face_index)
			end
		end
	end

	polygon_cache.feature = {
		value = cache,
		source_a = local_vertices,
		source_b = indices,
		count_a = vertex_count,
		count_b = index_count,
		epsilon = epsilon,
	}
	return cache
end

local function triangle_bounds_overlap(bounds, triangle)
	if not bounds then return true end

	return not (
		triangle.min_x > bounds.max_x or
		bounds.min_x > triangle.max_x or
		triangle.min_y > bounds.max_y or
		bounds.min_y > triangle.max_y or
		triangle.min_z > bounds.max_z or
		bounds.min_z > triangle.max_z
	)
end

function triangle_mesh.GetPolygonTriangles(poly)
	local sources = get_polygon_triangle_sources(poly)

	if not sources then return nil, 0 end

	local local_vertices = sources.local_vertices
	local indices = sources.indices
	local triangle_count = sources.triangle_count
	local vertex_count = sources.vertex_count
	local index_count = sources.index_count
	local cache = get_polygon_cache(poly)
	local triangles_cache = cache.triangles

	if
		triangles_cache and
		triangles_cache.source_a == local_vertices and
		triangles_cache.source_b == indices and
		triangles_cache.count_a == vertex_count and
		triangles_cache.count_b == index_count
	then
		return triangles_cache.value, triangle_count
	end

	local triangles = {}

	for triangle_index = 0, triangle_count - 1 do
		local v0, v1, v2 = triangle_mesh.GetPolygonTriangleLocalVertices(poly, triangle_index)

		if v0 and v1 and v2 then
			triangles[#triangles + 1] = build_triangle_record(triangle_index, v0, v1, v2)
		end
	end

	cache.triangles = {
		value = triangles,
		source_a = local_vertices,
		source_b = indices,
		count_a = vertex_count,
		count_b = index_count,
	}
	return triangles, #triangles
end

local function get_triangle_bounds(triangle)
	return triangle
end

local function get_triangle_centroid(triangle)
	return triangle.centroid_x, triangle.centroid_y, triangle.centroid_z
end

function triangle_mesh.GetPolygonTriangleAcceleration(poly)
	local triangles, triangle_count = triangle_mesh.GetPolygonTriangles(poly)

	if not triangles or triangle_count < TRIANGLE_BVH_THRESHOLD then
		return nil, triangles, triangle_count
	end

	local cache = get_polygon_cache(poly)
	local acceleration_cache = cache.acceleration

	if
		acceleration_cache and
		acceleration_cache.source == triangles and
		acceleration_cache.count == triangle_count
	then
		return acceleration_cache.value, triangles, triangle_count
	end

	local tree = BVH.Build(triangles, get_triangle_bounds, get_triangle_centroid, TRIANGLE_BVH_LEAF_COUNT)

	if not tree then return nil, triangles, triangle_count end

	tree.triangles = tree.items
	tree.items = nil
	tree.traversal_context = tree.traversal_context or {
		acceleration = tree,
		node_stack = {},
	}
	cache.acceleration = {
		value = tree,
		source = triangles,
		count = triangle_count,
	}
	return tree, triangles, triangle_count
end

local function visit_triangle_leaf(node, context, result)
	local triangles = context.acceleration.triangles
	local callback = context.callback
	local user_context = context.user_context

	for i = node.first, node.last do
		local triangle = triangles[i]

		if callback(triangle.v0, triangle.v1, triangle.v2, triangle.triangle_index, user_context) then
			return true
		end
	end

	return result
end

function triangle_mesh.ForEachOverlappingTriangle(poly, local_bounds, callback, context)
	local acceleration, triangles, triangle_count = triangle_mesh.GetPolygonTriangleAcceleration(poly)

	if not (poly and triangles and triangle_count > 0 and callback) then return end

	if acceleration and local_bounds then
		local traversal_context = acceleration.traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.callback = callback
		traversal_context.user_context = context
		return BVH.TraverseAABB(local_bounds, acceleration.root, visit_triangle_leaf, traversal_context, nil)
	end

	for i = 1, triangle_count do
		local triangle = triangles[i]

		if triangle_bounds_overlap(local_bounds, triangle) then
			if callback(triangle.v0, triangle.v1, triangle.v2, triangle.triangle_index, context) then return true end
		end
	end
end

return triangle_mesh
