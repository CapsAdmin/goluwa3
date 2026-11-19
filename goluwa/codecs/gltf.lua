local ffi = require("ffi")
local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local base64 = import("goluwa/codecs/base64.lua")
local meshopt = import("goluwa/codecs/meshopt.lua")
local gltf = {}
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

local GLB_MAGIC = "glTF"
local GLB_CHUNK_JSON = 0x4E4F534A
local GLB_CHUNK_BIN = 0x004E4942
local U32_PTR = ffi.typeof("const uint32_t *")
local CHAR_PTR = ffi.typeof("const char *")

local function split_glb(data)
	local header = ffi.cast(U32_PTR, ffi.cast(CHAR_PTR, data) + 4)

	if header[0] ~= 2 then error("Only GLB version 2 is supported", 0) end

	local json_data, bin_data
	local offset = 12

	while offset + 8 <= #data do
		local chunk = ffi.cast(U32_PTR, ffi.cast(CHAR_PTR, data) + offset)
		local chunk_size = chunk[0]

		if chunk[1] == GLB_CHUNK_JSON then
			json_data = data:sub(offset + 9, offset + 8 + chunk_size)
		elseif chunk[1] == GLB_CHUNK_BIN then
			bin_data = data:sub(offset + 9, offset + 8 + chunk_size)
		end

		offset = offset + 8 + chunk_size
	end

	return json_data, bin_data
end

local SMALL_BUFFER_BYTES = 4 * 1024 * 1024
local LFS_POINTER = "version https://git-lfs"

local function read_file_checked(path)
	local data, err = fs.read_file(path)

	if data and data:sub(1, #LFS_POINTER) == LFS_POINTER then
		return nil, path .. " is a git lfs pointer, run git lfs pull"
	end

	return data, err
end

local function load_buffer(base_dir, buffer_info, embedded)
	if not buffer_info.uri then
		return embedded
	else
		if buffer_info.uri:match("^data:") then
			local base64_data = buffer_info.uri:match("^data:[^;]+;base64,(.+)$")

			if base64_data then return base64.Decode(base64_data) end
		else
			local path = base_dir .. buffer_info.uri
			return assert(read_file_checked(path))
		end
	end

	return nil
end

local function read_accessor_raw(gltf_data, accessor_index, buffers)
	local accessor = gltf_data.accessors[accessor_index + 1]
	local buffer_view = gltf_data.bufferViews[accessor.bufferView + 1]
	local compression = buffer_view.extensions and buffer_view.extensions.EXT_meshopt_compression
	local buffer
	local view_offset = buffer_view.byteOffset or 0

	if compression then
		local source = ffi.cast("uint8_t*", buffers[compression.buffer + 1]) + (
				compression.byteOffset or
				0
			)

		if compression.mode == "ATTRIBUTES" then
			buffer = meshopt.DecodeVertexBuffer(compression.count, compression.byteStride, source, compression.byteLength)
		elseif compression.mode == "TRIANGLES" then
			buffer = meshopt.DecodeIndexBuffer(compression.count, compression.byteStride, source, compression.byteLength)
		else
			error("unsupported EXT_meshopt_compression mode " .. tostring(compression.mode))
		end

		view_offset = 0
	else
		buffer = buffers[buffer_view.buffer + 1]
	end

	local component_info = COMPONENT_TYPE[accessor.componentType]
	local component_count = ACCESSOR_TYPE[accessor.type]
	local byte_offset = view_offset + (accessor.byteOffset or 0)
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

	local transform = ref.extensions and ref.extensions.KHR_texture_transform
	return {
		index = ref.index,
		tex_coord = ref.texCoord,
		scale = ref.scale,
		strength = ref.strength,
		transform = transform and
			{
				offset = transform.offset or {0, 0},
				scale = transform.scale or {1, 1},
				rotation = transform.rotation or 0,
			},
	}
end

local function decode_material(material_info)
	local material = {
		name = material_info.name,
		double_sided = material_info.doubleSided or false,
		alpha_mode = material_info.alphaMode or "OPAQUE",
		alpha_cutoff = material_info.alphaCutoff or 0.5,
		normal_texture = decode_texture_ref(material_info.normalTexture),
		occlusion_texture = decode_texture_ref(material_info.occlusionTexture),
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

	local extensions = material_info.extensions or {}

	if extensions.KHR_materials_transmission then
		material.transmission_factor = extensions.KHR_materials_transmission.transmissionFactor or 0
	end

	if extensions.KHR_materials_ior then
		material.ior = extensions.KHR_materials_ior.ior or 1.5
	end

	if extensions.KHR_materials_dispersion then
		material.dispersion = extensions.KHR_materials_dispersion.dispersion or 0
	end

	if extensions.KHR_materials_volume then
		material.thickness_factor = extensions.KHR_materials_volume.thicknessFactor or 0
		material.attenuation_color = extensions.KHR_materials_volume.attenuationColor
		material.attenuation_distance = extensions.KHR_materials_volume.attenuationDistance
	end

	if extensions.KHR_materials_emissive_strength then
		material.emissive_strength = extensions.KHR_materials_emissive_strength.emissiveStrength or 1
	end

	if extensions.KHR_materials_unlit then material.unlit = true end

	if extensions.KHR_materials_specular then
		material.specular_factor = extensions.KHR_materials_specular.specularFactor or 1
	end

	if extensions.KHR_materials_clearcoat then
		material.clearcoat_factor = extensions.KHR_materials_clearcoat.clearcoatFactor or 0
		material.clearcoat_roughness_factor = extensions.KHR_materials_clearcoat.clearcoatRoughnessFactor or 0
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

function gltf.MaterialNeedsVFlip(data, material_index)
	local material = data.materials[material_index + 1]

	if not material then return false end

	local pbr = material.pbr_metallic_roughness
	local spec_gloss = material.pbr_specular_glossiness
	local reference = pbr and
		pbr.base_color_texture or
		spec_gloss and
		spec_gloss.diffuse_texture or
		pbr and
		pbr.metallic_roughness_texture or
		material.normal_texture or
		material.emissive_texture

	if not reference then return false end

	local image = data.images[data.textures[reference.index + 1].source + 1]
	local extension = image.path:lower():match("%.(%w+)$")
	return extension == "png" or extension == "bmp"
end

function gltf.Load(path, options)
	options = options or {}
	local base_dir = get_directory(path)
	local json_data, read_err = read_file_checked(path)

	if not json_data then return nil, read_err end

	local embedded_bin

	if json_data:sub(1, 4) == GLB_MAGIC then
		json_data, embedded_bin = split_glb(json_data)

		if not json_data then return nil, "GLB has no JSON chunk" end
	end

	local gltf_data = json.decode(json_data)

	if not gltf_data.asset or gltf_data.asset.version ~= "2.0" then
		return nil, "Only glTF 2.0 is supported"
	end

	local SUPPORTED_EXTENSIONS = {
		MSFT_texture_dds = true,
		KHR_materials_pbrSpecularGlossiness = true,
		KHR_materials_transmission = true,
		KHR_materials_ior = true,
		KHR_materials_dispersion = true,
		KHR_materials_volume = true,
		KHR_lights_punctual = true,
		EXT_meshopt_compression = true,
		KHR_materials_emissive_strength = true,
		KHR_materials_specular = true,
		KHR_materials_clearcoat = true,
		EXT_mesh_gpu_instancing = true,
		KHR_texture_transform = true,
		KHR_materials_unlit = true,
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
	local last_index, last_buffer
	setmetatable(
		buffers,
		{
			__index = function(self, index)
				if index == last_index then return last_buffer end

				local buffer_data = load_buffer(base_dir, gltf_data.buffers[index], index == 1 and embedded_bin or nil)

				if not buffer_data then return nil end

				local c_buffer = ffi.new("uint8_t[?]", #buffer_data)
				ffi.copy(c_buffer, buffer_data, #buffer_data)

				if #buffer_data <= SMALL_BUFFER_BYTES then
					rawset(self, index, c_buffer)
				else
					last_index, last_buffer = index, c_buffer
				end

				return c_buffer
			end,
		}
	)
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
		skins = {},
		animations = {},
		lights = gltf_data.extensions and
			gltf_data.extensions.KHR_lights_punctual and
			gltf_data.extensions.KHR_lights_punctual.lights or
			{},
	}

	if gltf_data.images then
		for i, image_info in ipairs(gltf_data.images) do
			local image_path = image_info.uri and (base_dir .. image_info.uri) or nil

			if not image_path then
				local view = gltf_data.bufferViews[image_info.bufferView + 1]
				image_path = string.format(
					"storage/cache/glb_%s_%d_%d%s",
					(path:match("([^/]+)$") or "model"):gsub("[^%w]", "_"),
					i - 1,
					view.byteLength,
					image_info.mimeType == "image/png" and ".png" or ".jpg"
				)

				if not fs.exists(image_path) then
					assert(fs.create_directory_recursive("storage/cache/"))
					assert(
						fs.write_file(
							image_path,
							ffi.string(buffers[view.buffer + 1] + (view.byteOffset or 0), view.byteLength)
						)
					)
				end
			end

			result.images[i] = {
				uri = image_info.uri,
				mime_type = image_info.mimeType,
				path = image_path,
				buffer_view = image_info.bufferView,
			}
		end
	end

	if gltf_data.textures then
		for i, texture_info in ipairs(gltf_data.textures) do
			local source = texture_info.source

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
		local function decode_primitives(mesh_info)
			local primitives = {}

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

				primitives[j] = primitive
			end

			return primitives
		end

		for i, mesh_info in ipairs(gltf_data.meshes) do
			if options.lazy_meshes then
				result.meshes[i] = setmetatable(
					{name = mesh_info.name},
					{
						__index = function(_, key)
							if key == "primitives" then return decode_primitives(mesh_info) end
						end,
					}
				)
			else
				result.meshes[i] = {name = mesh_info.name, primitives = decode_primitives(mesh_info)}
			end
		end
	end

	if gltf_data.nodes then
		for i, node_info in ipairs(gltf_data.nodes) do
			result.nodes[i] = {
				name = node_info.name,
				mesh = node_info.mesh,
				skin = node_info.skin,
				camera = node_info.camera,
				light = node_info.extensions and
					node_info.extensions.KHR_lights_punctual and
					node_info.extensions.KHR_lights_punctual.light,
				children = node_info.children,
				translation = node_info.translation or {0, 0, 0},
				rotation = node_info.rotation or {0, 0, 0, 1},
				scale = node_info.scale or {1, 1, 1},
				matrix = node_info.matrix,
			}
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

	if gltf_data.skins then
		for i, skin_info in ipairs(gltf_data.skins) do
			result.skins[i] = {
				name = skin_info.name,
				joints = skin_info.joints,
				skeleton = skin_info.skeleton,
				inverse_bind_matrices = skin_info.inverseBindMatrices and
					read_accessor_raw(gltf_data, skin_info.inverseBindMatrices, buffers),
			}
		end
	end

	if gltf_data.animations then
		for i, animation_info in ipairs(gltf_data.animations) do
			local animation = {name = animation_info.name, samplers = {}, channels = {}}

			for j, sampler_info in ipairs(animation_info.samplers) do
				animation.samplers[j] = {
					interpolation = sampler_info.interpolation or "LINEAR",
					input = read_accessor_raw(gltf_data, sampler_info.input, buffers),
					output = read_accessor_raw(gltf_data, sampler_info.output, buffers),
				}
			end

			for j, channel_info in ipairs(animation_info.channels) do
				animation.channels[j] = {
					sampler = animation.samplers[channel_info.sampler + 1],
					node = channel_info.target.node,
					path = channel_info.target.path,
				}
			end

			result.animations[i] = animation
		end
	end

	result.scene = gltf_data.scene or 0
	return result
end

gltf.file_extensions = {"gltf", "glb"}
return gltf
