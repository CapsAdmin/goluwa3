local ffi = require("ffi")
local json = require("json")
local fs = require("fs")
local Buffer = require("structs.buffer")
local base64 = require("goluwa.helpers.base64")
local gltf = {}
-- glTF component type constants
local COMPONENT_TYPE = {
	[5120] = {type = "int8_t", size = 1},
	[5121] = {type = "uint8_t", size = 1},
	[5122] = {type = "int16_t", size = 2},
	[5123] = {type = "uint16_t", size = 2},
	[5125] = {type = "uint32_t", size = 4},
	[5126] = {type = "float", size = 4},
}
-- glTF accessor type constants
local ACCESSOR_TYPE = {
	SCALAR = 1,
	VEC2 = 2,
	VEC3 = 3,
	VEC4 = 4,
	MAT2 = 4,
	MAT3 = 9,
	MAT4 = 16,
}
-- glTF primitive mode constants
local PRIMITIVE_MODE = {
	[0] = "points",
	[1] = "lines",
	[2] = "line_loop",
	[3] = "line_strip",
	[4] = "triangles",
	[5] = "triangle_strip",
	[6] = "triangle_fan",
}

-- Get directory from file path
local function get_directory(path)
	return path:match("(.*/)") or ""
end

-- Load binary buffer from file
local function load_buffer(base_dir, buffer_info)
	if buffer_info.uri then
		-- Check if it's a data URI
		if buffer_info.uri:match("^data:") then
			-- Data URI - base64 encoded
			local base64_data = buffer_info.uri:match("^data:[^;]+;base64,(.+)$")

			if base64_data then return base64.decode(base64_data) end
		else
			-- File URI
			local path = base_dir .. buffer_info.uri
			local data = fs.read_file(path)
			return data
		end
	end

	return nil
end

-- Read accessor data from buffer
local function read_accessor(gltf_data, accessor_index, buffers)
	local accessor = gltf_data.accessors[accessor_index + 1]
	local buffer_view = gltf_data.bufferViews[accessor.bufferView + 1]
	local buffer = buffers[buffer_view.buffer + 1]
	local component_info = COMPONENT_TYPE[accessor.componentType]
	local component_count = ACCESSOR_TYPE[accessor.type]
	local byte_offset = (buffer_view.byteOffset or 0) + (accessor.byteOffset or 0)
	local byte_stride = buffer_view.byteStride or (component_info.size * component_count)
	local result = {
		data = {},
		count = accessor.count,
		component_type = component_info.type,
		component_count = component_count,
		min = accessor.min,
		max = accessor.max,
	}
	-- Create C type for reading
	local c_type = ffi.typeof(component_info.type .. "*")
	local buffer_ptr = ffi.cast("uint8_t*", buffer)

	for i = 0, accessor.count - 1 do
		local offset = byte_offset + i * byte_stride
		local ptr = ffi.cast(c_type, buffer_ptr + offset)

		if component_count == 1 then
			result.data[i + 1] = ptr[0]
		else
			local values = {}

			for j = 0, component_count - 1 do
				values[j + 1] = ptr[j]
			end

			result.data[i + 1] = values
		end
	end

	return result
end

-- Read accessor data as raw C array
local function read_accessor_raw(gltf_data, accessor_index, buffers)
	local accessor = gltf_data.accessors[accessor_index + 1]
	local buffer_view = gltf_data.bufferViews[accessor.bufferView + 1]
	local buffer = buffers[buffer_view.buffer + 1]
	local component_info = COMPONENT_TYPE[accessor.componentType]
	local component_count = ACCESSOR_TYPE[accessor.type]
	local byte_offset = (buffer_view.byteOffset or 0) + (accessor.byteOffset or 0)
	local byte_stride = buffer_view.byteStride or (component_info.size * component_count)
	local buffer_ptr = ffi.cast("uint8_t*", buffer)
	-- Total elements = count * components per element
	local total_elements = accessor.count * component_count
	local element_size = component_info.size
	local c_array = ffi.new(component_info.type .. "[?]", total_elements)
	local c_type = ffi.typeof(component_info.type .. "*")

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

-- Load a glTF file
function gltf.Load(path)
	local base_dir = get_directory(path)
	-- Read and parse JSON
	local json_data = fs.read_file(path)

	if not json_data then return nil, "Failed to read file: " .. path end

	local gltf_data = json.decode(json_data)

	-- Validate glTF version
	if not gltf_data.asset or gltf_data.asset.version ~= "2.0" then
		return nil, "Only glTF 2.0 is supported"
	end

	-- Load all buffers
	local buffers = {}

	if gltf_data.buffers then
		for i, buffer_info in ipairs(gltf_data.buffers) do
			local buffer_data = load_buffer(base_dir, buffer_info)

			if buffer_data then
				-- Convert to C buffer
				local c_buffer = ffi.new("uint8_t[?]", #buffer_data)
				ffi.copy(c_buffer, buffer_data, #buffer_data)
				buffers[i] = c_buffer
			end
		end
	end

	-- Build result structure
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

	-- Process images
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

	-- Process textures
	if gltf_data.textures then
		for i, texture_info in ipairs(gltf_data.textures) do
			result.textures[i] = {
				source = texture_info.source,
				sampler = texture_info.sampler,
			}
		end
	end

	-- Process materials
	if gltf_data.materials then
		for i, material_info in ipairs(gltf_data.materials) do
			local material = {
				name = material_info.name,
				double_sided = material_info.doubleSided or false,
				alpha_mode = material_info.alphaMode or "OPAQUE",
				alpha_cutoff = material_info.alphaCutoff or 0.5,
			}

			-- PBR metallic roughness
			if material_info.pbrMetallicRoughness then
				local pbr = material_info.pbrMetallicRoughness
				material.base_color_factor = pbr.baseColorFactor or {1, 1, 1, 1}
				material.metallic_factor = pbr.metallicFactor or 1
				material.roughness_factor = pbr.roughnessFactor or 1

				if pbr.baseColorTexture then
					material.base_color_texture = pbr.baseColorTexture.index
				end

				if pbr.metallicRoughnessTexture then
					material.metallic_roughness_texture = pbr.metallicRoughnessTexture.index
				end
			end

			-- Normal texture
			if material_info.normalTexture then
				material.normal_texture = material_info.normalTexture.index
				material.normal_scale = material_info.normalTexture.scale or 1
			end

			-- Occlusion texture
			if material_info.occlusionTexture then
				material.occlusion_texture = material_info.occlusionTexture.index
				material.occlusion_strength = material_info.occlusionTexture.strength or 1
			end

			-- Emissive
			if material_info.emissiveTexture then
				material.emissive_texture = material_info.emissiveTexture.index
			end

			material.emissive_factor = material_info.emissiveFactor or {0, 0, 0}
			result.materials[i] = material
		end
	end

	-- Process meshes
	if gltf_data.meshes then
		for i, mesh_info in ipairs(gltf_data.meshes) do
			local mesh = {
				name = mesh_info.name,
				primitives = {},
			}

			for j, primitive_info in ipairs(mesh_info.primitives) do
				local primitive = {
					mode = PRIMITIVE_MODE[primitive_info.mode or 4],
					material = primitive_info.material,
					attributes = {},
				}

				-- Read indices
				if primitive_info.indices ~= nil then
					primitive.indices = read_accessor_raw(gltf_data, primitive_info.indices, buffers)
				end

				-- Read vertex attributes
				for attr_name, accessor_index in pairs(primitive_info.attributes) do
					primitive.attributes[attr_name] = read_accessor_raw(gltf_data, accessor_index, buffers)
				end

				mesh.primitives[j] = primitive
			end

			result.meshes[i] = mesh
		end
	end

	-- Process nodes
	if gltf_data.nodes then
		for i, node_info in ipairs(gltf_data.nodes) do
			local node = {
				name = node_info.name,
				mesh = node_info.mesh,
				children = node_info.children,
				translation = node_info.translation or {0, 0, 0},
				rotation = node_info.rotation or {0, 0, 0, 1},
				scale = node_info.scale or {1, 1, 1},
				matrix = node_info.matrix,
			}
			result.nodes[i] = node
		end
	end

	-- Process scenes
	if gltf_data.scenes then
		for i, scene_info in ipairs(gltf_data.scenes) do
			result.scenes[i] = {
				name = scene_info.name,
				nodes = scene_info.nodes,
			}
		end
	end

	result.scene = gltf_data.scene or 0
	return result
end

-- Helper to get interleaved vertex data for a primitive
-- Returns: vertex_data (C array of floats), vertex_count, stride_in_floats
-- New format: position (3) + normal (3) + texcoord (2) + tangent (4) = 12 floats
function gltf.GetInterleavedVertices(primitive)
	local position = primitive.attributes.POSITION
	local normal = primitive.attributes.NORMAL
	local texcoord = primitive.attributes.TEXCOORD_0
	local tangent = primitive.attributes.TANGENT

	if not position then return nil, "POSITION attribute is required" end

	local vertex_count = position.count
	-- Calculate stride: position (3) + normal (3) + texcoord (2) + tangent (4) = 12 floats
	local stride = 12
	local total_floats = vertex_count * stride
	local vertex_data = ffi.new("float[?]", total_floats)

	for i = 0, vertex_count - 1 do
		local base = i * stride

		-- Position (3 floats)
		if position then
			vertex_data[base + 0] = position.data[i * 3 + 0]
			vertex_data[base + 1] = position.data[i * 3 + 1]
			vertex_data[base + 2] = position.data[i * 3 + 2]
		end

		-- Normal (3 floats)
		if normal then
			vertex_data[base + 3] = normal.data[i * 3 + 0]
			vertex_data[base + 4] = normal.data[i * 3 + 1]
			vertex_data[base + 5] = normal.data[i * 3 + 2]
		else
			vertex_data[base + 3] = 0
			vertex_data[base + 4] = 1
			vertex_data[base + 5] = 0
		end

		-- Texcoord (2 floats)
		if texcoord then
			vertex_data[base + 6] = texcoord.data[i * 2 + 0]
			vertex_data[base + 7] = texcoord.data[i * 2 + 1]
		else
			vertex_data[base + 6] = 0
			vertex_data[base + 7] = 0
		end

		-- Tangent (4 floats: xyz + w for handedness)
		if tangent then
			vertex_data[base + 8] = tangent.data[i * 4 + 0]
			vertex_data[base + 9] = tangent.data[i * 4 + 1]
			vertex_data[base + 10] = tangent.data[i * 4 + 2]
			vertex_data[base + 11] = tangent.data[i * 4 + 3]
		else
			-- Default tangent pointing along X axis with positive handedness
			vertex_data[base + 8] = 1.0
			vertex_data[base + 9] = 0.0
			vertex_data[base + 10] = 0.0
			vertex_data[base + 11] = 1.0
		end
	end

	return vertex_data, vertex_count, stride
end

-- Helper to get indices as uint32_t array (for Vulkan compatibility)
function gltf.GetIndices32(primitive)
	if not primitive.indices then return nil end

	local indices = primitive.indices
	local index_data = ffi.new("uint32_t[?]", indices.count)

	for i = 0, indices.count - 1 do
		index_data[i] = indices.data[i]
	end

	return index_data, indices.count
end

-- Helper to get indices in their native format
function gltf.GetIndices(primitive)
	if not primitive.indices then return nil end

	local indices = primitive.indices
	return indices.data, indices.count, indices.component_type
end

local render = require("graphics.render")
local Texture = require("graphics.texture")

-- Create GPU vertex buffer from primitive
function gltf.CreateVertexBuffer(primitive)
	local vertex_data, vertex_count, stride = gltf.GetInterleavedVertices(primitive)

	if not vertex_data then
		return nil, vertex_count -- vertex_count is error message
	end

	local byte_size = vertex_count * stride * ffi.sizeof("float")
	local buffer = render.CreateBuffer(
		{
			buffer_usage = "vertex_buffer",
			data_type = "float",
			data = vertex_data,
			byte_size = byte_size,
		}
	)
	return buffer, vertex_count
end

-- Create GPU index buffer from primitive
-- Also validates indices against vertex_count if provided
function gltf.CreateIndexBuffer(primitive, vertex_count)
	if not primitive.indices then return nil, nil, nil end

	local indices = primitive.indices

	-- Validate indices if vertex_count provided
	if vertex_count then
		local max_index = 0

		for i = 0, indices.count - 1 do
			local idx = indices.data[i]

			if idx > max_index then max_index = idx end

			if idx >= vertex_count then
				print(
					string.format("WARNING: Index %d at position %d exceeds vertex_count %d!", idx, i, vertex_count)
				)
			end
		end
	end

	local buffer = render.CreateBuffer(
		{
			buffer_usage = "index_buffer",
			data_type = indices.component_type,
			data = indices.data,
			byte_size = indices.byte_size,
		}
	)
	-- Convert component type to Vulkan-style name
	local index_type = "uint16"

	if indices.component_type == "uint32_t" then index_type = "uint32" end

	return buffer, indices.count, index_type
end

-- Translate glTF sampler enums to our sampler config values
local function translate_gltf_sampler(sampler_info)
	local min_filter = "linear"
	local mag_filter = "linear"
	local wrap_s = "repeat"
	local wrap_t = "repeat"

	if sampler_info then
		-- glTF filter values
		-- 9728 = NEAREST, 9729 = LINEAR
		-- 9984 = NEAREST_MIPMAP_NEAREST, 9985 = LINEAR_MIPMAP_NEAREST
		-- 9986 = NEAREST_MIPMAP_LINEAR, 9987 = LINEAR_MIPMAP_LINEAR
		if sampler_info.minFilter then
			if
				sampler_info.minFilter == 9728 or
				sampler_info.minFilter == 9984 or
				sampler_info.minFilter == 9986
			then
				min_filter = "nearest"
			end
		end

		if sampler_info.magFilter then
			if sampler_info.magFilter == 9728 then mag_filter = "nearest" end
		end

		-- glTF wrap values
		-- 33071 = CLAMP_TO_EDGE, 33648 = MIRRORED_REPEAT, 10497 = REPEAT
		if sampler_info.wrapS then
			if sampler_info.wrapS == 33071 then
				wrap_s = "clamp_to_edge"
			elseif sampler_info.wrapS == 33648 then
				wrap_s = "mirrored_repeat"
			end
		end

		if sampler_info.wrapT then
			if sampler_info.wrapT == 33071 then
				wrap_t = "clamp_to_edge"
			elseif sampler_info.wrapT == 33648 then
				wrap_t = "mirrored_repeat"
			end
		end
	end

	return {
		min_filter = min_filter,
		mag_filter = mag_filter,
		wrap_s = wrap_s,
		wrap_t = wrap_t,
		mipmap_mode = "linear",
	}
end

-- Load a texture from glTF image reference
function gltf.LoadTexture(gltf_result, texture_index)
	if not texture_index then return nil end

	local texture_info = gltf_result.textures[texture_index + 1]

	if not texture_info then
		print("Warning: Invalid texture index:", texture_index)
		return Texture.GetFallback()
	end

	local image_info = gltf_result.images[texture_info.source + 1]

	if not image_info then
		print("Warning: Invalid image source:", texture_info.source)
		return Texture.GetFallback()
	end

	local image_path = image_info.path

	if not image_path then
		print("Warning: No path for image:", texture_info.source)
		return Texture.GetFallback()
	end

	-- Get sampler info if available
	local sampler_info = nil

	if texture_info.sampler and gltf_result.raw.samplers then
		sampler_info = gltf_result.raw.samplers[texture_info.sampler + 1]
	end

	-- Translate glTF sampler enums to our format
	local sampler_config = translate_gltf_sampler(sampler_info)
	-- Use cache_key to enable caching in Texture.New
	local cache_key = gltf_result.path .. ":" .. texture_index
	-- Create texture using Texture.New (handles caching, loading, mipmaps, and fallback)
	local texture = Texture.New(
		{
			path = image_path,
			cache_key = cache_key,
			format = "R8G8B8A8_UNORM",
			mip_map_levels = "auto",
			sampler = sampler_config,
		}
	)
	return texture
end

-- Create all GPU resources for a glTF model
-- Returns a table of primitives with vertex_buffer, index_buffer, and material
function gltf.CreateGPUResources(gltf_result)
	local Material = require("graphics.material")
	local primitives = {}

	for mesh_idx, mesh in ipairs(gltf_result.meshes) do
		for prim_idx, primitive in ipairs(mesh.primitives) do
			local vertex_buffer, vertex_count = gltf.CreateVertexBuffer(primitive)

			if not vertex_buffer then
				print(
					"Warning: Failed to create vertex buffer for mesh",
					mesh_idx,
					"primitive",
					prim_idx
				)

				goto continue
			end

			local index_buffer, index_count, index_type = gltf.CreateIndexBuffer(primitive, vertex_count)
			-- Create Material object with all PBR textures
			local material = nil
			local texture = nil -- Legacy support
			if primitive.material ~= nil then
				local gltf_mat = gltf_result.materials[primitive.material + 1]

				if gltf_mat then
					-- Load all PBR textures
					local albedo_tex = gltf_mat.base_color_texture and
						gltf.LoadTexture(gltf_result, gltf_mat.base_color_texture)
					local normal_tex = gltf_mat.normal_texture and
						gltf.LoadTexture(gltf_result, gltf_mat.normal_texture)
					local metallic_roughness_tex = gltf_mat.metallic_roughness_texture and
						gltf.LoadTexture(gltf_result, gltf_mat.metallic_roughness_texture)
					local occlusion_tex = gltf_mat.occlusion_texture and
						gltf.LoadTexture(gltf_result, gltf_mat.occlusion_texture)
					local emissive_tex = gltf_mat.emissive_texture and
						gltf.LoadTexture(gltf_result, gltf_mat.emissive_texture)
					material = Material.New(
						{
							name = gltf_mat.name,
							albedo_texture = albedo_tex,
							normal_texture = normal_tex,
							metallic_roughness_texture = metallic_roughness_tex,
							occlusion_texture = occlusion_tex,
							emissive_texture = emissive_tex,
							base_color_factor = gltf_mat.base_color_factor,
							metallic_factor = gltf_mat.metallic_factor,
							roughness_factor = gltf_mat.roughness_factor,
							normal_scale = gltf_mat.normal_scale,
							occlusion_strength = gltf_mat.occlusion_strength,
							emissive_factor = {
								gltf_mat.emissive_factor[1],
								gltf_mat.emissive_factor[2],
								gltf_mat.emissive_factor[3],
							},
							double_sided = gltf_mat.double_sided,
							alpha_mode = gltf_mat.alpha_mode,
							alpha_cutoff = gltf_mat.alpha_cutoff,
						}
					)
					-- Legacy texture reference
					texture = albedo_tex
				end
			end

			primitives[#primitives + 1] = {
				vertex_buffer = vertex_buffer,
				vertex_count = vertex_count,
				index_buffer = index_buffer,
				index_count = index_count,
				index_type = index_type,
				texture = texture, -- Legacy support
				material = material, -- New PBR material
				material_index = primitive.material,
				mesh_name = mesh.name,
			}

			::continue::
		end
	end

	return primitives
end

-- Clear the texture cache (useful when reloading models)
function gltf.ClearTextureCache()
	Texture.ClearCache()
end

return gltf
