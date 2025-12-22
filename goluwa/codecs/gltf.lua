local ffi = require("ffi")
local json = require("codecs.json")
local fs = require("fs")
local Buffer = require("structs.buffer")
local base64 = require("codecs.base64")
local Matrix44 = require("structs.matrix44")
local Quat = require("structs.quat")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local ecs = require("ecs")
local Material = require("render3d.material")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Texture = require("render.texture")
local Polygon3D = require("render3d.polygon_3d")
require("components.transform")
require("components.model")
local AABB = require("structs.aabb")
local gltf = {}
gltf.debug_white_textures = false
gltf.debug_print_nodes = false
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
	return path:match("(.*/)") or ""
end

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

	-- Track supported extensions
	local SUPPORTED_EXTENSIONS = {
		MSFT_texture_dds = true,
		KHR_materials_pbrSpecularGlossiness = true,
	}

	-- Check required extensions - error if any are unsupported
	if gltf_data.extensionsRequired then
		for _, ext in ipairs(gltf_data.extensionsRequired) do
			if not SUPPORTED_EXTENSIONS[ext] then
				return nil, "Required extension '" .. ext .. "' is not supported"
			end
		end
	end

	-- Warn about used extensions that aren't fully supported
	if gltf_data.extensionsUsed then
		for _, ext in ipairs(gltf_data.extensionsUsed) do
			if not SUPPORTED_EXTENSIONS[ext] then
				print("WARNING: glTF extension '" .. ext .. "' is used but not fully supported")
			end
		end
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
			local source = texture_info.source

			-- Check for MSFT_texture_dds extension (prefer DDS over default source)
			if texture_info.extensions and texture_info.extensions.MSFT_texture_dds then
				source = texture_info.extensions.MSFT_texture_dds.source
			end

			result.textures[i] = {
				source = source,
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
			-- Check for KHR_materials_pbrSpecularGlossiness extension first
			-- This uses diffuse/specular workflow instead of metallic/roughness
			local spec_gloss = material_info.extensions and
				material_info.extensions.KHR_materials_pbrSpecularGlossiness

			if spec_gloss then
				-- Convert specular-glossiness to metallic-roughness approximation
				-- diffuseFactor -> base_color_factor
				material.base_color_factor = spec_gloss.diffuseFactor or {1, 1, 1, 1}
				-- glossiness is inverse of roughness
				material.roughness_factor = 1.0 - (spec_gloss.glossinessFactor or 1.0)
				-- Approximate metallic from specular (if specular is high and similar to diffuse, it's metallic)
				local spec = spec_gloss.specularFactor or {1, 1, 1}
				local avg_spec = (spec[1] + spec[2] + spec[3]) / 3.0
				material.metallic_factor = avg_spec > 0.5 and avg_spec or 0.0

				-- diffuseTexture -> base_color_texture
				if spec_gloss.diffuseTexture then
					material.base_color_texture = spec_gloss.diffuseTexture.index
				end

				-- specularGlossinessTexture - we don't have a direct equivalent,
				-- but the glossiness (alpha) can approximate roughness
				if spec_gloss.specularGlossinessTexture then
					material.metallic_roughness_texture = spec_gloss.specularGlossinessTexture.index
				end
			elseif material_info.pbrMetallicRoughness then
				-- Standard PBR metallic roughness
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
			else
				-- No PBR info at all, use defaults
				material.base_color_factor = {1, 1, 1, 1}
				material.metallic_factor = 0
				material.roughness_factor = 0.5
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

-- Set local transform properties from glTF node (TRS or matrix)
local function set_local_transform(transform, node) end

-- Helper to get interleaved vertex data for a primitive
-- Returns: vertex_data (C array of floats), vertex_count, stride_in_floats, aabb
-- New format: position (3) + normal (3) + texcoord (2) + tangent (4) = 12 floats
-- Converts coordinates using the top-level conversion functions (controlled by ENABLE_COORDINATE_CONVERSION)
-- Also computes AABB in our coordinate system
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
	-- Initialize AABB with extreme values
	local aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for i = 0, vertex_count - 1 do
		local base = i * stride

		-- Position (3 floats) - convert coordinate system
		if position then
			local px = position.data[i * 3 + 0]
			local py = position.data[i * 3 + 1]
			local pz = position.data[i * 3 + 2]
			local our_x, our_y, our_z = px, py, pz
			vertex_data[base + 0] = our_x
			vertex_data[base + 1] = our_y
			vertex_data[base + 2] = our_z

			-- Expand AABB
			if our_x < aabb.min_x then aabb.min_x = our_x end

			if our_y < aabb.min_y then aabb.min_y = our_y end

			if our_z < aabb.min_z then aabb.min_z = our_z end

			if our_x > aabb.max_x then aabb.max_x = our_x end

			if our_y > aabb.max_y then aabb.max_y = our_y end

			if our_z > aabb.max_z then aabb.max_z = our_z end
		end

		-- Normal (3 floats) - convert coordinate system
		if normal then
			local nx = normal.data[i * 3 + 0]
			local ny = normal.data[i * 3 + 1]
			local nz = normal.data[i * 3 + 2]
			local our_nx, our_ny, our_nz = nx, ny, nz
			vertex_data[base + 3] = our_nx
			vertex_data[base + 4] = our_ny
			vertex_data[base + 5] = our_nz
		else
			vertex_data[base + 3] = 0
			vertex_data[base + 4] = 0
			vertex_data[base + 5] = 1
		end

		-- Texcoord (2 floats)
		if texcoord then
			vertex_data[base + 6] = texcoord.data[i * 2 + 0]
			vertex_data[base + 7] = texcoord.data[i * 2 + 1]
		else
			vertex_data[base + 6] = 0
			vertex_data[base + 7] = 0
		end

		-- Tangent (4 floats: xyz + w for handedness) - convert coordinate system
		if tangent then
			local tx = tangent.data[i * 4 + 0]
			local ty = tangent.data[i * 4 + 1]
			local tz = tangent.data[i * 4 + 2]
			local tw = tangent.data[i * 4 + 3]
			local our_tx, our_ty, our_tz = tx, ty, tz
			vertex_data[base + 8] = our_tx
			vertex_data[base + 9] = our_ty
			vertex_data[base + 10] = our_tz
			vertex_data[base + 11] = tw
		else
			-- Default tangent pointing along X axis with positive handedness
			vertex_data[base + 8] = 1.0
			vertex_data[base + 9] = 0.0
			vertex_data[base + 10] = 0.0
			vertex_data[base + 11] = 1.0
		end
	end

	return vertex_data, vertex_count, stride, aabb
end

-- White debug texture (created on demand)
local white_texture = nil

local function get_white_texture()
	if white_texture then return white_texture end

	-- Create 4x4 white texture
	local size = 4
	local buffer = ffi.new("uint8_t[?]", size * size * 4)

	for i = 0, size * size - 1 do
		buffer[i * 4 + 0] = 255 -- R
		buffer[i * 4 + 1] = 255 -- G
		buffer[i * 4 + 2] = 255 -- B
		buffer[i * 4 + 3] = 255 -- A
	end

	white_texture = Texture.New(
		{
			width = size,
			height = size,
			format = "r8g8b8a8_unorm",
			buffer = buffer,
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
	)
	return white_texture
end

-- Create GPU vertex buffer from primitive
-- Returns: buffer, vertex_count, aabb (in local/mesh space)
function gltf.CreateVertexBuffer(primitive)
	local vertex_data, vertex_count, stride, aabb = gltf.GetInterleavedVertices(primitive)

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
	return buffer, vertex_count, aabb
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

	-- Debug mode: return white texture instead of loading
	if gltf.debug_white_textures then return get_white_texture() end

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
			format = not image_path:ends_with(".dds") and "r8g8b8a8_unorm" or nil,
			mip_map_levels = "auto",
			sampler = sampler_config,
		}
	)
	return texture
end

-- Clear the texture cache (useful when reloading models)
function gltf.ClearTextureCache()
	Texture.ClearCache()
end

-- Compute the bounding box of all meshes in the scene, accounting for node transforms
-- Returns min, max, center as Vec3 (in our coordinate system)
-- Requires node_to_entity map from CreateEntityHierarchy
function gltf.ComputeSceneBounds(gltf_result, node_to_entity)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
	-- Build a map of mesh index to nodes that reference it
	local mesh_to_nodes = {}

	for node_index, node in ipairs(gltf_result.nodes) do
		if node.mesh ~= nil then
			local mesh_index = node.mesh + 1
			mesh_to_nodes[mesh_index] = mesh_to_nodes[mesh_index] or {}
			table.insert(mesh_to_nodes[mesh_index], node_index)
		end
	end

	-- For each mesh, transform its bounds by the node's world matrix
	for mesh_idx, mesh in ipairs(gltf_result.meshes) do
		local node_indices = mesh_to_nodes[mesh_idx] or {}

		for _, node_index in ipairs(node_indices) do
			local entity = node_to_entity[node_index]
			local world_matrix = entity and entity.transform and entity.transform:GetWorldMatrix()

			if not world_matrix then goto continue end

			for _, primitive in ipairs(mesh.primitives) do
				local pos = primitive.attributes.POSITION

				if pos and pos.min and pos.max then
					-- Transform all 8 corners of the bounding box
					local corners = {
						{pos.min[1], pos.min[2], pos.min[3]},
						{pos.min[1], pos.min[2], pos.max[3]},
						{pos.min[1], pos.max[2], pos.min[3]},
						{pos.min[1], pos.max[2], pos.max[3]},
						{pos.max[1], pos.min[2], pos.min[3]},
						{pos.max[1], pos.min[2], pos.max[3]},
						{pos.max[1], pos.max[2], pos.min[3]},
						{pos.max[1], pos.max[2], pos.max[3]},
					}

					for _, corner in ipairs(corners) do
						-- Transform by world matrix (in glTF coordinates)
						local tx, ty, tz = world_matrix:TransformVector(corner[1], corner[2], corner[3])
						-- Convert to our coordinate system
						local our_x, our_y, our_z = tx, ty, tz
						min_x = math.min(min_x, our_x)
						min_y = math.min(min_y, our_y)
						min_z = math.min(min_z, our_z)
						max_x = math.max(max_x, our_x)
						max_y = math.max(max_y, our_y)
						max_z = math.max(max_z, our_z)
					end
				end
			end

			::continue::
		end
	end

	local our_min = Vec3(min_x, min_y, min_z)
	local our_max = Vec3(max_x, max_y, max_z)
	local center = Vec3((our_min.x + our_max.x) / 2, (our_min.y + our_max.y) / 2, (our_min.z + our_max.z) / 2)
	return our_min, our_max, center
end

-- Get the offset needed to center the scene at origin
-- Requires node_to_entity map from CreateEntityHierarchy
function gltf.GetCenteringOffset(gltf_result, node_to_entity)
	local _, _, center = gltf.ComputeSceneBounds(gltf_result, node_to_entity)
	-- Return negative of center to move scene to origin
	return Vec3(-center.x, -center.y, -center.z)
end

-- Get suggested camera position and angles from glTF
-- Looks for: 1) glTF camera nodes, 2) nodes with "camera" in the name, 3) scene center
-- Returns position (Vec3), angles (Ang3 or nil)
-- Requires node_to_entity map from CreateEntityHierarchy
function gltf.GetSuggestedCameraTransform(gltf_result, node_to_entity)
	-- First, look for nodes with a "camera" property (actual glTF cameras)
	for node_index, node in ipairs(gltf_result.nodes) do
		if node.camera ~= nil then
			local entity = node_to_entity[node_index]

			if entity and entity.transform then
				local world_matrix = entity.transform:GetWorldMatrix()
				local pos = Vec3(world_matrix.m30, world_matrix.m31, world_matrix.m32)

				if gltf.debug_print_nodes then
					print("Found glTF camera node:", node.name or node_index, "at", pos.x, pos.y, pos.z)
				end

				return pos, nil -- TODO: extract rotation as angles
			end
		end
	end

	-- Fallback: use scene center from ComputeSceneBounds
	-- This uses glTF accessor min/max with proper world transforms
	local _, _, center = gltf.ComputeSceneBounds(gltf_result, node_to_entity)

	if gltf.debug_print_nodes then
		local bounds_min, bounds_max = gltf.ComputeSceneBounds(gltf_result, node_to_entity)
		print("No camera found, using scene center:", center.x, center.y, center.z)
		print("  Scene bounds min:", bounds_min.x, bounds_min.y, bounds_min.z)
		print("  Scene bounds max:", bounds_max.x, bounds_max.y, bounds_max.z)
	end

	-- Position camera at center, slightly elevated
	return Vec3(center.x, center.y, center.z + 2), nil
end

-- Create an entity hierarchy from a glTF model using the ECS system
-- Returns the root entity containing the entire scene
-- glTF uses Y-up, we use Z-up (Source engine style), so we convert coordinates
-- Options:
--   center_scene: boolean - if true, translates scene so center is at origin
function gltf.CreateEntityHierarchy(gltf_result, parent_entity, options)
	options = options or {}
	-- Create root entity for this glTF scene
	local root_entity = ecs.CreateEntity(gltf_result.path or "gltf_root", parent_entity)
	root_entity:AddComponent("transform")
	-- Map from glTF node index to entity
	local node_to_entity = {}
	-- Debug stats
	local stats = {
		total_nodes = #gltf_result.nodes,
		nodes_with_mesh = 0,
		total_primitives = 0,
		failed_primitives = 0,
	}

	-- First pass: create all entities with transforms
	for node_index, node in ipairs(gltf_result.nodes) do
		local entity = ecs.CreateEntity(node.name or ("node_" .. node_index))
		entity:AddComponent("transform")
		-- Set local transform from glTF node
		local transform = entity.transform

		if node.matrix then
			local m = Matrix44()
			m.m00 = node.matrix[1]
			m.m01 = node.matrix[2]
			m.m02 = node.matrix[3]
			m.m03 = node.matrix[4]
			m.m10 = node.matrix[5]
			m.m11 = node.matrix[6]
			m.m12 = node.matrix[7]
			m.m13 = node.matrix[8]
			m.m20 = node.matrix[9]
			m.m21 = node.matrix[10]
			m.m22 = node.matrix[11]
			m.m23 = node.matrix[12]
			m.m30 = node.matrix[13]
			m.m31 = node.matrix[14]
			m.m32 = node.matrix[15]
			m.m33 = node.matrix[16]
			transform:SetFromMatrix(m)
		else
			local t = node.translation
			transform:SetPosition(Vec3(t[1], t[2], t[3]))
			local r = node.rotation
			transform:SetRotation(Quat(r[1], r[2], r[3], r[4]))
			local s = node.scale
			transform:SetScale(Vec3(s[1], s[2], s[3]))
		end

		node_to_entity[node_index] = entity
	end

	-- Second pass: set up parenting
	for node_index, node in ipairs(gltf_result.nodes) do
		local entity = node_to_entity[node_index]

		if node.children then
			for _, child_index in ipairs(node.children) do
				local child_entity = node_to_entity[child_index + 1]

				if child_entity then child_entity:SetParent(entity) end
			end
		end
	end

	-- Third pass: attach model components to nodes with meshes
	for node_index, node in ipairs(gltf_result.nodes) do
		if node.mesh ~= nil then
			stats.nodes_with_mesh = stats.nodes_with_mesh + 1
			local entity = node_to_entity[node_index]
			local mesh = gltf_result.meshes[node.mesh + 1]

			if mesh then
				-- Check if we should split primitives into separate entities
				local should_split = options.split_primitives and #mesh.primitives > 1

				if not should_split then
					-- Original behavior: all primitives in one model component
					local model = entity:AddComponent("model")

					-- Create primitives for this mesh
					for prim_idx, primitive in ipairs(mesh.primitives) do
						stats.total_primitives = stats.total_primitives + 1
						-- Get raw vertex data (FFI array)
						local vertex_data, vertex_count, stride, prim_aabb = gltf.GetInterleavedVertices(primitive)

						if vertex_data then
							-- Get raw index data (FFI array) if present
							local index_data = nil
							local index_type = nil
							local index_count = nil

							if primitive.indices then
								index_data = primitive.indices.data
								index_count = primitive.indices.count
								index_type = primitive.indices.component_type == "uint32_t" and "uint32" or "uint16"
							end

							-- Create material
							local material = nil
							local texture = nil

							if primitive.material ~= nil then
								local gltf_mat = gltf_result.materials[primitive.material + 1]

								if gltf_mat then
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
									texture = albedo_tex
								end
							end

							-- Create Polygon3D object
							local poly = Polygon3D.New()
							poly:SetAABB(prim_aabb)
							poly.material = material
							poly.mesh = render3d.CreateMesh(vertex_data, index_data, index_type, index_count)
							model:AddPrimitive(poly)
						else
							stats.failed_primitives = stats.failed_primitives + 1

							if gltf.debug_print_nodes then
								print("  FAILED to get vertex data:", vertex_count)
							end
						end
					end
				else
					-- Split primitives: create a child entity for each primitive
					for prim_idx, primitive in ipairs(mesh.primitives) do
						stats.total_primitives = stats.total_primitives + 1
						-- Get raw vertex data (FFI array)
						local vertex_data, vertex_count, stride, prim_aabb = gltf.GetInterleavedVertices(primitive)

						if vertex_data then
							-- Get raw index data (FFI array) if present
							local index_data = nil
							local index_type = nil
							local index_count = nil

							if primitive.indices then
								index_data = primitive.indices.data
								index_count = primitive.indices.count
								index_type = primitive.indices.component_type == "uint32_t" and "uint32" or "uint16"
							end

							-- Create material
							local material = nil
							local texture = nil

							if primitive.material ~= nil then
								local gltf_mat = gltf_result.materials[primitive.material + 1]

								if gltf_mat then
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
									texture = albedo_tex
								end
							end

							-- Create a child entity for this primitive
							local prim_name = (mesh.name or "mesh") .. "_prim" .. prim_idx
							local prim_entity = ecs.CreateEntity(prim_name, entity)
							prim_entity:AddComponent("transform")
							-- Transform is identity since it inherits from parent node
							local prim_model = prim_entity:AddComponent("model")
							-- Create Polygon3D object
							local poly = Polygon3D.New()
							poly:SetAABB(prim_aabb)
							poly.material = material
							poly.mesh = render3d.CreateMesh(vertex_data, index_data, index_type, index_count)

							if gltf.debug_print_nodes then
								print("  FAILED to get vertex data:", vertex_count)
							end
						end
					end
				end
			end
		end
	end

	-- Fourth pass: parent root nodes to our root entity
	local scene_index = gltf_result.scene + 1
	local scene = gltf_result.scenes[scene_index]

	if scene and scene.nodes then
		for _, root_node_index in ipairs(scene.nodes) do
			local entity = node_to_entity[root_node_index + 1]

			if entity then entity:SetParent(root_entity) end
		end
	end

	-- Apply centering offset if requested (after hierarchy is built)
	if options.center_scene then
		local offset = gltf.GetCenteringOffset(gltf_result, node_to_entity)
		root_entity.transform:SetPosition(offset)

		if gltf.debug_print_nodes then
			local _, _, center = gltf.ComputeSceneBounds(gltf_result, node_to_entity)
			print("=== Scene Centering ===")
			print("  Original center:", center.x, center.y, center.z)
			print("  Applied offset:", offset.x, offset.y, offset.z)
			print("=======================")
		end
	end

	-- Print debug stats
	if gltf.debug_print_nodes then
		print("=== glTF Load Stats ===")
		print("  Total nodes:", stats.total_nodes)
		print("  Nodes with meshes:", stats.nodes_with_mesh)
		print("  Total primitives:", stats.total_primitives)
		print("  Failed primitives:", stats.failed_primitives)
		print("  Successful primitives:", stats.total_primitives - stats.failed_primitives)
		print("=======================")
	end

	return root_entity, node_to_entity
end

gltf.file_extensions = {"gltf"}
return gltf
