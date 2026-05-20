local T = import("test/environment.lua")
local Material = import("goluwa/render3d/material.lua")
local Texture = import("goluwa/render/texture.lua")
local vfs = import("goluwa/vfs.lua")
local cgf = import("goluwa/render3d/model_decoders/cgf.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local ffi = require("ffi")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function write_u32(parts, value)
	parts[#parts + 1] = string.char(
		bit.band(value, 0xFF),
		bit.band(bit.rshift(value, 8), 0xFF),
		bit.band(bit.rshift(value, 16), 0xFF),
		bit.band(bit.rshift(value, 24), 0xFF)
	)
end

local function build_fixture_744()
	local parts = {}
	parts[#parts + 1] = "CryTek\0\0"
	write_u32(parts, cgf.FILE_TYPE_GEOMETRY)
	write_u32(parts, cgf.VERSION_744)
	write_u32(parts, 20)
	write_u32(parts, 2)
	write_u32(parts, cgf.CHUNK_MTL_NAME)
	write_u32(parts, 0x80000800)
	write_u32(parts, 56)
	write_u32(parts, 4)
	write_u32(parts, cgf.CHUNK_MESH)
	write_u32(parts, 0x80000800)
	write_u32(parts, 84)
	write_u32(parts, 9)
	write_u32(parts, cgf.CHUNK_MTL_NAME)
	write_u32(parts, 0x80000800)
	write_u32(parts, 56)
	write_u32(parts, 4)
	parts[#parts + 1] = string.rep("A", 12)
	write_u32(parts, cgf.CHUNK_MESH)
	write_u32(parts, 0x80000800)
	write_u32(parts, 84)
	write_u32(parts, 9)
	parts[#parts + 1] = string.rep("B", 20)
	return table.concat(parts)
end

local function write_i32(parts, value)
	if value < 0 then value = value + 0x100000000 end

	write_u32(parts, value)
end

local function write_f32(parts, value)
	local packed = ffi.new("float[1]", value)
	parts[#parts + 1] = ffi.string(packed, 4)
end

local function write_vec2(parts, x, y)
	write_f32(parts, x)
	write_f32(parts, y)
end

local function write_vec3(parts, x, y, z)
	write_f32(parts, x)
	write_f32(parts, y)
	write_f32(parts, z)
end

local function write_chunk_entry(parts, type, version, offset, id)
	write_u32(parts, type)
	write_u32(parts, version)
	write_u32(parts, offset)
	write_u32(parts, id)
end

local function build_chunk(type, version, offset, id, body)
	local parts = {}
	write_u32(parts, type)
	write_u32(parts, version)
	write_u32(parts, offset)
	write_u32(parts, id)
	parts[#parts + 1] = body
	return table.concat(parts)
end

local function build_node_chunk_body(name, object_id, parent_id, material_id, position)
	local node_body = {}
	position = position or {0, 0, 0}
	node_body[#node_body + 1] = name .. string.rep("\0", 64 - #name)
	write_i32(node_body, object_id)
	write_i32(node_body, parent_id)
	write_i32(node_body, 0)
	write_i32(node_body, material_id)
	node_body[#node_body + 1] = string.char(0, 0, 0, 0)

	for i = 1, 16 do
		write_f32(node_body, (i == 1 or i == 6 or i == 11 or i == 16) and 1 or 0)
	end

	write_vec3(node_body, position[1], position[2], position[3])
	write_f32(node_body, 0)
	write_f32(node_body, 0)
	write_f32(node_body, 0)
	write_f32(node_body, 1)
	write_vec3(node_body, 1, 1, 1)
	write_i32(node_body, 0)
	write_i32(node_body, 0)
	write_i32(node_body, 0)
	write_i32(node_body, 0)
	return table.concat(node_body)
end

local function build_material_chunk_body(name)
	local parts = {}
	parts[#parts + 1] = string.char(18, 0, 0, 0, 0, 0, 0, 0)
	parts[#parts + 1] = name .. string.rep("\0", 128 - #name)
	return table.concat(parts)
end

local function build_static_mesh_fixture_744(options)
	options = options or {}
	local table_offset = 20
	local chunks = {}
	local material_name = options.material_name or "fixture_material"
	local subsets_body = {}
	write_i32(subsets_body, 0)
	write_i32(subsets_body, 1)
	write_i32(subsets_body, 0)
	write_i32(subsets_body, 0)
	write_i32(subsets_body, 0)
	write_i32(subsets_body, 3)
	write_i32(subsets_body, 0)
	write_i32(subsets_body, 3)
	write_i32(subsets_body, 0)
	write_f32(subsets_body, 1)
	write_vec3(subsets_body, 0, 0, 0)
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_MESH_SUBSETS,
		version = 0x800,
		id = 14,
		body = table.concat(subsets_body),
	}
	local positions_body = {}
	write_i32(positions_body, 0)
	write_i32(positions_body, 0)
	write_i32(positions_body, 3)
	write_i32(positions_body, 12)
	write_i32(positions_body, 0)
	write_i32(positions_body, 0)
	write_vec3(positions_body, 0, 0, 0)
	write_vec3(positions_body, 1, 0, 0)
	write_vec3(positions_body, 0, 1, 0)
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_DATA_STREAM,
		version = 0x800,
		id = 15,
		body = table.concat(positions_body),
	}
	local normals_body = {}
	write_i32(normals_body, 0)
	write_i32(normals_body, 1)
	write_i32(normals_body, 3)
	write_i32(normals_body, 12)
	write_i32(normals_body, 0)
	write_i32(normals_body, 0)
	write_vec3(normals_body, 0, 0, 1)
	write_vec3(normals_body, 0, 0, 1)
	write_vec3(normals_body, 0, 0, 1)
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_DATA_STREAM,
		version = 0x800,
		id = 16,
		body = table.concat(normals_body),
	}
	local uv_body = {}
	write_i32(uv_body, 0)
	write_i32(uv_body, 2)
	write_i32(uv_body, 3)
	write_i32(uv_body, 8)
	write_i32(uv_body, 0)
	write_i32(uv_body, 0)
	write_vec2(uv_body, 0, 0)
	write_vec2(uv_body, 1, 0)
	write_vec2(uv_body, 0, 1)
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_DATA_STREAM,
		version = 0x800,
		id = 17,
		body = table.concat(uv_body),
	}
	local index_body = {}
	write_i32(index_body, 0)
	write_i32(index_body, 5)
	write_i32(index_body, 3)
	write_i32(index_body, 2)
	write_i32(index_body, 0)
	write_i32(index_body, 0)
	index_body[#index_body + 1] = string.char(0, 0, 1, 0, 2, 0)
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_DATA_STREAM,
		version = 0x800,
		id = 19,
		body = table.concat(index_body),
	}
	chunks[#chunks + 1] = {
		type = cgf.CHUNK_MTL_NAME,
		version = 0x800,
		id = 4,
		body = build_material_chunk_body(material_name),
	}
	local mesh_body = {}
	write_i32(mesh_body, 0)
	write_i32(mesh_body, 0)
	write_i32(mesh_body, 3)
	write_i32(mesh_body, 3)
	write_i32(mesh_body, 1)
	write_i32(mesh_body, 14)
	write_i32(mesh_body, 0)

	for _, stream_id in ipairs{15, 16, 17, 0, 0, 19} do
		write_i32(mesh_body, stream_id)
	end

	for _ = 7, 16 do
		write_i32(mesh_body, 0)
	end

	for _ = 1, 4 do
		write_i32(mesh_body, 0)
	end

	write_vec3(mesh_body, 0, 0, 0)
	write_vec3(mesh_body, 1, 1, 0)
	write_f32(mesh_body, 0)

	for _ = 1, 31 do
		write_i32(mesh_body, 0)
	end

	chunks[#chunks + 1] = {
		type = cgf.CHUNK_MESH,
		version = 0x800,
		id = 22,
		body = table.concat(mesh_body),
	}

	if options.parent_position then
		chunks[#chunks + 1] = {
			type = cgf.CHUNK_NODE,
			version = 0x823,
			id = 21,
			body = build_node_chunk_body("parent", 0, -1, 0, options.parent_position),
		}
	end

	local node_chunk = {
		type = cgf.CHUNK_NODE,
		version = 0x823,
		id = 23,
		body = build_node_chunk_body(
			"root",
			22,
			options.parent_position and 21 or -1,
			4,
			options.node_position
		),
	}
	chunks[#chunks + 1] = node_chunk
	local chunk_count = #chunks
	local data_offset = table_offset + 4 + (chunk_count * 16)
	local next_offset = data_offset

	for _, chunk in ipairs(chunks) do
		chunk.offset = next_offset
		chunk.payload = build_chunk(chunk.type, 0x80000000 + chunk.version, next_offset, chunk.id, chunk.body)
		next_offset = next_offset + #chunk.payload
	end

	local out = {}
	out[#out + 1] = "CryTek\0\0"
	write_u32(out, cgf.FILE_TYPE_GEOMETRY)
	write_u32(out, cgf.VERSION_744)
	write_u32(out, table_offset)
	write_u32(out, chunk_count)

	for _, chunk in ipairs(chunks) do
		write_chunk_entry(out, chunk.type, 0x80000000 + chunk.version, chunk.offset, chunk.id)
	end

	for _, chunk in ipairs(chunks) do
		out[#out + 1] = chunk.payload
	end

	return table.concat(out)
end

T.Test("CGF parser reads old CryTek header and infers 0x744 chunk sizes", function()
	local path = "os:" .. vfs.GetStorageDirectory("shared") .. "cgf_test_parser_744.cgf"
	assert(vfs.Write(path, build_fixture_744()))
	local file = assert(vfs.Open(path))
	local header = cgf.ReadHeader(file)
	T(header.file_type)["=="](cgf.FILE_TYPE_GEOMETRY)
	T(header.version)["=="](cgf.VERSION_744)
	T(header.chunk_table_offset)["=="](20)
	local chunks = cgf.ReadChunks(file, header)
	T(#chunks)["=="](2)
	T(chunks[1].type)["=="](cgf.CHUNK_MTL_NAME)
	T(chunks[1].version)["=="](0x800)
	T(chunks[1].size)["=="](28)
	T(chunks[2].type)["=="](cgf.CHUNK_MESH)
	T(chunks[2].size)["=="](36)
	local embedded = cgf.ReadChunkEmbeddedHeader(file, chunks[1])
	T(embedded.type)["=="](chunks[1].type)
	T(embedded.version)["=="](chunks[1].version)
	T(embedded.offset)["=="](chunks[1].offset)
	file:Close()
	vfs.Delete(path)
end)

T.Test("CGF decoder registers for .cgf files", function()
	T(model_loader.FindModelDecoder("models/test.cgf") ~= nil)["=="](true)
end)

T.Test("CGF parser extracts a static triangle mesh from chunked streams", function()
	local path = "os:" .. vfs.GetStorageDirectory("shared") .. "cgf_test_static_mesh_744.cgf"
	assert(vfs.Write(path, build_static_mesh_fixture_744()))
	local parsed = cgf.Open(path)
	local entries = cgf.ExtractStaticMeshData(parsed)
	T(#entries)["=="](1)
	T(entries[1].name)["=="]("root")
	T(entries[1].material_name)["=="]("fixture_material")
	T(#entries[1].vertices)["=="](3)
	T(#entries[1].indices)["=="](3)
	T(entries[1].indices[1])["=="](1)
	T(entries[1].indices[2])["=="](3)
	T(entries[1].indices[3])["=="](2)
	T(entries[1].vertices[2].pos.x)["~"](1)
	T(entries[1].vertices[3].pos.z)["~"](-1)
	T(entries[1].vertices[1].normal.y)["~"](1)
	T(entries[1].vertices[2].uv.x)["~"](1)
	parsed.file:Close()
	vfs.Delete(path)
end)

T.Test("CGF node world transforms compose parent and local translation", function()
	local nodes = {
		[1] = {
			id = 1,
			parent_id = -1,
			position = Vec3(10, 0, 0),
			rotation = Quat(0, 0, 0, 1),
			scale = Vec3(1, 1, 1),
		},
		[2] = {
			id = 2,
			parent_id = 1,
			position = Vec3(1, 2, 3),
			rotation = Quat(0, 0, 0, 1),
			scale = Vec3(1, 1, 1),
		},
	}
	local world = cgf.GetNodeWorldTransform(nodes, 2)
	local origin = world:TransformVector(Vec3(0, 0, 0))
	T(origin.x)["~"](11)
	T(origin.y)["~"](2)
	T(origin.z)["~"](3)
end)

T.Test("CGF extraction applies node translation before emitting vertices", function()
	local path = "os:" .. vfs.GetStorageDirectory("shared") .. "cgf_test_static_mesh_translated_744.cgf"
	assert(
		vfs.Write(
			path,
			build_static_mesh_fixture_744{parent_position = {10, 0, 0}, node_position = {1, 2, 3}}
		)
	)
	local parsed = cgf.Open(path)
	local entries = cgf.ExtractStaticMeshData(parsed)
	T(#entries)["=="](1)
	T(entries[1].vertices[1].pos.x)["~"](11)
	T(entries[1].vertices[1].pos.y)["~"](3)
	T(entries[1].vertices[1].pos.z)["~"](-2)
	T(entries[1].vertices[2].pos.x)["~"](12)
	parsed.file:Close()
	vfs.Delete(path)
end)

T.Test("CryMTL loader resolves submaterial textures with dds fallback", function()
	local mount_root = "os:" .. vfs.GetStorageDirectory("shared") .. "cgf_crymtl_test"
	assert(vfs.CreateDirectory(mount_root))
	assert(vfs.CreateDirectory(mount_root .. "/Game"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Objects.pak"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Objects.pak/materials"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Objects.pak/objects"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Objects.pak/objects/demo"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Textures.pak"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Textures.pak/textures"))
	assert(vfs.CreateDirectory(mount_root .. "/Game/Textures.pak/textures/demo"))
	assert(
		vfs.Write(
			mount_root .. "/Game/Objects.pak/materials/demo.mtl",
			[[<Material><SubMaterials><Material Name="rock" Diffuse="0.25,0.5,0.75" Opacity="1" Shader="Vegetation" AlphaTest="0.5"><Textures><Texture Map="Diffuse" File="objects/demo/albedo.tif" /><Texture Map="Normalmap" File="objects/demo/normal.tif" /><Texture Map="Specular" File="textures/demo/spec.tif" /><Texture Map="Opacity" File="objects/demo/spec.tif" /></Textures><PublicParams BackDiffuse="0.2,0.4,0.6" BackDiffuseMultiplier="1.5" BackViewDep="0.7" /></Material></SubMaterials></Material>]]
		)
	)
	assert(vfs.Write(mount_root .. "/Game/Objects.pak/objects/demo/albedo.dds", "dds"))
	assert(vfs.Write(mount_root .. "/Game/Objects.pak/objects/demo/normal.dds", "dds"))
	assert(vfs.Write(mount_root .. "/Game/Textures.pak/textures/demo/spec.dds", "dds"))
	local old_texture_new = Texture.New
	local created = {}
	Texture.New = function(config)
		created[#created + 1] = {path = config.path, srgb = config.srgb}
		return {
			config = config,
			Shade = function() end,
			GetWidth = function()
				return 4
			end,
			GetHeight = function()
				return 4
			end,
			GetMipMapLevels = function()
				return 1
			end,
			GetSamplerConfig = function()
				return {
					min_filter = "linear",
					mag_filter = "linear",
					mipmap_mode = "linear",
					wrap_s = "repeat",
					wrap_t = "repeat",
				}
			end,
			IsReady = function()
				return true
			end,
		}
	end
	local material = Material.FromCryMTL(mount_root .. "/Game/Objects.pak/materials/demo.mtl", 0)
	Texture.New = old_texture_new
	T(material.cry_sub_material_name)["=="]("rock")
	T(#created)["=="](5)
	T(created[1].path)["=="](mount_root .. "/Game/Objects.pak/objects/demo/albedo.dds")
	T(created[1].srgb)["=="](true)
	T(created[2].path)["=="](mount_root .. "/Game/Objects.pak/objects/demo/normal.dds")
	T(created[2].srgb)["=="](false)
	T(created[3].path)["=="](mount_root .. "/Game/Textures.pak/textures/demo/spec.dds")
	T(created[3].srgb)["=="](false)
	T(created[4].path)["=="](nil)
	T(created[5].path)["=="](mount_root .. "/Game/Textures.pak/textures/demo/spec.dds")
	T(created[5].srgb)["=="](false)
	T(material:GetAlphaTest())["=="](true)
	T(material:GetAlphaCutoff())["=="](0.5)
	T(material:GetDoubleSided())["=="](true)
	T(material:GetSubsurface())["=="](true)
	T(material:GetOpacityTexture() ~= nil)["=="](true)
	T(material:GetRoughnessTexture() ~= nil)["=="](true)
	T(material:GetMetallicMultiplier())["=="](0)
	T(math.abs(material:GetTransmissionColor().r - 0.2))["<"](0.0001)
	T(math.abs(material:GetTransmissionColor().g - 0.4))["<"](0.0001)
	T(math.abs(material:GetTransmissionColor().b - 0.6))["<"](0.0001)
	T(math.abs(material:GetTransmissionColor().a - 1.5))["<"](0.0001)
	T(math.abs(material:GetTransmissionViewDependency() - 0.7))["<"](0.0001)
	T(material:GetTransmissionBlocking())["=="](1)
	T(material:GetReverseXZNormalMap())["=="](true)
	T(material:GetInvertRoughnessTexture())["=="](false)
	vfs.Delete(mount_root .. "/Game/Objects.pak/materials/demo.mtl")
	vfs.Delete(mount_root .. "/Game/Objects.pak/objects/demo/albedo.dds")
	vfs.Delete(mount_root .. "/Game/Objects.pak/objects/demo/normal.dds")
	vfs.Delete(mount_root .. "/Game/Textures.pak/textures/demo/spec.dds")
end)
