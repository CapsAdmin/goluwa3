local ffi = require("ffi")
local blob = import("goluwa/codecs/internal/blob.lua")
local vtx = library()
vtx.file_extensions = {"vtx"}
vtx.returns_blob = true
local header_t = ffi.typeof([[struct __attribute__((packed)) {
	int32_t version;
	int32_t vertex_cache_size;
	uint16_t max_bones_per_strip;
	uint16_t max_bones_per_tri;
	int32_t max_bones_per_vertex;
	int32_t checksum;
	int32_t lod_count;
	int32_t material_replacement_list_offset;
	int32_t body_part_count;
	int32_t body_part_offset;
}]])
local header_ptr_t = ffi.typeof("const $ *", header_t)
local body_part_ptr_t = ffi.typeof(
	"const struct __attribute__((packed)) { int32_t model_count; int32_t model_offset; } *"
)
local model_ptr_t = ffi.typeof(
	"const struct __attribute__((packed)) { int32_t lod_count; int32_t lod_offset; } *"
)
local lod_ptr_t = ffi.typeof(
	"const struct __attribute__((packed)) { int32_t mesh_count; int32_t mesh_offset; float switch_point; } *"
)
local mesh_ptr_t = ffi.typeof(
	"const struct __attribute__((packed)) { int32_t strip_group_count; int32_t strip_group_offset; uint8_t flags; } *"
)
local strip_group_ptr_t = ffi.typeof([[const struct __attribute__((packed)) {
	int32_t vertex_count;
	int32_t vertex_offset;
	int32_t index_count;
	int32_t index_offset;
	int32_t strip_count;
	int32_t strip_offset;
	uint8_t flags;
} *]])
local vertex_ptr_t = ffi.typeof([[const struct __attribute__((packed)) {
	uint8_t bone_weight_index[3];
	uint8_t bone_count;
	uint16_t mesh_vertex_id;
	uint8_t bone_id[3];
} *]])
local strip_ptr_t = ffi.typeof([[const struct __attribute__((packed)) {
	int32_t index_count;
	int32_t index_offset;
	int32_t vertex_count;
	int32_t vertex_offset;
	int16_t bone_count;
	uint8_t flags;
	int32_t bone_state_change_count;
	int32_t bone_state_change_offset;
} *]])
local uint16_ptr_t = ffi.typeof("const uint16_t *")
local uint8_ptr_t = ffi.typeof("const uint8_t *")
local uint16_array_t = ffi.typeof("uint16_t[?]")
local MESH_SIZE = 9
local VERTEX_SIZE = 9
local STRIP_SIZE = 27
local BODY_PART_SIZE = 8
local MODEL_SIZE = 8
local LOD_SIZE = 12

function vtx.Decode(str, strip_group_size)
	if #str < ffi.sizeof(header_t) then return nil, "not a vtx file" end

	local length = #str
	local base = ffi.cast(uint8_ptr_t, str)
	local header = ffi.cast(header_ptr_t, base)
	local builder = blob.New()
	local body_parts = {}

	local function region(offset, count, size)
		if offset < 0 or count < 0 or offset + count * size > length then
			error("vtx data is out of range", 3)
		end

		return base + offset
	end

	local body_part_headers = ffi.cast(
		body_part_ptr_t,
		region(header.body_part_offset, header.body_part_count, BODY_PART_SIZE)
	)

	for bp = 0, header.body_part_count - 1 do
		local models = {}
		local models_offset = header.body_part_offset + bp * BODY_PART_SIZE + body_part_headers[bp].model_offset
		local model_count = body_part_headers[bp].model_count
		local model_headers = ffi.cast(model_ptr_t, region(models_offset, model_count, MODEL_SIZE))

		for m = 0, model_count - 1 do
			local lods = {}
			local lods_offset = models_offset + m * MODEL_SIZE + model_headers[m].lod_offset
			local lod_count = model_headers[m].lod_count
			local lod_headers = ffi.cast(lod_ptr_t, region(lods_offset, lod_count, LOD_SIZE))

			for l = 0, lod_count - 1 do
				local meshes = {}
				local meshes_offset = lods_offset + l * LOD_SIZE + lod_headers[l].mesh_offset
				local mesh_count = lod_headers[l].mesh_count
				local mesh_headers = ffi.cast(mesh_ptr_t, region(meshes_offset, mesh_count, MESH_SIZE))

				for k = 0, mesh_count - 1 do
					local mesh_header = mesh_headers[k]
					local groups_offset = meshes_offset + k * MESH_SIZE + mesh_header.strip_group_offset
					local group_count = mesh_header.strip_group_count
					region(groups_offset, group_count, strip_group_size)
					local bound = 0

					for g = 0, group_count - 1 do
						local group_offset = groups_offset + g * strip_group_size
						local group = ffi.cast(strip_group_ptr_t, base + group_offset)
						local strips = ffi.cast(
							strip_ptr_t,
							region(group_offset + group.strip_offset, group.strip_count, STRIP_SIZE)
						)

						for s = 0, group.strip_count - 1 do
							bound = bound + strips[s].index_count
						end
					end

					local array = uint16_array_t(math.max(bound, 1))
					local id_count = 0

					for g = 0, group_count - 1 do
						local group_offset = groups_offset + g * strip_group_size
						local group = ffi.cast(strip_group_ptr_t, base + group_offset)
						local vertices = ffi.cast(
							vertex_ptr_t,
							region(group_offset + group.vertex_offset, group.vertex_count, VERTEX_SIZE)
						)
						local indices = ffi.cast(uint16_ptr_t, region(group_offset + group.index_offset, group.index_count, 2))
						local strips = ffi.cast(strip_ptr_t, base + group_offset + group.strip_offset)

						for s = 0, group.strip_count - 1 do
							local strip = strips[s]

							if
								strip.index_offset < 0 or
								strip.index_offset + strip.index_count > group.index_count
							then
								error("vtx strip indices are out of range")
							end

							for i = 0, strip.index_count - 1 do
								local index = indices[strip.index_offset + i]

								if index < group.vertex_count then
									array[id_count] = vertices[index].mesh_vertex_id
									id_count = id_count + 1
								end
							end
						end
					end

					meshes[k + 1] = {
						offset = builder:Add(array, id_count * 2),
						count = id_count,
						flags = mesh_header.flags,
					}
				end

				lods[l + 1] = {meshes = meshes, switch_point = lod_headers[l].switch_point}
			end

			models[m + 1] = {lods = lods}
		end

		body_parts[bp + 1] = {models = models}
	end

	return {version = header.version, lod_count = header.lod_count, body_parts = body_parts},
	builder:Finish()
end

return vtx
