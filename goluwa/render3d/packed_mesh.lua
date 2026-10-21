local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local VertexType = vertex_math.VertexType
local packed_mesh = {}
local index_types = {
	[2] = ffi.typeof("uint16_t[?]"),
	[4] = ffi.typeof("uint32_t[?]"),
}
local VERTEX_BYTES = ffi.sizeof(VertexType(1)[0])

function packed_mesh.PackPolygon(builder, polygon)
	local vertices, vertex_count = polygon:PackVertices()

	if not vertices then return nil end

	local indices = polygon.indices
	local index_count = #indices
	local index_size = vertex_count > 65535 and 4 or 2
	local array = index_types[index_size](math.max(index_count, 1))

	for i = 1, index_count do
		array[i - 1] = indices[i] - 1
	end

	return {
		vertex_count = vertex_count,
		index_count = index_count,
		index_size = index_size,
		vertex_offset = builder:Add(vertices, vertex_count * VERTEX_BYTES),
		index_offset = builder:Add(array, index_count * index_size),
	}
end

function packed_mesh.Unpack(info, blob_table)
	local vertices = VertexType(info.vertex_count)
	ffi.copy(vertices, blob_table.ptr + info.vertex_offset, info.vertex_count * VERTEX_BYTES)
	local indices = index_types[info.index_size](math.max(info.index_count, 1))

	if info.index_count > 0 then
		ffi.copy(indices, blob_table.ptr + info.index_offset, info.index_count * info.index_size)
	end

	return vertices, indices
end

function packed_mesh.ToPolygon(info, blob_table)
	local vertices, indices = packed_mesh.Unpack(info, blob_table)
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, info.vertex_count, indices, info.index_count, true)
	return polygon
end

return packed_mesh
