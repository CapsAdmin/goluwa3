local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local VertexType = vertex_math.VertexType
local packed_mesh = {}
local index_types = {
	[2] = ffi.typeof("uint16_t[?]"),
	[4] = ffi.typeof("uint32_t[?]"),
}
local VERTEX_BYTES = ffi.sizeof(VertexType(1)[0])

function packed_mesh.PackArrays(builder, vertices, vertex_count, indices, index_count, index_size)
	return {
		vertex_count = vertex_count,
		index_count = index_count,
		index_size = index_size,
		vertex_offset = builder:Add(vertices, vertex_count * VERTEX_BYTES),
		index_offset = builder:Add(indices, index_count * index_size),
	}
end

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

	return packed_mesh.PackArrays(builder, vertices, vertex_count, array, index_count, index_size)
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

function packed_mesh.PackSplit(builder, info, vertices)
	local uniform = vertex_layout.GetUniformExtras(vertices, info.vertex_count)
	local core, extras = vertex_layout.Split(vertices, info.vertex_count, not uniform)
	info.core_offset = builder:Add(core, info.vertex_count * vertex_layout.CoreStride)
	info.extras_offset = extras and
		builder:Add(extras, info.vertex_count * vertex_layout.ExtrasStride) or
		nil
	info.uniform_extras = uniform
end

function packed_mesh.UnpackSplit(info, blob_table)
	local core_size = info.vertex_count * vertex_layout.CoreStride
	local core = ffi.new("uint8_t[?]", math.max(core_size, 1))
	ffi.copy(core, blob_table.ptr + info.core_offset, core_size)
	local extras

	if info.extras_offset then
		local extras_size = info.vertex_count * vertex_layout.ExtrasStride
		extras = ffi.new("uint8_t[?]", math.max(extras_size, 1))
		ffi.copy(extras, blob_table.ptr + info.extras_offset, extras_size)
	end

	return {core = core, extras = extras, uniform = info.uniform_extras}
end

function packed_mesh.ToPolygon(info, blob_table)
	local vertices, indices = packed_mesh.Unpack(info, blob_table)
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, info.vertex_count, indices, info.index_count, true)
	return polygon
end

return packed_mesh
