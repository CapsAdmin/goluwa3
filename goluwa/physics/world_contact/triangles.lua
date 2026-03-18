local BVH = import("goluwa/physics/bvh.lua")
local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_contact_triangles = {}
local TRIANGLE_BVH_THRESHOLD = 24
local TRIANGLE_BVH_LEAF_COUNT = 8

function world_contact_triangles.GetVertexPosition(vertex)
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

function world_contact_triangles.GetPolygonLocalVertices(poly)
	if not (poly and poly.Vertices) then return nil, 0 end

	local vertices = poly.Vertices
	local vertex_count = #vertices

	if
		poly.world_contact_local_vertices and
		poly.world_contact_local_vertices_source == vertices and
		poly.world_contact_local_vertex_count == vertex_count
	then
		return poly.world_contact_local_vertices, vertex_count
	end

	local local_vertices = {}

	for i = 1, vertex_count do
		local_vertices[i] = world_contact_triangles.GetVertexPosition(vertices[i])
	end

	poly.world_contact_local_vertices = local_vertices
	poly.world_contact_local_vertices_source = vertices
	poly.world_contact_local_vertex_count = vertex_count
	return local_vertices, vertex_count
end

function world_contact_triangles.GetPolygonIndexBuffer(poly)
	if not (poly and poly.Vertices) then return nil, 0 end

	if poly.indices then return poly.indices, math.floor(#poly.indices / 3) end

	local vertex_count = #poly.Vertices
	local triangle_count = math.floor(vertex_count / 3)

	if
		poly.world_contact_sequential_indices and
		poly.world_contact_sequential_vertex_count == vertex_count
	then
		return poly.world_contact_sequential_indices, triangle_count
	end

	local sequential = {}

	for i = 1, vertex_count do
		sequential[i] = i - 1
	end

	poly.world_contact_sequential_indices = sequential
	poly.world_contact_sequential_vertex_count = vertex_count
	return sequential, triangle_count
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

function world_contact_triangles.GetPolygonTriangles(poly)
	if not (poly and poly.Vertices) then return nil, 0 end

	local local_vertices = world_contact_triangles.GetPolygonLocalVertices(poly)
	local indices, triangle_count = world_contact_triangles.GetPolygonIndexBuffer(poly)
	local vertex_count = #poly.Vertices
	local index_count = indices and #indices or 0

	if
		poly.world_contact_triangles and
		poly.world_contact_triangle_vertices_source == local_vertices and
		poly.world_contact_triangle_indices_source == indices and
		poly.world_contact_triangle_vertex_count == vertex_count and
		poly.world_contact_triangle_index_count == index_count
	then
		return poly.world_contact_triangles, triangle_count
	end

	local triangles = {}

	for triangle_index = 0, triangle_count - 1 do
		local base = triangle_index * 3
		local v0 = local_vertices[indices[base + 1] + 1]
		local v1 = local_vertices[indices[base + 2] + 1]
		local v2 = local_vertices[indices[base + 3] + 1]

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

	poly.world_contact_triangles = triangles
	poly.world_contact_triangle_vertices_source = local_vertices
	poly.world_contact_triangle_indices_source = indices
	poly.world_contact_triangle_vertex_count = vertex_count
	poly.world_contact_triangle_index_count = index_count
	return triangles, #triangles
end

local function get_triangle_bounds(triangle)
	return triangle
end

local function get_triangle_centroid(triangle)
	return triangle.centroid_x, triangle.centroid_y, triangle.centroid_z
end

function world_contact_triangles.GetPolygonTriangleAcceleration(poly)
	local triangles, triangle_count = world_contact_triangles.GetPolygonTriangles(poly)

	if not triangles or triangle_count < TRIANGLE_BVH_THRESHOLD then
		return nil, triangles, triangle_count
	end

	if
		poly.world_contact_triangle_acceleration and
		poly.world_contact_triangle_acceleration_source == triangles and
		poly.world_contact_triangle_acceleration_count == triangle_count
	then
		return poly.world_contact_triangle_acceleration, triangles, triangle_count
	end

	local tree = BVH.Build(triangles, get_triangle_bounds, get_triangle_centroid, TRIANGLE_BVH_LEAF_COUNT)

	if not tree then return nil, triangles, triangle_count end

	tree.triangles = tree.items
	tree.items = nil
	tree.traversal_context = tree.traversal_context or {
		acceleration = tree,
		node_stack = {},
	}
	poly.world_contact_triangle_acceleration = tree
	poly.world_contact_triangle_acceleration_source = triangles
	poly.world_contact_triangle_acceleration_count = triangle_count
	return tree, triangles, triangle_count
end

function world_contact_triangles.BuildTriangleHit(model, entity, primitive, primitive_index, triangle_index)
	return {
		entity = entity,
		model = model,
		primitive = primitive,
		primitive_index = primitive_index,
		triangle_index = triangle_index,
	}
end

local function invoke_triangle_callback_local(triangle, callback, context)
	callback(triangle.v0, triangle.v1, triangle.v2, triangle.triangle_index, context)
end

local function invoke_triangle_callback_world(triangle, local_to_world, callback, context)
	callback(
		local_to_world:TransformVector(triangle.v0),
		local_to_world:TransformVector(triangle.v1),
		local_to_world:TransformVector(triangle.v2),
		triangle.triangle_index,
		context
	)
end

local function visit_triangle_leaf_local(node, context, result)
	for i = node.first, node.last do
		invoke_triangle_callback_local(context.acceleration.triangles[i], context.callback, context.user_context)
	end

	return result
end

local function visit_triangle_leaf_world(node, context, result)
	for i = node.first, node.last do
		invoke_triangle_callback_world(context.acceleration.triangles[i], context.local_to_world, context.callback, context.user_context)
	end

	return result
end

function world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, callback, context)
	local acceleration, triangles, triangle_count = world_contact_triangles.GetPolygonTriangleAcceleration(poly)

	if not (poly and triangles and triangle_count > 0 and callback) then return end

	if acceleration and local_body_aabb then
		local traversal_context = acceleration.traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.callback = callback
		traversal_context.local_to_world = local_to_world
		traversal_context.user_context = context
		BVH.TraverseAABB(
			local_body_aabb,
			acceleration.root,
			local_to_world and visit_triangle_leaf_world or visit_triangle_leaf_local,
			traversal_context,
			nil
		)
		return
	end

	for i = 1, triangle_count do
		local triangle = triangles[i]

		if triangle_bounds_overlap(local_body_aabb, triangle) then
			if local_to_world then
				invoke_triangle_callback_world(triangle, local_to_world, callback, context)
			else
				invoke_triangle_callback_local(triangle, callback, context)
			end
		end
	end
end

return world_contact_triangles
