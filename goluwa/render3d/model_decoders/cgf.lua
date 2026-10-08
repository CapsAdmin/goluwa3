local mtl_material = import("goluwa/cry_engine/mtl_material.lua")
local cry_units = import("goluwa/cry_engine/units.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local lod = import("goluwa/render3d/lod.lua")
local cgf = {}
cgf.FILE_TYPE_GEOMETRY = 0xFFFF0000
cgf.FILE_TYPE_ANIMATION = 0xFFFF0001
cgf.VERSION_744 = 0x744
cgf.VERSION_745 = 0x745
cgf.VERSION_MESH_COMPILED = 0x800
cgf.CHUNK_MESH = 0xCCCC0000
cgf.CHUNK_HELPER = 0xCCCC0001
cgf.CHUNK_NODE = 0xCCCC000B
cgf.CHUNK_MTL_NAME = 0xCCCC0014
cgf.CHUNK_EXPORT_FLAGS = 0xCCCC0015
cgf.CHUNK_DATA_STREAM = 0xCCCC0016
cgf.CHUNK_MESH_SUBSETS = 0xCCCC0017
cgf.CHUNK_MESH_PHYSICS_DATA = 0xCCCC0018
cgf.MAX_SIBLING_LODS = 4

local function assert_old_cgf_version(version)
	if version ~= cgf.VERSION_744 and version ~= cgf.VERSION_745 then
		error(string.format("unsupported cgf version 0x%X", version))
	end
end

local function normalize_chunk_version(version)
	return bit.band(version, 0x7FFFFFFF)
end

local function get_chunk_entry_size(version)
	if version == cgf.VERSION_745 then return 20 end

	return 16
end

local function read_vec2(file)
	return Vec2(file:ReadFloat(), file:ReadFloat())
end

local function read_vec3(file)
	return Vec3(file:ReadFloat(), file:ReadFloat(), file:ReadFloat())
end

local function transform_direction(matrix, vec)
	local origin = matrix:TransformVector(Vec3(0, 0, 0))
	return (matrix:TransformVector(vec) - origin):GetNormalized()
end

local function chunk_body_offset(chunk)
	return chunk.offset + 16
end

local function infer_744_chunk_sizes(chunks, file_size, chunk_table_offset)
	local ordered = {}

	for i, chunk in ipairs(chunks) do
		ordered[i] = chunk
	end

	table.sort(ordered, function(a, b)
		return a.offset < b.offset
	end)

	for i, chunk in ipairs(ordered) do
		local next_offset = ordered[i + 1] and ordered[i + 1].offset or file_size

		if chunk_table_offset > chunk.offset and chunk_table_offset < next_offset then
			next_offset = chunk_table_offset
		end

		chunk.size = math.max(0, next_offset - chunk.offset)
	end
end

function cgf.ReadHeader(file)
	file:SetPosition(0)
	local signature = file:ReadString(8)

	if signature:sub(1, 6) ~= "CryTek" then error("not a CryTek chunk file") end

	local header = {
		signature = signature,
		file_type = file:ReadU32LE(),
		version = file:ReadU32LE(),
		chunk_table_offset = file:ReadU32LE(),
	}
	assert_old_cgf_version(header.version)
	return header
end

function cgf.ReadChunks(file, header)
	header = header or cgf.ReadHeader(file)
	file:PushPosition(header.chunk_table_offset)
	local chunk_count = file:ReadU32()
	local entry_size = get_chunk_entry_size(header.version)
	local chunks = {}

	for index = 1, chunk_count do
		local chunk = {
			index = index,
			type = file:ReadU32(),
			raw_version = file:ReadU32(),
			offset = file:ReadU32(),
			id = file:ReadU32(),
		}
		chunk.version = normalize_chunk_version(chunk.raw_version)

		if entry_size == 20 then chunk.size = file:ReadU32() end

		chunks[index] = chunk
	end

	file:PopPosition()

	if entry_size == 16 then
		infer_744_chunk_sizes(chunks, file:GetSize(), header.chunk_table_offset)
	end

	return chunks
end

function cgf.ReadChunkEmbeddedHeader(file, chunk)
	file:PushPosition(chunk.offset)
	local embedded = {
		type = file:ReadU32(),
		raw_version = file:ReadU32(),
		offset = file:ReadU32(),
		id = file:ReadU32(),
	}
	file:PopPosition()
	embedded.version = normalize_chunk_version(embedded.raw_version)
	return embedded
end

function cgf.Open(path)
	local file = assert(vfs.Open(path))
	local header = cgf.ReadHeader(file)
	local chunks = cgf.ReadChunks(file, header)
	local chunks_by_id = {}

	for _, chunk in ipairs(chunks) do
		chunks_by_id[chunk.id] = chunk
	end

	return {
		file = file,
		header = header,
		chunks = chunks,
		chunks_by_id = chunks_by_id,
	}
end

function cgf.ReadMeshChunk(file, chunk)
	file:PushPosition(chunk_body_offset(chunk))
	local mesh = {
		chunk = chunk,
		flags = file:ReadI32(),
		flags2 = file:ReadI32(),
		num_vertices = file:ReadI32(),
		num_indices = file:ReadI32(),
		num_subsets = file:ReadI32(),
		subsets_chunk_id = file:ReadI32(),
		vertex_animation_chunk_id = file:ReadI32(),
		stream_chunk_ids = {},
		physics_data_chunk_ids = {},
	}

	for index = 1, 16 do
		mesh.stream_chunk_ids[index] = file:ReadI32()
	end

	for index = 1, 4 do
		mesh.physics_data_chunk_ids[index] = file:ReadI32()
	end

	mesh.bounds_min = read_vec3(file)
	mesh.bounds_max = read_vec3(file)
	mesh.tex_mapping_density = file:ReadFloat()
	file:PopPosition()
	return mesh
end

function cgf.ReadMeshSubsetsChunk(file, chunk)
	file:PushPosition(chunk_body_offset(chunk))
	local out = {
		chunk = chunk,
		flags = file:ReadI32(),
		count = file:ReadI32(),
		subsets = {},
	}
	file:Advance(8)

	for index = 1, out.count do
		out.subsets[index] = {
			first_index = file:ReadI32(),
			num_indices = file:ReadI32(),
			first_vertex = file:ReadI32(),
			num_vertices = file:ReadI32(),
			material_id = file:ReadI32(),
			radius = file:ReadFloat(),
			center = read_vec3(file),
		}
	end

	file:PopPosition()
	return out
end

function cgf.ReadDataStreamChunk(file, chunk)
	file:PushPosition(chunk_body_offset(chunk))
	local stream = {
		chunk = chunk,
		flags = file:ReadI32(),
		stream_type = file:ReadI32(),
		count = file:ReadI32(),
		element_size = file:ReadI32(),
	}
	file:Advance(8)

	if stream.stream_type == 0 or stream.stream_type == 1 then
		stream.values = {}

		for index = 1, stream.count do
			stream.values[index] = read_vec3(file)
		end
	elseif stream.stream_type == 2 then
		stream.values = {}

		for index = 1, stream.count do
			stream.values[index] = read_vec2(file)
		end
	elseif stream.stream_type == 3 then
		stream.values = {}

		for index = 1, stream.count do
			stream.values[index] = {
				r = file:ReadByte() / 255,
				g = file:ReadByte() / 255,
				b = file:ReadByte() / 255,
				a = file:ReadByte() / 255,
			}
		end
	elseif stream.stream_type == 5 then
		stream.values = {}

		for index = 1, stream.count do
			stream.values[index] = file:ReadU16() + 1
		end
	else
		stream.values = false
	end

	file:PopPosition()
	return stream
end

function cgf.ReadMaterialNameChunk(file, chunk)
	file:PushPosition(chunk_body_offset(chunk))
	local material = {
		chunk = chunk,
		kind = file:ReadI32(),
		flags = file:ReadI32(),
		name = file:ReadString(128):remove_padding(),
	}
	file:PopPosition()
	return material
end

function cgf.ReadNodeChunk(file, chunk)
	file:PushPosition(chunk_body_offset(chunk))
	local node = {
		id = chunk.id,
		chunk = chunk,
		name = file:ReadString(64):remove_padding(),
		object_id = file:ReadI32(),
		parent_id = file:ReadI32(),
		num_children = file:ReadI32(),
		material_chunk_id = file:ReadI32(),
		is_group_head = file:ReadByte() ~= 0,
		is_group_member = file:ReadByte() ~= 0,
	}
	file:Advance(2)
	local tm = {}

	for i = 1, 16 do
		tm[i] = file:ReadFloat()
	end

	tm[4] = 0
	tm[8] = 0
	tm[12] = 0
	tm[13] = tm[13] * 0.01
	tm[14] = tm[14] * 0.01
	tm[15] = tm[15] * 0.01
	tm[16] = 1
	node.local_transform = Matrix44(unpack(tm))
	file:Advance((3 + 4 + 3) * 4)
	node.position_controller_id = file:ReadI32()
	node.rotation_controller_id = file:ReadI32()
	node.scale_controller_id = file:ReadI32()
	file:PopPosition()
	return node
end

function cgf.GetNodeWorldTransform(nodes_by_id, node_id, cache, visiting)
	cache = cache or {}

	if cache[node_id] then return cache[node_id] end

	visiting = visiting or {}

	if visiting[node_id] then error("cgf node cycle at " .. tostring(node_id)) end

	local node = assert(nodes_by_id[node_id], "unknown cgf node " .. tostring(node_id))
	local local_transform = node.local_transform
	visiting[node_id] = true

	if node.parent_id and node.parent_id > -1 and nodes_by_id[node.parent_id] then
		cache[node_id] = cgf.GetNodeWorldTransform(nodes_by_id, node.parent_id, cache, visiting) * local_transform
	else
		cache[node_id] = local_transform
	end

	visiting[node_id] = nil
	return cache[node_id]
end

function cgf.ExtractStaticMeshData(parsed)
	local entries = {}
	local file = parsed.file
	local nodes_by_id = {}
	local materials_by_id = {}
	local node_order = {}

	for _, chunk in ipairs(parsed.chunks) do
		if chunk.type == cgf.CHUNK_NODE then
			local node = cgf.ReadNodeChunk(file, chunk)
			nodes_by_id[node.id] = node
			node_order[#node_order + 1] = node.id
		elseif chunk.type == cgf.CHUNK_MTL_NAME then
			materials_by_id[chunk.id] = cgf.ReadMaterialNameChunk(file, chunk)
		end
	end

	local world_transforms = {}
	local base_nodes_by_name = {}
	local first_base_node

	for _, node_id in ipairs(node_order) do
		local node = nodes_by_id[node_id]

		if node.object_id > 0 and not node.name:starts_with("$") then
			base_nodes_by_name[node.name] = node_id
			first_base_node = first_base_node or node_id
		end
	end

	for _, node_id in ipairs(node_order) do
		local node = nodes_by_id[node_id]
		local lod_level = tonumber(node.name:match("^%$[lL][oO][dD](%d+)_"))

		if node.object_id > 0 and (lod_level or not node.name:starts_with("$")) then
			local mesh_chunk = parsed.chunks_by_id[node.object_id]

			if mesh_chunk and mesh_chunk.type == cgf.CHUNK_MESH then
				local transform_node_id = node.id

				if lod_level then
					local base_name = node.name:gsub("^%$[lL][oO][dD]%d+_", "")
					transform_node_id = base_nodes_by_name[base_name] or first_base_node or node.id
				end

				local world_transform = cgf.GetNodeWorldTransform(nodes_by_id, transform_node_id, world_transforms)

				if mesh_chunk.version ~= cgf.VERSION_MESH_COMPILED then
					error(
						string.format(
							"unsupported cgf mesh chunk version 0x%X in node %q",
							mesh_chunk.version,
							node.name
						)
					)
				end

				local mesh = cgf.ReadMeshChunk(file, mesh_chunk)
				local subsets_chunk = parsed.chunks_by_id[mesh.subsets_chunk_id]

				if subsets_chunk and subsets_chunk.type ~= cgf.CHUNK_MESH_SUBSETS then
					error(
						string.format(
							"cgf mesh subsets chunk %d has type 0x%X",
							mesh.subsets_chunk_id,
							subsets_chunk.type
						)
					)
				end

				local subsets = subsets_chunk and cgf.ReadMeshSubsetsChunk(file, subsets_chunk) or {subsets = {}}
				local streams_by_type = {}
				local material = materials_by_id[node.material_chunk_id]

				for _, stream_chunk_id in ipairs(mesh.stream_chunk_ids) do
					if stream_chunk_id and stream_chunk_id > 0 then
						local stream_chunk = parsed.chunks_by_id[stream_chunk_id]

						if stream_chunk and stream_chunk.type == cgf.CHUNK_DATA_STREAM then
							local stream = cgf.ReadDataStreamChunk(file, stream_chunk)
							streams_by_type[stream.stream_type] = stream
						end
					end
				end

				local positions = streams_by_type[0] and streams_by_type[0].values or {}
				local normals = streams_by_type[1] and streams_by_type[1].values or {}
				local uvs = streams_by_type[2] and streams_by_type[2].values or {}
				local colors = streams_by_type[3] and streams_by_type[3].values or {}
				local indices = streams_by_type[5] and streams_by_type[5].values or {}
				local base_vertices = {}

				for index, pos in ipairs(positions) do
					local transformed_position = cry_units.ToEngine(world_transform:TransformVector(pos))
					local transformed_normal = normals[index] and
						cry_units.ToEngine(transform_direction(world_transform, normals[index])) or
						nil
					base_vertices[index] = {
						pos = transformed_position,
						normal = transformed_normal,
						uv = uvs[index] and uvs[index]:Copy() or nil,
						texture_blend = colors[index] and colors[index].a or 0,
						vertex_color = colors[index],
					}
				end

				if subsets.subsets[1] then
					local claimed = {}

					for _, subset in ipairs(subsets.subsets) do
						if subset.num_indices <= 0 then goto continue_subset end

						local subset_indices = {}
						local subset_vertices = {}
						local remap = {}

						for index = subset.first_index + 1, subset.first_index + subset.num_indices do
							local vertex_index = indices[index]
							local new_index = remap[vertex_index]

							if not new_index then
								local vertex = base_vertices[vertex_index]
								new_index = #subset_vertices + 1
								remap[vertex_index] = new_index

								if claimed[vertex_index] then
									vertex = {
										pos = vertex.pos,
										normal = vertex.normal,
										uv = vertex.uv,
										texture_blend = vertex.texture_blend,
										vertex_color = vertex.vertex_color,
									}
								else
									claimed[vertex_index] = true
								end

								subset_vertices[new_index] = vertex
							end

							subset_indices[#subset_indices + 1] = new_index
						end

						for index = 1, #subset_indices - 2, 3 do
							subset_indices[index + 1], subset_indices[index + 2] = subset_indices[index + 2], subset_indices[index + 1]
						end

						if not subset_indices[1] then goto continue_subset end

						entries[#entries + 1] = {
							name = node.name,
							material_chunk_id = node.material_chunk_id,
							material_name = material and material.name or nil,
							subset_material_id = subset.material_id,
							vertices = subset_vertices,
							indices = subset_indices,
							lod_level = lod_level or 0,
						}

						::continue_subset::
					end
				elseif indices[1] then
					local fixed_indices = {}

					for index = 1, #indices do
						fixed_indices[index] = indices[index]
					end

					for index = 1, #fixed_indices - 2, 3 do
						fixed_indices[index + 1], fixed_indices[index + 2] = fixed_indices[index + 2], fixed_indices[index + 1]
					end

					entries[#entries + 1] = {
						name = node.name,
						material_chunk_id = node.material_chunk_id,
						material_name = material and material.name or nil,
						vertices = base_vertices,
						indices = fixed_indices,
						lod_level = lod_level or 0,
					}
				end
			end
		end
	end

	return entries
end

function cgf.ResolveMaterialPath(model_path, material_name)
	local material_root = file_path.GetFolderFromPath(model_path)
	local name = file_path.FixPathSlashes(material_name):gsub("%.[mM][tT][lL]$", "")

	if name:find("/", 1, true) then
		material_root = material_root:sub(1, (material_root:lower():find("/objects/", 1, true) or 0))
	end

	local material_path = material_root .. name .. ".mtl"
	return vfs.FindMixedCasePath(material_path) or material_path
end

function cgf.GetMaterialPaths(path)
	local parsed = cgf.Open(path)
	local model_path = parsed.file.path_used or path
	local out = {}
	local seen = {}

	for _, chunk in ipairs(parsed.chunks) do
		local material_chunk = chunk.type == cgf.CHUNK_NODE and
			parsed.chunks_by_id[cgf.ReadNodeChunk(parsed.file, chunk).material_chunk_id]

		if material_chunk and material_chunk.type == cgf.CHUNK_MTL_NAME then
			local name = cgf.ReadMaterialNameChunk(parsed.file, material_chunk).name

			if name ~= "" then
				local material_path = cgf.ResolveMaterialPath(model_path, name)

				if not seen[material_path] then
					seen[material_path] = true
					out[#out + 1] = material_path
				end
			end
		end
	end

	parsed.file:Close()
	return out
end

function cgf.DecodeModel(path, full_path, mesh_callback)
	local ok_open, parsed_or_err = pcall(cgf.Open, full_path)

	if not ok_open then
		error(("failed to open cgf %q from %q: %s"):format(path, full_path, parsed_or_err), 0)
	end

	local parsed = parsed_or_err
	local model_path = parsed.file.path_used or full_path
	local resolved_material_paths = {}
	local ok, result = xpcall(function()
		local entries = cgf.ExtractStaticMeshData(parsed)
		local has_lod_nodes = false

		for _, entry in ipairs(entries) do
			if entry.lod_level > 0 then has_lod_nodes = true end
		end

		if not has_lod_nodes then
			local base = model_path:gsub("%.[cC][gG][fF]$", "")

			for level = 1, cgf.MAX_SIBLING_LODS do
				local lod_path = vfs.FindMixedCasePath(base .. "_lod" .. level .. ".cgf")

				if not lod_path then break end

				local lod_parsed = cgf.Open(lod_path)
				local ok_lod, lod_entries = pcall(cgf.ExtractStaticMeshData, lod_parsed)
				lod_parsed.file:Close()

				if not ok_lod then error(lod_entries, 0) end

				for _, entry in ipairs(lod_entries) do
					entry.lod_level = level
					entries[#entries + 1] = entry
				end
			end
		end

		local bend_height = 0

		for _, entry in ipairs(entries) do
			if entry.lod_level == 0 then
				for _, vertex in ipairs(entry.vertices) do
					bend_height = math.max(bend_height, vertex.pos.y)
				end
			end
		end

		for _, entry in ipairs(entries) do
			local mesh = Polygon3D.New()
			local material = nil

			if entry.material_name then
				local material_path = resolved_material_paths[entry.material_name]

				if not material_path then
					material_path = cgf.ResolveMaterialPath(model_path, entry.material_name)
					resolved_material_paths[entry.material_name] = material_path
				end

				if vfs.IsFile(material_path) then
					material = mtl_material.FromCryMTL(material_path, entry.subset_material_id)
				else
					logf(
						"crytek material not found for %q referenced by model %q\n",
						tostring(material_path),
						tostring(path)
					)
					material = Material.New()
					material:SetAlbedoTexture(Texture.GetFallback())
				end
			end

			local vertices = entry.vertices
			local diffuse = material and material.cry_texture_maps and material.cry_texture_maps.Diffuse

			if
				diffuse and
				(
					diffuse.tile_u ~= 1 or
					diffuse.tile_v ~= 1 or
					diffuse.offset_u ~= 0 or
					diffuse.offset_v ~= 0
				)
			then
				for _, vertex in ipairs(vertices) do
					if vertex.uv then
						vertex.uv = Vec2(
							vertex.uv.x * diffuse.tile_u + diffuse.offset_u,
							vertex.uv.y * diffuse.tile_v + diffuse.offset_v
						)
					end
				end
			end

			mesh:SetVertices(vertices)
			mesh:SetBendHeight(bend_height)
			mesh:SetMaterialSlot(entry.subset_material_id)
			mesh:SetLODLevel(entry.lod_level)
			mesh:SetLODDistance(entry.lod_level * lod.CRY_RADII_PER_LEVEL)
			mesh:SetName(path)
			mesh:BuildBoundingBox()
			mesh:Upload(entry.indices)
			mesh_callback(mesh, material)
		end

		return true
	end, function(err)
		return err
	end)
	parsed.file:Close()

	if not ok then error(result, 0) end

	return {}
end

return cgf
