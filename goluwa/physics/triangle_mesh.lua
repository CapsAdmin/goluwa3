local BVH = import("goluwa/physics/bvh.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local triangle_mesh = {}
local TRIANGLE_BVH_THRESHOLD = 24
local TRIANGLE_BVH_LEAF_COUNT = 8

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
	if not (poly and poly.Vertices) then return nil, 0 end

	local vertices = poly.Vertices
	local vertex_count = #vertices

	if
		poly.triangle_mesh_local_vertices and
		poly.triangle_mesh_local_vertices_source == vertices and
		poly.triangle_mesh_local_vertex_count == vertex_count
	then
		return poly.triangle_mesh_local_vertices, vertex_count
	end

	local local_vertices = {}

	for i = 1, vertex_count do
		local_vertices[i] = triangle_mesh.GetVertexPosition(vertices[i])
	end

	poly.triangle_mesh_local_vertices = local_vertices
	poly.triangle_mesh_local_vertices_source = vertices
	poly.triangle_mesh_local_vertex_count = vertex_count
	return local_vertices, vertex_count
end

function triangle_mesh.GetPolygonIndexBuffer(poly)
	if not (poly and poly.Vertices) then return nil, 0 end

	if poly.indices then return poly.indices, math.floor(#poly.indices / 3) end

	local vertex_count = #poly.Vertices
	local triangle_count = math.floor(vertex_count / 3)

	if
		poly.triangle_mesh_sequential_indices and
		poly.triangle_mesh_sequential_vertex_count == vertex_count
	then
		return poly.triangle_mesh_sequential_indices, triangle_count
	end

	local sequential = {}

	for i = 1, vertex_count do
		sequential[i] = i - 1
	end

	poly.triangle_mesh_sequential_indices = sequential
	poly.triangle_mesh_sequential_vertex_count = vertex_count
	return sequential, triangle_count
end

function triangle_mesh.GetPolygonTriangleIndices(poly, triangle_index)
	if triangle_index == nil then return nil end

	local indices = select(1, triangle_mesh.GetPolygonIndexBuffer(poly))

	if not indices then return nil end

	local base = triangle_index * 3
	return indices[base + 1] + 1, indices[base + 2] + 1, indices[base + 3] + 1
end

function triangle_mesh.GetPolygonTriangleLocalVertices(poly, triangle_index)
	local local_vertices = select(1, triangle_mesh.GetPolygonLocalVertices(poly))
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
	if not (poly and poly.Vertices) then return nil end

	epsilon = epsilon or 0.0001
	local local_vertices, vertex_count = triangle_mesh.GetPolygonLocalVertices(poly)
	local indices, face_count = triangle_mesh.GetPolygonIndexBuffer(poly)

	if not (local_vertices and indices) then return nil end

	local index_count = #indices
	local cache = poly.triangle_mesh_feature_cache

	if
		cache and
		cache.local_vertices == local_vertices and
		cache.indices == indices and
		cache.vertex_count == vertex_count and
		cache.index_count == index_count and
		cache.epsilon == epsilon
	then
		return cache
	end

	cache = {
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

	poly.triangle_mesh_feature_cache = cache
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
	if not (poly and poly.Vertices) then return nil, 0 end

	local local_vertices = triangle_mesh.GetPolygonLocalVertices(poly)
	local indices, triangle_count = triangle_mesh.GetPolygonIndexBuffer(poly)
	local vertex_count = #poly.Vertices
	local index_count = indices and #indices or 0

	if
		poly.triangle_mesh_triangles and
		poly.triangle_mesh_triangle_vertices_source == local_vertices and
		poly.triangle_mesh_triangle_indices_source == indices and
		poly.triangle_mesh_triangle_vertex_count == vertex_count and
		poly.triangle_mesh_triangle_index_count == index_count
	then
		return poly.triangle_mesh_triangles, triangle_count
	end

	local triangles = {}

	for triangle_index = 0, triangle_count - 1 do
		local v0, v1, v2 = triangle_mesh.GetPolygonTriangleLocalVertices(poly, triangle_index)

		if v0 and v1 and v2 then
			triangles[#triangles + 1] = {
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
	end

	poly.triangle_mesh_triangles = triangles
	poly.triangle_mesh_triangle_vertices_source = local_vertices
	poly.triangle_mesh_triangle_indices_source = indices
	poly.triangle_mesh_triangle_vertex_count = vertex_count
	poly.triangle_mesh_triangle_index_count = index_count
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

	if
		poly.triangle_mesh_acceleration and
		poly.triangle_mesh_acceleration_source == triangles and
		poly.triangle_mesh_acceleration_count == triangle_count
	then
		return poly.triangle_mesh_acceleration, triangles, triangle_count
	end

	local tree = BVH.Build(triangles, get_triangle_bounds, get_triangle_centroid, TRIANGLE_BVH_LEAF_COUNT)

	if not tree then return nil, triangles, triangle_count end

	tree.triangles = tree.items
	tree.items = nil
	tree.traversal_context = tree.traversal_context or {
		acceleration = tree,
		node_stack = {},
	}
	poly.triangle_mesh_acceleration = tree
	poly.triangle_mesh_acceleration_source = triangles
	poly.triangle_mesh_acceleration_count = triangle_count
	return tree, triangles, triangle_count
end

local function invoke_triangle_callback(triangle, callback, context)
	callback(triangle.v0, triangle.v1, triangle.v2, triangle.triangle_index, context)
end

local function visit_triangle_leaf(node, context, result)
	for i = node.first, node.last do
		invoke_triangle_callback(context.acceleration.triangles[i], context.callback, context.user_context)
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
		BVH.TraverseAABB(local_bounds, acceleration.root, visit_triangle_leaf, traversal_context, nil)
		return
	end

	for i = 1, triangle_count do
		local triangle = triangles[i]

		if triangle_bounds_overlap(local_bounds, triangle) then
			invoke_triangle_callback(triangle, callback, context)
		end
	end
end

return triangle_mesh
