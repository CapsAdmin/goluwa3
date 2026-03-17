local world_transform_utils = import("goluwa/physics/world_transform_utils.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local world_contact_triangles = {}

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

local function triangle_overlaps_local_aabb(v0, v1, v2, bounds)
	if not bounds then return true end

	local triangle_bounds = {
		min_x = math.min(v0.x, v1.x, v2.x),
		min_y = math.min(v0.y, v1.y, v2.y),
		min_z = math.min(v0.z, v1.z, v2.z),
		max_x = math.max(v0.x, v1.x, v2.x),
		max_y = math.max(v0.y, v1.y, v2.y),
		max_z = math.max(v0.z, v1.z, v2.z),
	}

	return world_transform_utils.AABBIntersects(triangle_bounds, bounds)
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

function world_contact_triangles.ForEachOverlappingWorldTriangle(poly, local_body_aabb, local_to_world, callback, ...)
	local local_vertices = world_contact_triangles.GetPolygonLocalVertices(poly)
	local indices, triangle_count = world_contact_triangles.GetPolygonIndexBuffer(poly)

	if not (poly and local_vertices and indices and triangle_count > 0) then return end

	for triangle_index = 0, triangle_count - 1 do
		local base = triangle_index * 3
		local v0_local = local_vertices[indices[base + 1] + 1]
		local v1_local = local_vertices[indices[base + 2] + 1]
		local v2_local = local_vertices[indices[base + 3] + 1]

		if
			v0_local and
			v1_local and
			v2_local and
			triangle_overlaps_local_aabb(v0_local, v1_local, v2_local, local_body_aabb)
		then
			local v0 = local_to_world and local_to_world:TransformVector(v0_local) or v0_local
			local v1 = local_to_world and local_to_world:TransformVector(v1_local) or v1_local
			local v2 = local_to_world and local_to_world:TransformVector(v2_local) or v2_local
			callback(v0, v1, v2, triangle_index, ...)
		end
	end
end

return world_contact_triangles