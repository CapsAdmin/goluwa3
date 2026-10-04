local ffi = require("ffi")
local source = import("goluwa/codecs/internal/source.lua")
local vvd = library()
vvd.file_extensions = {"vvd"}
vvd.magic_headers = {"IDSV"}
vvd.returns_blob = true
local header_t = ffi.typeof([[struct {
	char id[4];
	int32_t version;
	int32_t checksum;
	int32_t lod_count;
	int32_t lod_vertex_count[8];
	int32_t fixup_count;
	int32_t fixup_offset;
	int32_t vertices_offset;
	int32_t tangent_offset;
}]])
local header_ptr_t = ffi.typeof("const $ *", header_t)
local fixup_ptr_t = ffi.typeof("const struct { int32_t lod; int32_t source_vertex; int32_t vertex_count; } *")
local file_vertex_ptr_t = ffi.typeof([[const struct {
	float bone_weights[3];
	uint8_t bone_ids[3];
	uint8_t bone_count;
	float pos[3];
	float normal[3];
	float uv[2];
} *]])
local vertex_t = ffi.typeof([[struct {
	float pos[3];
	float normal[3];
	float uv[2];
	float bone_weights[3];
	uint8_t bone_ids[3];
	uint8_t bone_count;
}]])
local vertex_array_t = ffi.typeof("$[?]", vertex_t)
vvd.Vertex = vertex_t
vvd.VertexArray = vertex_array_t
vvd.VertexSize = ffi.sizeof(vertex_t)
local scale = source.meters
local uint8_ptr_t = ffi.typeof("const uint8_t *")

function vvd.Decode(str)
	if #str < ffi.sizeof(header_t) or str:sub(1, 4) ~= "IDSV" then
		return nil, "not a vvd file"
	end

	local base = ffi.cast(uint8_ptr_t, str)
	local header = ffi.cast(header_ptr_t, base)
	local count = 0

	if header.lod_count > 0 then
		if header.fixup_count == 0 then
			count = header.lod_vertex_count[0]
		else
			if header.fixup_offset < 0 or header.fixup_offset + header.fixup_count * 12 > #str then
				return nil, "vvd fixup table is out of range"
			end

			local fixups = ffi.cast(fixup_ptr_t, base + header.fixup_offset)

			for i = 0, header.fixup_count - 1 do
				count = count + fixups[i].vertex_count
			end
		end
	end

	local file_vertices = ffi.cast(file_vertex_ptr_t, base + header.vertices_offset)
	local available = math.floor((#str - header.vertices_offset) / ffi.sizeof(vertex_t))

	if header.vertices_offset < 0 or count < 0 or count > available then
		return nil, "vvd vertex data is truncated"
	end

	local out = vertex_array_t(math.max(count, 1))
	local range_starts, range_counts = {}, {}

	if count > 0 then
		if header.fixup_count == 0 then
			range_starts[1], range_counts[1] = 0, count
		else
			local fixups = ffi.cast(fixup_ptr_t, base + header.fixup_offset)

			for i = 0, header.fixup_count - 1 do
				local fixup = fixups[i]

				if
					fixup.source_vertex < 0 or
					fixup.vertex_count < 0 or
					fixup.source_vertex + fixup.vertex_count > available
				then
					return nil, "vvd fixup references vertices outside the file"
				end

				range_starts[i + 1] = fixup.source_vertex
				range_counts[i + 1] = fixup.vertex_count
			end
		end
	end

	local index = 0

	for range = 1, #range_starts do
		for k = 0, range_counts[range] - 1 do
			local file_vertex = file_vertices[range_starts[range] + k]
			local out_vertex = out[index]
			index = index + 1
			local x, y, z = file_vertex.pos[0], file_vertex.pos[1], file_vertex.pos[2]
			out_vertex.pos[0] = -y * scale
			out_vertex.pos[1] = z * scale
			out_vertex.pos[2] = -x * scale
			local nx, ny, nz = file_vertex.normal[0], file_vertex.normal[1], file_vertex.normal[2]
			out_vertex.normal[0] = -ny
			out_vertex.normal[1] = nz
			out_vertex.normal[2] = -nx
			out_vertex.uv[0] = file_vertex.uv[0]
			out_vertex.uv[1] = file_vertex.uv[1]

			for i = 0, 2 do
				out_vertex.bone_weights[i] = file_vertex.bone_weights[i]
				out_vertex.bone_ids[i] = file_vertex.bone_ids[i]
			end

			out_vertex.bone_count = file_vertex.bone_count
		end
	end

	return {version = header.version, lod_count = header.lod_count, count = count},
	out
end

return vvd
