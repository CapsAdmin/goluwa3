local ffi = require("ffi")
local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local base64 = import("goluwa/codecs/base64.lua")
local gltf = library()
local COMPONENT_TYPE = {
	[5120] = {type = "int8_t", size = 1},
	[5121] = {type = "uint8_t", size = 1},
	[5122] = {type = "int16_t", size = 2},
	[5123] = {type = "uint16_t", size = 2},
	[5125] = {type = "uint32_t", size = 4},
	[5126] = {type = "float", size = 4},
}

for i, info in pairs(COMPONENT_TYPE) do
	info.pointer = ffi.typeof(info.type .. "*")
	info.array = ffi.typeof(info.type .. "[?]")
end

local ACCESSOR_TYPE = {
	SCALAR = 1,
	VEC2 = 2,
	VEC3 = 3,
	VEC4 = 4,
	MAT2 = 4,
	MAT3 = 9,
	MAT4 = 16,
}
local PRIMITIVE_MODE = {
	[0] = "points",
	[1] = "lines",
	[2] = "line_loop",
	[3] = "line_strip",
	[4] = "triangles",
	[5] = "triangle_strip",
	[6] = "triangle_fan",
}

local function get_directory(path)
	if not path then debug.trace() end

	return path:match("(.*/)") or ""
end

local function load_buffer(base_dir, buffer_info)
	if buffer_info.uri then
		if buffer_info.uri:match("^data:") then
			local base64_data = buffer_info.uri:match("^data:[^;]+;base64,(.+)$")

			if base64_data then return base64.Decode(base64_data) end
		else
			local path = base_dir .. buffer_info.uri
			local data = fs.read_file(path)
			return data
		end
	end

	return nil
end

-- Read accessor data as a raw C array (position/normal/... stay in glTF's own layout, no coordinate or engine translation)
local function read_accessor_raw(gltf_data, accessor_index, buffers)
	local accessor = gltf_data.accessors[accessor_index + 1]
	local buffer_view = gltf_data.bufferViews[accessor.bufferView + 1]
	local buffer = buffers[buffer_view.buffer + 1]
	local component_info = COMPONENT_TYPE[accessor.componentType]
	local component_count = ACCESSOR_TYPE[accessor.type]
	local byte_offset = (buffer_view.byteOffset or 0) + (accessor.byteOffset or 0)
	local byte_stride = buffer_view.byteStride or (component_info.size * component_count)
	local buffer_ptr = ffi.cast("uint8_t*", buffer)
	local total_elements = accessor.count * component_count
	local element_size = component_info.size
	local c_array = ffi.new(component_info.array, total_elements)
	local c_type = ffi.new(component_info.pointer)

	for i = 0, accessor.count - 1 do
		local offset = byte_offset + i * byte_stride
		local src_ptr = ffi.cast(c_type, buffer_ptr + offset)

		for j = 0, component_count - 1 do
			c_array[i * component_count + j] = src_ptr[j]
		end
	end

	return {
		data = c_array,
		count = accessor.count,
		total_elements = total_elements,
		component_type = component_info.type,
		component_count = component_count,
		byte_size = total_elements * element_size,
		min = accessor.min,
		max = accessor.max,
	}
end

local function decode_texture_ref(ref)
	if not ref then return nil end

	return {index = ref.index, tex_coord = ref.texCoord}
end

local function decode_material(material_info)
	local material = {
		name = material_info.name,
		double_sided = material_info.doubleSided or false,
		alpha_mode = material_info.alphaMode or "OPAQUE",
		alpha_cutoff = material_info.alphaCutoff or 0.5,
		normal_texture = material_info.normalTexture and
			{
				index = material_info.normalTexture.index,
				scale = material_info.normalTexture.scale,
			},
		occlusion_texture = material_info.occlusionTexture and
			{
				index = material_info.occlusionTexture.index,
				strength = material_info.occlusionTexture.strength,
			},
		emissive_texture = decode_texture_ref(material_info.emissiveTexture),
		emissive_factor = material_info.emissiveFactor,
	}
	local pbr = material_info.pbrMetallicRoughness

	if pbr then
		material.pbr_metallic_roughness = {
			base_color_factor = pbr.baseColorFactor,
			base_color_texture = decode_texture_ref(pbr.baseColorTexture),
			metallic_factor = pbr.metallicFactor,
			roughness_factor = pbr.roughnessFactor,
			metallic_roughness_texture = decode_texture_ref(pbr.metallicRoughnessTexture),
		}
	end

	local spec_gloss = material_info.extensions and
		material_info.extensions.KHR_materials_pbrSpecularGlossiness

	if spec_gloss then
		material.pbr_specular_glossiness = {
			diffuse_factor = spec_gloss.diffuseFactor,
			diffuse_texture = decode_texture_ref(spec_gloss.diffuseTexture),
			glossiness_factor = spec_gloss.glossinessFactor,
			specular_factor = spec_gloss.specularFactor,
			specular_glossiness_texture = decode_texture_ref(spec_gloss.specularGlossinessTexture),
		}
	end

	return material
end

-- Decode a glTF file into plain data: buffers, accessors, materials, meshes, nodes and scenes,
-- kept in glTF's own vocabulary and coordinate system. Building an engine entity hierarchy,
-- GPU meshes/materials/textures out of this data is the job of whatever uses this codec.
function gltf.Load(path)
	local base_dir = get_directory(path)
	local json_data = fs.read_file(path)

	if not json_data then return nil, "Failed to read file: " .. path end

	local gltf_data = json.decode(json_data)

	if not gltf_data.asset or gltf_data.asset.version ~= "2.0" then
		return nil, "Only glTF 2.0 is supported"
	end

	local SUPPORTED_EXTENSIONS = {
		MSFT_texture_dds = true,
		KHR_materials_pbrSpecularGlossiness = true,
		EXT_mesh_gpu_instancing = true,
	}

	if gltf_data.extensionsRequired then
		for _, ext in ipairs(gltf_data.extensionsRequired) do
			if not SUPPORTED_EXTENSIONS[ext] then
				return nil, "Required extension '" .. ext .. "' is not supported"
			end
		end
	end

	if gltf_data.extensionsUsed then
		for _, ext in ipairs(gltf_data.extensionsUsed) do
			if not SUPPORTED_EXTENSIONS[ext] then
				print("WARNING: glTF extension '" .. ext .. "' is used but not fully supported")
			end
		end
	end

	local buffers = {}

	if gltf_data.buffers then
		for i, buffer_info in ipairs(gltf_data.buffers) do
			local buffer_data = load_buffer(base_dir, buffer_info)

			if buffer_data then
				local c_buffer = ffi.new("uint8_t[?]", #buffer_data)
				ffi.copy(c_buffer, buffer_data, #buffer_data)
				buffers[i] = c_buffer
			end
		end
	end

	local result = {
		path = path,
		base_dir = base_dir,
		raw = gltf_data,
		buffers = buffers,
		meshes = {},
		materials = {},
		textures = {},
		images = {},
		nodes = {},
		scenes = {},
	}

	if gltf_data.images then
		for i, image_info in ipairs(gltf_data.images) do
			result.images[i] = {
				uri = image_info.uri,
				mime_type = image_info.mimeType,
				path = image_info.uri and (base_dir .. image_info.uri) or nil,
				buffer_view = image_info.bufferView,
			}
		end
	end

	if gltf_data.textures then
		for i, texture_info in ipairs(gltf_data.textures) do
			local source = texture_info.source

			-- Prefer DDS over the default source when present
			if texture_info.extensions and texture_info.extensions.MSFT_texture_dds then
				source = texture_info.extensions.MSFT_texture_dds.source
			end

			result.textures[i] = {source = source, sampler = texture_info.sampler}
		end
	end

	if gltf_data.materials then
		for i, material_info in ipairs(gltf_data.materials) do
			result.materials[i] = decode_material(material_info)
		end
	end

	if gltf_data.meshes then
		for i, mesh_info in ipairs(gltf_data.meshes) do
			local mesh = {name = mesh_info.name, primitives = {}}

			for j, primitive_info in ipairs(mesh_info.primitives) do
				local primitive = {
					mode = PRIMITIVE_MODE[primitive_info.mode or 4],
					material = primitive_info.material,
					attributes = {},
				}

				if primitive_info.indices ~= nil then
					primitive.indices = read_accessor_raw(gltf_data, primitive_info.indices, buffers)
				end

				for attr_name, accessor_index in pairs(primitive_info.attributes) do
					primitive.attributes[attr_name] = read_accessor_raw(gltf_data, accessor_index, buffers)
				end

				mesh.primitives[j] = primitive
			end

			result.meshes[i] = mesh
		end
	end

	if gltf_data.nodes then
		for i, node_info in ipairs(gltf_data.nodes) do
			result.nodes[i] = {
				name = node_info.name,
				mesh = node_info.mesh,
				camera = node_info.camera,
				children = node_info.children,
				translation = node_info.translation or {0, 0, 0},
				rotation = node_info.rotation or {0, 0, 0, 1},
				scale = node_info.scale or {1, 1, 1},
				matrix = node_info.matrix,
			}
			-- EXT_mesh_gpu_instancing: one node + mesh represents many instances via
			-- per-instance TRANSLATION/ROTATION/SCALE accessor arrays, instead of one
			-- node per instance (what exporters use for large scatter/foliage counts)
			local instancing_ext = node_info.extensions and node_info.extensions.EXT_mesh_gpu_instancing

			if instancing_ext and instancing_ext.attributes then
				local attributes = instancing_ext.attributes
				result.nodes[i].gpu_instancing = {
					translation = attributes.TRANSLATION and
						read_accessor_raw(gltf_data, attributes.TRANSLATION, buffers),
					rotation = attributes.ROTATION and
						read_accessor_raw(gltf_data, attributes.ROTATION, buffers),
					scale = attributes.SCALE and read_accessor_raw(gltf_data, attributes.SCALE, buffers),
				}
			end
		end
	end

	if gltf_data.scenes then
		for i, scene_info in ipairs(gltf_data.scenes) do
			result.scenes[i] = {name = scene_info.name, nodes = scene_info.nodes}
		end
	end

	result.scene = gltf_data.scene or 0
	return result
end

gltf.file_extensions = {"gltf"}
return gltf
