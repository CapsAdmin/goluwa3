local vfs = import("goluwa/vfs.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Material = import("goluwa/render3d/material.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local cgf = {}
cgf.FILE_TYPE_GEOMETRY = 0xFFFF0000
cgf.FILE_TYPE_ANIMATION = 0xFFFF0001
cgf.VERSION_744 = 0x744
cgf.VERSION_745 = 0x745
cgf.CHUNK_MESH = 0xCCCC0000
cgf.CHUNK_HELPER = 0xCCCC0001
cgf.CHUNK_NODE = 0xCCCC000B
cgf.CHUNK_MTL_NAME = 0xCCCC0014
cgf.CHUNK_EXPORT_FLAGS = 0xCCCC0015
cgf.CHUNK_DATA_STREAM = 0xCCCC0016
cgf.CHUNK_MESH_SUBSETS = 0xCCCC0017
cgf.CHUNK_MESH_PHYSICS_DATA = 0xCCCC0018

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

local function cry_vec3_to_engine(vec)
	return Vec3(vec.x, vec.z, -vec.y)
end

local function transform_direction(matrix, vec)
	local origin = matrix:TransformVector(Vec3(0, 0, 0))
	return (matrix:TransformVector(vec) - origin):GetNormalized()
end

local function clone_vertices(vertices)
	local out = {}

	for index, vertex in ipairs(vertices) do
		out[index] = {
			pos = vertex.pos and vertex.pos:Copy() or nil,
			normal = vertex.normal and vertex.normal:Copy() or nil,
			uv = vertex.uv and vertex.uv:Copy() or nil,
			texture_blend = vertex.texture_blend,
			vertex_color = vertex.vertex_color and
				{
					r = vertex.vertex_color.r,
					g = vertex.vertex_color.g,
					b = vertex.vertex_color.b,
					a = vertex.vertex_color.a,
				} or
				nil,
			tangent = vertex.tangent and
				{
					x = vertex.tangent.x or vertex.tangent[1],
					y = vertex.tangent.y or vertex.tangent[2],
					z = vertex.tangent.z or vertex.tangent[3],
					w = vertex.tangent.w or vertex.tangent[4],
				} or
				nil,
		}
	end

	return out
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
		file_type = file:ReadUnsignedLong(),
		version = file:ReadUnsignedLong(),
		chunk_table_offset = file:ReadUnsignedLong(),
	}
	assert_old_cgf_version(header.version)
	return header
end

function cgf.ReadChunks(file, header)
	header = header or cgf.ReadHeader(file)
	file:PushPosition(header.chunk_table_offset)
	local chunk_count = file:ReadUnsignedLong()
	local entry_size = get_chunk_entry_size(header.version)
	local chunks = {}

	for index = 1, chunk_count do
		local chunk = {
			index = index,
			type = file:ReadUnsignedLong(),
			raw_version = file:ReadUnsignedLong(),
			offset = file:ReadUnsignedLong(),
			id = file:ReadUnsignedLong(),
		}
		chunk.version = normalize_chunk_version(chunk.raw_version)

		if entry_size == 20 then chunk.size = file:ReadUnsignedLong() end

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
		type = file:ReadUnsignedLong(),
		raw_version = file:ReadUnsignedLong(),
		offset = file:ReadUnsignedLong(),
		id = file:ReadUnsignedLong(),
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
		flags = file:ReadLong(),
		flags2 = file:ReadLong(),
		num_vertices = file:ReadLong(),
		num_indices = file:ReadLong(),
		num_subsets = file:ReadLong(),
		subsets_chunk_id = file:ReadLong(),
		vertex_animation_chunk_id = file:ReadLong(),
		stream_chunk_ids = {},
		physics_data_chunk_ids = {},
	}

	for index = 1, 16 do
		mesh.stream_chunk_ids[index] = file:ReadLong()
	end

	for index = 1, 4 do
		mesh.physics_data_chunk_ids[index] = file:ReadLong()
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
		flags = file:ReadLong(),
		count = file:ReadLong(),
		subsets = {},
	}
	file:Advance(8)

	for index = 1, out.count do
		out.subsets[index] = {
			first_index = file:ReadLong(),
			num_indices = file:ReadLong(),
			first_vertex = file:ReadLong(),
			num_vertices = file:ReadLong(),
			material_id = file:ReadLong(),
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
		flags = file:ReadLong(),
		stream_type = file:ReadLong(),
		count = file:ReadLong(),
		element_size = file:ReadLong(),
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
			stream.values[index] = file:ReadUnsignedShort() + 1
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
		kind = file:ReadLong(),
		flags = file:ReadLong(),
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
		object_id = file:ReadLong(),
		parent_id = file:ReadLong(),
		num_children = file:ReadLong(),
		material_chunk_id = file:ReadLong(),
		is_group_head = file:ReadByte() ~= 0,
		is_group_member = file:ReadByte() ~= 0,
	}
	file:Advance(2)
	file:Advance(16 * 4)
	node.position = read_vec3(file)
	node.rotation = Quat(file:ReadFloat(), file:ReadFloat(), file:ReadFloat(), file:ReadFloat())
	node.scale = read_vec3(file)
	node.position_controller_id = file:ReadLong()
	node.rotation_controller_id = file:ReadLong()
	node.scale_controller_id = file:ReadLong()
	file:PopPosition()
	return node
end

function cgf.BuildNodeLocalTransform(node)
	local matrix = Matrix44()
	matrix:SetRotation(node.rotation or Quat(0, 0, 0, 1))
	matrix:Scale(node.scale.x, node.scale.y, node.scale.z)
	matrix:SetTranslation(node.position.x, node.position.y, node.position.z)
	return matrix
end

function cgf.GetNodeWorldTransform(nodes_by_id, node_id, cache, visiting)
	cache = cache or {}

	if cache[node_id] then return cache[node_id] end

	visiting = visiting or {}

	if visiting[node_id] then error("cgf node cycle at " .. tostring(node_id)) end

	local node = assert(nodes_by_id[node_id], "unknown cgf node " .. tostring(node_id))
	local local_transform = cgf.BuildNodeLocalTransform(node)
	visiting[node_id] = true

	if node.parent_id and node.parent_id > -1 and nodes_by_id[node.parent_id] then
		cache[node_id] = cgf.GetNodeWorldTransform(nodes_by_id, node.parent_id, cache, visiting) * local_transform
	else
		cache[node_id] = local_transform
	end

	visiting[node_id] = nil
	return cache[node_id]
end

local function build_children_by_parent(nodes_by_id)
	local children_by_parent = {}

	for _, node in pairs(nodes_by_id) do
		local parent_id = node.parent_id or -1
		children_by_parent[parent_id] = children_by_parent[parent_id] or {}
		children_by_parent[parent_id][#children_by_parent[parent_id] + 1] = node.id
	end

	return children_by_parent
end

local function get_helper_pivots_for_node(parsed, nodes_by_id, children_by_parent, world_transforms, node_id)
	local out = {}
	local seen = {}
	local current_id = node_id

	while current_id and current_id > -1 and nodes_by_id[current_id] do
		local root_transform = cgf.GetNodeWorldTransform(nodes_by_id, current_id, world_transforms)
		local root_origin = cry_vec3_to_engine(root_transform:TransformVector(Vec3(0, 0, 0)))

		if
			not seen[string.format("%.6f:%.6f:%.6f", root_origin.x, root_origin.y, root_origin.z)]
		then
			out[#out + 1] = root_origin
			seen[string.format("%.6f:%.6f:%.6f", root_origin.x, root_origin.y, root_origin.z)] = true
		end

		local stack = children_by_parent[current_id] and {unpack(children_by_parent[current_id])} or {}

		while stack[1] do
			local child_id = table.remove(stack)
			local child = nodes_by_id[child_id]

			if child then
				local object_chunk = child.object_id > 0 and parsed.chunks_by_id[child.object_id] or nil

				if object_chunk and object_chunk.type == cgf.CHUNK_HELPER then
					local helper_transform = cgf.GetNodeWorldTransform(nodes_by_id, child.id, world_transforms)
					local helper_origin = cry_vec3_to_engine(helper_transform:TransformVector(Vec3(0, 0, 0)))
					local key = string.format("%.6f:%.6f:%.6f", helper_origin.x, helper_origin.y, helper_origin.z)

					if not seen[key] then
						out[#out + 1] = helper_origin
						seen[key] = true
					end
				end

				local children = children_by_parent[child.id]

				if children then
					for i = 1, #children do
						stack[#stack + 1] = children[i]
					end
				end
			end
		end

		if #out > 1 then break end

		current_id = nodes_by_id[current_id].parent_id
	end

	return out
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
	local children_by_parent = build_children_by_parent(nodes_by_id)

	for _, node_id in ipairs(node_order) do
		local node = nodes_by_id[node_id]

		if node.object_id > 0 and not node.name:starts_with("$") then
			local mesh_chunk = parsed.chunks_by_id[node.object_id]

			if mesh_chunk and mesh_chunk.type == cgf.CHUNK_MESH then
				local world_transform = cgf.GetNodeWorldTransform(nodes_by_id, node.id, world_transforms)
				local helper_pivots = get_helper_pivots_for_node(
					parsed,
					nodes_by_id,
					children_by_parent,
					world_transforms,
					node.id
				)
				local mesh = cgf.ReadMeshChunk(file, mesh_chunk)
				local subsets_chunk = parsed.chunks_by_id[mesh.subsets_chunk_id]
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
					local transformed_position = cry_vec3_to_engine(world_transform:TransformVector(pos))
					local transformed_normal = normals[index] and
						cry_vec3_to_engine(transform_direction(world_transform, normals[index])) or
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
					local shared_vertices = #subsets.subsets > 1

					for _, subset in ipairs(subsets.subsets) do
						if subset.num_indices <= 0 then goto continue_subset end

						local subset_indices = {}

						for index = subset.first_index + 1, subset.first_index + subset.num_indices do
							subset_indices[#subset_indices + 1] = indices[index]
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
							branch_helper_pivots = helper_pivots,
							vertices_shared = shared_vertices,
							vertices = base_vertices,
							indices = subset_indices,
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
						branch_helper_pivots = helper_pivots,
						vertices_shared = false,
						vertices = base_vertices,
						indices = fixed_indices,
					}
				end
			end
		end
	end

	return entries
end

function cgf.DecodeModel(path, full_path, mesh_callback)
	local ok_open, parsed_or_err = pcall(cgf.Open, full_path)

	if not ok_open then
		error(("failed to open cgf %q from %q: %s"):format(path, full_path, parsed_or_err), 0)
	end

	local parsed = parsed_or_err
	local material_root = vfs.GetFolderFromPath(parsed.file.path_used or full_path)
	local package_material_root = material_root and ("crytek package:" .. material_root) or nil
	local resolved_material_paths = {}
	local ok, result = xpcall(function()
		for _, entry in ipairs(cgf.ExtractStaticMeshData(parsed)) do
			local mesh = Polygon3D.New()
			local material = nil

			if entry.material_name then
				local material_path = material_root .. entry.material_name .. ".mtl"
				local resolved_material_path = resolved_material_paths[material_path]

				if resolved_material_path == nil then
					resolved_material_path = vfs.FindMixedCasePath(material_path) or material_path

					if not vfs.IsFile(resolved_material_path) and package_material_root then
						resolved_material_path = vfs.FindFileByNameRecursive(package_material_root, entry.material_name .. ".mtl") or
							resolved_material_path
					end

					resolved_material_paths[material_path] = resolved_material_path
				end

				if vfs.IsFile(resolved_material_path) then
					material = Material.FromCryMTL(resolved_material_path, entry.subset_material_id)
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

			if entry.vertices_shared then
				mesh:SetVertices(clone_vertices(entry.vertices))
			else
				mesh:SetVertices(entry.vertices)
			end

			mesh:SetBranchHelperPivots(entry.branch_helper_pivots)
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
