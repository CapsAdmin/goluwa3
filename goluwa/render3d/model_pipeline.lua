local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local system = import("goluwa/system.lua")
local model_pipeline = library()
local MAX_BRANCH_HELPERS = 16
local BRANCH_HELPER_KEYS = {}
local FLOAT_SIZE = ffi.sizeof("float")

for i = 0, MAX_BRANCH_HELPERS - 1 do
	BRANCH_HELPER_KEYS[i + 1] = "BranchHelper" .. tostring(i)
end

local SURFACE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
}
local PBR_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
}
local PBR_COLOR_FIELDS = {
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
}
local PBR_FACTOR_FIELDS = {
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "SpecularMultiplier", getter = "GetSpecularMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
}
local PBR_DETAIL_FIELDS = {
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{type = "texture", name = "DetailTexture", getter = "GetDetailTexture"},
	{type = "vec2", name = "DetailTiling", getter = "GetDetailTiling"},
	{type = "float", name = "DetailBumpScale", getter = "GetDetailBumpScale"},
	{type = "float", name = "DetailBlendAmount", getter = "GetDetailBlendAmount"},
}
local PBR_AUX_FIELDS = {
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{
		type = "texture",
		name = "AmbientOcclusionTexture",
		getter = "GetAmbientOcclusionTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{
		type = "float",
		name = "AmbientOcclusionMultiplier",
		getter = "GetAmbientOcclusionMultiplier",
	},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "texture", name = "MetallicTexture", getter = "GetMetallicTexture"},
	{type = "texture", name = "RoughnessTexture", getter = "GetRoughnessTexture"},
	{type = "texture", name = "OpacityTexture", getter = "GetOpacityTexture"},
}
local PBR_DISPLACEMENT_FIELDS = {
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
}
local PBR_TERRAIN_FIELDS = {
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer1Texture",
		getter = "GetTerrainLayer1Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer2Texture",
		getter = "GetTerrainLayer2Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer3Texture",
		getter = "GetTerrainLayer3Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer4Texture",
		getter = "GetTerrainLayer4Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer1NormalTexture",
		getter = "GetTerrainLayer1NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer2NormalTexture",
		getter = "GetTerrainLayer2NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer3NormalTexture",
		getter = "GetTerrainLayer3NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer4NormalTexture",
		getter = "GetTerrainLayer4NormalTexture",
	},
	{
		type = "vec4",
		name = "TerrainLayerScales",
		getter = "GetTerrainLayerScales",
	},
	{
		type = "vec4",
		name = "TerrainLayerRoughness",
		getter = "GetTerrainLayerRoughness",
	},
	{
		type = "vec4",
		name = "TerrainLayerAmbientOcclusion",
		getter = "GetTerrainLayerAmbientOcclusion",
	},
}
local PBR_TRANSMISSION_FIELDS = {
	{
		type = "vec4",
		name = "TransmissionColor",
		getter = "GetTransmissionColor",
	},
	{
		type = "float",
		name = "TransmissionViewDependency",
		getter = "GetTransmissionViewDependency",
	},
	{
		type = "float",
		name = "TransmissionBlocking",
		getter = "GetTransmissionBlocking",
	},
}
local PROBE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer1Texture",
		getter = "GetTerrainLayer1Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer2Texture",
		getter = "GetTerrainLayer2Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer3Texture",
		getter = "GetTerrainLayer3Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer4Texture",
		getter = "GetTerrainLayer4Texture",
	},
	{
		type = "texture",
		name = "TerrainLayer1NormalTexture",
		getter = "GetTerrainLayer1NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer2NormalTexture",
		getter = "GetTerrainLayer2NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer3NormalTexture",
		getter = "GetTerrainLayer3NormalTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer4NormalTexture",
		getter = "GetTerrainLayer4NormalTexture",
	},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "vec4",
		name = "TerrainLayerScales",
		getter = "GetTerrainLayerScales",
	},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
}

local function get_material()
	return render3d.GetMaterial()
end

local VERTEX_ATTRIBUTE_DEFS = {
	{name = "position", type = "vec3", format = "r32g32b32_sfloat", float_count = 3},
	{name = "normal", type = "vec3", format = "r32g32b32_sfloat", float_count = 3},
	{name = "uv", type = "vec2", format = "r32g32_sfloat", float_count = 2},
	{
		name = "tangent",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		float_count = 4,
	},
	{name = "texture_blend", type = "float", format = "r32_sfloat", float_count = 1},
	{
		name = "vertex_color",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		float_count = 4,
	},
}

local function get_vertex_stride()
	local stride = 0

	for _, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		stride = stride + def.float_count * FLOAT_SIZE
	end

	return stride
end

function model_pipeline.GetVertexAttributes()
	local attributes = {}

	for i, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		attributes[i] = {def.name, def.type, def.format}
	end

	return attributes
end

local function build_vertex_attribute_name_set(names)
	local lookup = {}

	for _, name in ipairs(names or {}) do
		lookup[name] = true
	end

	return lookup
end

function model_pipeline.GetVertexAttributesSubset(names)
	local include = build_vertex_attribute_name_set(names)
	local attributes = {}
	local offset = 0

	for _, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		if include[def.name] then
			attributes[#attributes + 1] = {def.name, def.type, def.format, offset}
		end

		offset = offset + def.float_count * FLOAT_SIZE
	end

	return attributes
end

function model_pipeline.GetVertexStride()
	return get_vertex_stride()
end

function model_pipeline.GetVertexBufferBinding(binding_index)
	return {
		binding = binding_index or 0,
		stride = get_vertex_stride(),
		input_rate = "vertex",
	}
end

function model_pipeline.GetVertexAttributeLayout(binding_index)
	binding_index = binding_index or 0
	local attributes = {}
	local offset = 0

	for i, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		attributes[i] = {
			binding = binding_index,
			location = i - 1,
			format = def.format,
			offset = offset,
		}
		offset = offset + def.float_count * FLOAT_SIZE
	end

	return attributes
end

function model_pipeline.GetVertexAttributeLayoutSubset(names, binding_index)
	binding_index = binding_index or 0
	local include = build_vertex_attribute_name_set(names)
	local attributes = {}
	local offset = 0
	local location = 0

	for _, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		if include[def.name] then
			attributes[#attributes + 1] = {
				binding = binding_index,
				location = location,
				format = def.format,
				offset = offset,
			}
			location = location + 1
		end

		offset = offset + def.float_count * FLOAT_SIZE
	end

	return attributes
end

function model_pipeline.GetTransformBlock(include_projection_view_world, include_prev_world)
	local block = {}

	if include_projection_view_world ~= false then
		block[#block + 1] = {"projection_view_world", "mat4"}
	end

	block[#block + 1] = {"world", "mat4"}

	if include_prev_world then block[#block + 1] = {"prev_world", "mat4"} end

	return block
end

function model_pipeline.BuildTransformBlockWriter(
	include_projection_view_world,
	get_projection_view_world_matrix,
	include_prev_world
)
	get_projection_view_world_matrix = get_projection_view_world_matrix or render3d.GetProjectionViewWorldMatrix
	return function(self, block)
		if include_projection_view_world ~= false then
			get_projection_view_world_matrix():CopyToFloatPointer(block.projection_view_world)
		end

		render3d.GetWorldMatrix():CopyToFloatPointer(block.world)

		if include_prev_world then
			render3d.GetPreviousWorldMatrix():CopyToFloatPointer(block.prev_world)
		end

		return block
	end
end

function model_pipeline.GetInstancedTransformBlock(include_projection_view)
	local block = {}

	if include_projection_view ~= false then
		block[#block + 1] = {"projection_view", "mat4"}
	end

	return block
end

function model_pipeline.BuildInstancedTransformBlockWriter(include_projection_view, get_projection_view_matrix)
	get_projection_view_matrix = get_projection_view_matrix or render3d.GetProjectionViewMatrix
	return function(self, block)
		if include_projection_view ~= false then
			get_projection_view_matrix():CopyToFloatPointer(block.projection_view)
		end

		return block
	end
end

function model_pipeline.GetInstanceAttributes()
	return {
		{"instance_world", "mat4"},
	}
end

function model_pipeline.GetPreviousInstanceAttributes()
	return {
		{"instance_prev_world", "mat4"},
	}
end

local function get_instance_world_expr()
	return "mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
end

local function get_instance_prev_world_expr()
	return "mat4(in_instance_prev_world_row_0, in_instance_prev_world_row_1, in_instance_prev_world_row_2, in_instance_prev_world_row_3)"
end

local function build_vertex_shader(options)
	local enable_vertex_animation = options.enable_vertex_animation ~= false
	local lines = {}

	if enable_vertex_animation then
		lines[#lines + 1] = model_pipeline.BuildVertexAnimationGlsl("vertex_animation", "vertex.world")
	end

	lines[#lines + 1] = "void main() {"
	lines[#lines + 1] = "\tvec3 local_position = in_position;"
	lines[#lines + 1] = "\tvec3 world_position = (vertex.world * vec4(local_position, 1.0)).xyz;"
	lines[#lines + 1] = "\tmat3 world_matrix3 = mat3(vertex.world);"
	lines[#lines + 1] = "\tmat3 inv_world_matrix3 = inverse(world_matrix3);"
	lines[#lines + 1] = "\tvec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);"
	lines[#lines + 1] = "\tvec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);"

	if options.velocity then
		lines[#lines + 1] = "\tvec3 prev_world_position = (vertex.prev_world * vec4(in_position, 1.0)).xyz;"
	end

	if enable_vertex_animation then
		lines[#lines + 1] = "\tvec3 world_offset = get_vertex_animation_offset(world_position, world_normal, world_tangent, in_uv, in_texture_blend, in_vertex_color);"

		if options.velocity then
			lines[#lines + 1] = "\tprev_world_position += get_previous_vertex_animation_offset(prev_world_position, world_normal, world_tangent, in_uv, in_texture_blend, in_vertex_color);"
		end

		lines[#lines + 1] = "\tif (dot(world_offset, world_offset) > 0.0) {"
		lines[#lines + 1] = "\t\tlocal_position += inv_world_matrix3 * world_offset;"
		lines[#lines + 1] = "\t\tworld_position += world_offset;"
		lines[#lines + 1] = "\t\tworld_normal = bend_vertex_animation_direction(world_normal, world_offset);"
		lines[#lines + 1] = "\t\tworld_tangent = bend_vertex_animation_direction(world_tangent, world_offset);"
		lines[#lines + 1] = "\t}"
	end

	if options.include_projection_view_world == false then
		local camera_uniform_block_name = options.camera_uniform_block_name or "camera_data"
		lines[#lines + 1] = "\tgl_Position = " .. camera_uniform_block_name .. ".projection * " .. camera_uniform_block_name .. ".view * vec4(world_position, 1.0);"
	else
		lines[#lines + 1] = "\tgl_Position = vertex.projection_view_world * vec4(local_position, 1.0);"
	end

	if options.position ~= false then
		lines[#lines + 1] = "\tout_position = world_position;"
	end

	if options.velocity then
		lines[#lines + 1] = "\tout_prev_position = prev_world_position;"
	end

	if options.normal then lines[#lines + 1] = "\tout_normal = world_normal;" end

	if options.tangent then
		lines[#lines + 1] = "\tout_tangent = vec4(world_tangent, in_tangent.w);"
	end

	if options.uv then lines[#lines + 1] = "\tout_uv = in_uv;" end

	if options.texture_blend then
		lines[#lines + 1] = "\tout_texture_blend = in_texture_blend;"
	end

	if options.vertex_color then
		lines[#lines + 1] = "\tout_vertex_color = in_vertex_color;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function build_instanced_vertex_shader(options)
	local world_expr = get_instance_world_expr()
	local enable_vertex_animation = options.enable_vertex_animation ~= false
	local lines = {}

	if enable_vertex_animation then
		lines[#lines + 1] = model_pipeline.BuildVertexAnimationGlsl("vertex_animation", world_expr)
	end

	lines[#lines + 1] = "void main() {"
	lines[#lines + 1] = "\tmat4 instance_world = " .. world_expr .. ";"
	lines[#lines + 1] = "\tvec3 local_position = in_position;"
	lines[#lines + 1] = "\tvec3 world_position = (instance_world * vec4(local_position, 1.0)).xyz;"
	lines[#lines + 1] = "\tmat3 world_matrix3 = mat3(instance_world);"
	lines[#lines + 1] = "\tmat3 inv_world_matrix3 = inverse(world_matrix3);"
	lines[#lines + 1] = "\tvec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);"
	lines[#lines + 1] = "\tvec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);"

	if options.velocity then
		-- gpu culled static batches bind one buffer to both instance bindings, so
		-- this is literally the same matrix and the subtraction cancels
		lines[#lines + 1] = "\tmat4 instance_prev_world = " .. get_instance_prev_world_expr() .. ";"
		lines[#lines + 1] = "\tvec3 prev_world_position = (instance_prev_world * vec4(in_position, 1.0)).xyz;"
	end

	if enable_vertex_animation then
		lines[#lines + 1] = "\tvec3 world_offset = get_vertex_animation_offset(world_position, world_normal, world_tangent, in_uv, in_texture_blend, in_vertex_color);"

		if options.velocity then
			lines[#lines + 1] = "\tprev_world_position += get_previous_vertex_animation_offset(prev_world_position, world_normal, world_tangent, in_uv, in_texture_blend, in_vertex_color);"
		end

		lines[#lines + 1] = "\tif (dot(world_offset, world_offset) > 0.0) {"
		lines[#lines + 1] = "\t\tlocal_position += inv_world_matrix3 * world_offset;"
		lines[#lines + 1] = "\t\tworld_position += world_offset;"
		lines[#lines + 1] = "\t\tworld_normal = bend_vertex_animation_direction(world_normal, world_offset);"
		lines[#lines + 1] = "\t\tworld_tangent = bend_vertex_animation_direction(world_tangent, world_offset);"
		lines[#lines + 1] = "\t}"
	end

	if options.include_projection_view == false then
		local camera_uniform_block_name = options.camera_uniform_block_name or "camera_data"
		lines[#lines + 1] = "\tgl_Position = " .. camera_uniform_block_name .. ".projection * " .. camera_uniform_block_name .. ".view * vec4(world_position, 1.0);"
	else
		lines[#lines + 1] = "\tgl_Position = vertex.projection_view * vec4(world_position, 1.0);"
	end

	if options.position ~= false then
		lines[#lines + 1] = "\tout_position = world_position;"
	end

	if options.velocity then
		lines[#lines + 1] = "\tout_prev_position = prev_world_position;"
	end

	if options.normal then lines[#lines + 1] = "\tout_normal = world_normal;" end

	if options.tangent then
		lines[#lines + 1] = "\tout_tangent = vec4(world_tangent, in_tangent.w);"
	end

	if options.uv then lines[#lines + 1] = "\tout_uv = in_uv;" end

	if options.texture_blend then
		lines[#lines + 1] = "\tout_texture_blend = in_texture_blend;"
	end

	if options.vertex_color then
		lines[#lines + 1] = "\tout_vertex_color = in_vertex_color;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function get_vertex_stage_outputs(options)
	local outputs = {}

	if options.position ~= false then
		outputs[#outputs + 1] = {"position", "vec3"}
	end

	if options.normal then outputs[#outputs + 1] = {"normal", "vec3"} end

	if options.tangent then outputs[#outputs + 1] = {"tangent", "vec4"} end

	if options.uv then outputs[#outputs + 1] = {"uv", "vec2"} end

	if options.texture_blend then
		outputs[#outputs + 1] = {"texture_blend", "float"}
	end

	if options.vertex_color then outputs[#outputs + 1] = {"vertex_color", "vec4"} end

	-- appended rather than placed next to position, so that turning velocity on
	-- does not renumber the outputs every other stage already agrees on
	if options.velocity then outputs[#outputs + 1] = {"prev_position", "vec3"} end

	return outputs
end

function model_pipeline.CreateVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	local enable_vertex_animation = options.enable_vertex_animation ~= false
	local include_projection_view_world = options.include_projection_view_world ~= false
	local transform_buffers = {
		{
			name = options.transform_block_name or "vertex",
			block = model_pipeline.GetTransformBlock(include_projection_view_world, options.velocity),
			write = model_pipeline.BuildTransformBlockWriter(
				include_projection_view_world,
				options.get_projection_view_world_matrix,
				options.velocity
			),
		},
	}
	local animation_buffers = {}
	local extra_uniform_buffers = {}

	if options.uniform_buffers then
		for _, buffer in ipairs(options.uniform_buffers) do
			extra_uniform_buffers[#extra_uniform_buffers + 1] = buffer
		end
	end

	if enable_vertex_animation then
		animation_buffers = options.vertex_uniform_buffers or
			{
				{
					name = "vertex_animation",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetVertexAnimationUploadKey,
					block = model_pipeline.GetVertexAnimationBlock(),
					write = model_pipeline.WriteVertexAnimationBlock,
				},
			}
	end

	local stage = {
		binding_index = options.binding_index or 0,
		attributes = model_pipeline.GetVertexAttributes(),
		[storage_key] = transform_buffers,
		shader = build_vertex_shader(options),
	}

	if options.velocity then
		local outputs = model_pipeline.GetVertexAttributes()
		outputs[#outputs + 1] = {"prev_position", "vec3"}
		stage.outputs = outputs
	end

	if storage_key == "uniform_buffers" then
		for _, buffer in ipairs(extra_uniform_buffers) do
			table.insert(transform_buffers, buffer)
		end

		for _, buffer in ipairs(animation_buffers) do
			table.insert(transform_buffers, buffer)
		end

		stage.uniform_buffers = transform_buffers
	else
		local uniform_buffers = {}

		for _, buffer in ipairs(extra_uniform_buffers) do
			uniform_buffers[#uniform_buffers + 1] = buffer
		end

		for _, buffer in ipairs(animation_buffers) do
			uniform_buffers[#uniform_buffers + 1] = buffer
		end

		stage.uniform_buffers = uniform_buffers[1] and uniform_buffers or nil
	end

	return stage
end

function model_pipeline.CreateInstancedVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	local enable_vertex_animation = options.enable_vertex_animation ~= false
	local include_projection_view = options.include_projection_view ~= false
	local transform_buffers = nil
	local animation_buffers = {}
	local extra_uniform_buffers = {}

	if options.uniform_buffers then
		for _, buffer in ipairs(options.uniform_buffers) do
			extra_uniform_buffers[#extra_uniform_buffers + 1] = buffer
		end
	end

	if include_projection_view then
		transform_buffers = {
			{
				name = options.transform_block_name or "vertex",
				block = model_pipeline.GetInstancedTransformBlock(include_projection_view),
				write = model_pipeline.BuildInstancedTransformBlockWriter(include_projection_view, options.get_projection_view_matrix),
			},
		}
	end

	if enable_vertex_animation then
		animation_buffers = options.vertex_uniform_buffers or
			{
				{
					name = "vertex_animation",
					upload_scope = "frame_keyed",
					upload_key = model_pipeline.GetVertexAnimationUploadKey,
					block = model_pipeline.GetVertexAnimationBlock(),
					write = model_pipeline.WriteVertexAnimationBlock,
				},
			}
	end

	local bindings = {
		{
			binding = options.binding_index or 0,
			input_rate = "vertex",
			attributes = model_pipeline.GetVertexAttributes(),
		},
		{
			binding = options.instance_binding_index or 1,
			input_rate = "instance",
			attributes = model_pipeline.GetInstanceAttributes(),
		},
	}

	if options.velocity then
		bindings[#bindings + 1] = {
			binding = options.prev_instance_binding_index or 2,
			input_rate = "instance",
			attributes = model_pipeline.GetPreviousInstanceAttributes(),
		}
	end

	local stage = {
		bindings = bindings,
		outputs = get_vertex_stage_outputs(options),
		shader = build_instanced_vertex_shader(options),
	}

	if transform_buffers then stage[storage_key] = transform_buffers end

	if storage_key == "uniform_buffers" then
		stage.uniform_buffers = transform_buffers or {}

		for _, buffer in ipairs(extra_uniform_buffers) do
			table.insert(stage.uniform_buffers, buffer)
		end

		for _, buffer in ipairs(animation_buffers) do
			table.insert(stage.uniform_buffers, buffer)
		end
	else
		local uniform_buffers = {}

		for _, buffer in ipairs(extra_uniform_buffers) do
			uniform_buffers[#uniform_buffers + 1] = buffer
		end

		for _, buffer in ipairs(animation_buffers) do
			uniform_buffers[#uniform_buffers + 1] = buffer
		end

		stage.uniform_buffers = uniform_buffers[1] and uniform_buffers or nil
	end

	return stage
end

local function build_material_block(field_defs)
	local block = {}

	for i, def in ipairs(field_defs) do
		if def.type == "texture" then
			block[i] = {def.name, "int"}
		else
			block[i] = {def.name, def.type}
		end
	end

	return block
end

local function build_material_block_writer(name, field_defs)
	local lines = {
		"return function(get_material)",
		"\treturn function(self, block, material)",
		"\tmaterial = material or get_material()",
	}

	for _, def in ipairs(field_defs) do
		if def.type == "texture" then
			lines[#lines + 1] = string.format("\tblock.%s = self:GetTextureIndex(material:%s())", def.name, def.getter)
		elseif def.type == "vec2" or def.type == "vec3" or def.type == "vec4" then
			lines[#lines + 1] = string.format("\tmaterial:%s():CopyToFloatPointer(block.%s)", def.getter, def.name)
		else
			lines[#lines + 1] = string.format("\tblock.%s = material:%s()", def.name, def.getter)
		end
	end

	lines[#lines + 1] = "\t\treturn block"
	lines[#lines + 1] = "\tend"
	lines[#lines + 1] = "end"
	return assert(loadstring(table.concat(lines, "\n"), name .. "_material_block_writer"))()(get_material)
end

local SURFACE_MATERIAL_BLOCK = build_material_block(SURFACE_MATERIAL_FIELDS)
local PBR_MATERIAL_BLOCK = build_material_block(PBR_MATERIAL_FIELDS)
local PROBE_MATERIAL_BLOCK = build_material_block(PROBE_MATERIAL_FIELDS)
local PBR_COLOR_BLOCK = build_material_block(PBR_COLOR_FIELDS)
local PBR_FACTOR_BLOCK = build_material_block(PBR_FACTOR_FIELDS)
local PBR_DETAIL_BLOCK = build_material_block(PBR_DETAIL_FIELDS)
local PBR_AUX_BLOCK = build_material_block(PBR_AUX_FIELDS)
local PBR_DISPLACEMENT_BLOCK = build_material_block(PBR_DISPLACEMENT_FIELDS)
local PBR_TERRAIN_BLOCK = build_material_block(PBR_TERRAIN_FIELDS)
local PBR_TRANSMISSION_BLOCK = build_material_block(PBR_TRANSMISSION_FIELDS)
local WRITE_SURFACE_MATERIAL_BLOCK = build_material_block_writer("surface", SURFACE_MATERIAL_FIELDS)
local WRITE_PBR_MATERIAL_BLOCK = build_material_block_writer("pbr", PBR_MATERIAL_FIELDS)
local WRITE_PBR_COLOR_BLOCK = build_material_block_writer("pbr_color", PBR_COLOR_FIELDS)
local WRITE_PBR_FACTOR_BLOCK = build_material_block_writer("pbr_factor", PBR_FACTOR_FIELDS)
local WRITE_PBR_DETAIL_BLOCK = build_material_block_writer("pbr_detail", PBR_DETAIL_FIELDS)
local WRITE_PBR_AUX_BLOCK = build_material_block_writer("pbr_aux", PBR_AUX_FIELDS)
local WRITE_PBR_DISPLACEMENT_BLOCK = build_material_block_writer("pbr_displacement", PBR_DISPLACEMENT_FIELDS)
local WRITE_PBR_TERRAIN_BLOCK = build_material_block_writer("pbr_terrain", PBR_TERRAIN_FIELDS)
local WRITE_PBR_TRANSMISSION_BLOCK = build_material_block_writer("pbr_transmission", PBR_TRANSMISSION_FIELDS)
local WRITE_PROBE_MATERIAL_BLOCK = build_material_block_writer("probe", PROBE_MATERIAL_FIELDS)
local NO_PBR_COLOR_KEY = {}
local NO_PBR_FACTOR_KEY = {}
local NO_PBR_DETAIL_KEY = {}
local NO_PBR_AUX_KEY = {}
local NO_PBR_DISPLACEMENT_KEY = {}
local NO_PBR_TERRAIN_KEY = {}
local NO_PBR_TRANSMISSION_KEY = {}

function model_pipeline.GetSurfaceMaterialBlock()
	return SURFACE_MATERIAL_BLOCK
end

function model_pipeline.GetPBRMaterialBlock()
	return PBR_MATERIAL_BLOCK
end

function model_pipeline.GetProbeMaterialBlock()
	return PROBE_MATERIAL_BLOCK
end

function model_pipeline.GetPBRColorMaterialBlock()
	return PBR_COLOR_BLOCK
end

function model_pipeline.GetPBRFactorMaterialBlock()
	return PBR_FACTOR_BLOCK
end

function model_pipeline.GetPBRDetailMaterialBlock()
	return PBR_DETAIL_BLOCK
end

function model_pipeline.GetPBRAuxMaterialBlock()
	return PBR_AUX_BLOCK
end

function model_pipeline.GetPBRDisplacementMaterialBlock()
	return PBR_DISPLACEMENT_BLOCK
end

function model_pipeline.GetPBRTerrainMaterialBlock()
	return PBR_TERRAIN_BLOCK
end

function model_pipeline.GetPBRTransmissionMaterialBlock()
	return PBR_TRANSMISSION_BLOCK
end

function model_pipeline.WriteSurfaceMaterialBlock(self, block)
	return WRITE_SURFACE_MATERIAL_BLOCK(self, block)
end

function model_pipeline.WritePBRMaterialBlock(self, block)
	return WRITE_PBR_MATERIAL_BLOCK(self, block)
end

function model_pipeline.WritePBRColorMaterialBlock(self, block)
	return WRITE_PBR_COLOR_BLOCK(self, block)
end

function model_pipeline.WritePBRFactorMaterialBlock(self, block)
	return WRITE_PBR_FACTOR_BLOCK(self, block)
end

function model_pipeline.WritePBRDetailMaterialBlock(self, block)
	return WRITE_PBR_DETAIL_BLOCK(self, block)
end

function model_pipeline.WritePBRAuxMaterialBlock(self, block)
	return WRITE_PBR_AUX_BLOCK(self, block)
end

function model_pipeline.WritePBRDisplacementMaterialBlock(self, block)
	return WRITE_PBR_DISPLACEMENT_BLOCK(self, block)
end

function model_pipeline.WritePBRTerrainMaterialBlock(self, block)
	return WRITE_PBR_TERRAIN_BLOCK(self, block)
end

function model_pipeline.WritePBRTransmissionMaterialBlock(self, block)
	return WRITE_PBR_TRANSMISSION_BLOCK(self, block)
end

function model_pipeline.WriteProbeMaterialBlock(self, block)
	return WRITE_PROBE_MATERIAL_BLOCK(self, block)
end

function model_pipeline.GetPBRTerrainUploadKey()
	local material = get_material()

	if not material then return NO_PBR_TERRAIN_KEY end

	if material:GetTerrainMaterialTexture() == nil then return NO_PBR_TERRAIN_KEY end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRColorUploadKey()
	local material = get_material()

	if not material then return NO_PBR_COLOR_KEY end

	local color = material:GetColorMultiplier()

	if color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1 then
		return NO_PBR_COLOR_KEY
	end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRFactorUploadKey()
	local material = get_material()

	if not material then return NO_PBR_FACTOR_KEY end

	local has_default_scalars = material:GetMetallicMultiplier() == 1.0 and
		material:GetRoughnessMultiplier() == 1.0 and
		material:GetSpecularMultiplier() == 1.0 and
		material:GetAlphaCutoff() == 0.5

	if has_default_scalars then return NO_PBR_FACTOR_KEY end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRAuxUploadKey()
	local material = get_material()

	if not material then return NO_PBR_AUX_KEY end

	local uses_metallic_detail = material:GetMetallicRoughnessTexture() ~= nil or
		material:GetMetallicTexture() ~= nil or
		material:GetRoughnessTexture() ~= nil or
		material:GetOpacityTexture() ~= nil
	local uses_ao = material:GetAmbientOcclusionTexture() ~= nil or
		material:GetAmbientOcclusionMultiplier() ~= 1.0
	local uses_emissive = material:GetEmissiveTexture() ~= nil or
		material:GetAlbedoAlphaIsEmissive() or
		material:GetMetallicTextureAlphaIsEmissive()

	if not (uses_metallic_detail or uses_ao or uses_emissive) then
		return NO_PBR_AUX_KEY
	end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRDetailUploadKey()
	local material = get_material()

	if not material then return NO_PBR_DETAIL_KEY end

	if
		material:GetAlbedo2Texture() == nil and
		material:GetNormal2Texture() == nil and
		material:GetBlendTexture() == nil and
		material:GetDetailTexture() == nil
	then
		return NO_PBR_DETAIL_KEY
	end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRDisplacementUploadKey()
	local material = get_material()

	if not material then return NO_PBR_DISPLACEMENT_KEY end

	if not material:GetHeightTexture() or material:GetHeightScale() <= 0 then
		return NO_PBR_DISPLACEMENT_KEY
	end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRTransmissionUploadKey()
	local material = get_material()

	if not material then return NO_PBR_TRANSMISSION_KEY end

	if not material:GetSubsurface() then return NO_PBR_TRANSMISSION_KEY end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetVertexAnimationUniformBufferDecl()
	local fields = {
		"float Time;",
		"float PrevTime;",
		"float WindAmplitude;",
		"float WindFrequency;",
		"float WindDetailAmplitude;",
		"float WindDetailFrequency;",
		"float WindPhaseScale;",
		"float WindNormalInfluence;",
		"float WindDirection[3];",
		"int BranchHelperCount;",
	}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		fields[#fields + 1] = string.format("float BranchHelper%d[4];", i)
	end

	return ([[
		struct {
			%s
		}
	]]):format(table.concat(fields, "\n\t\t\t"))
end

function model_pipeline.BuildVertexAnimationUniformDeclaration(block_name, binding_index)
	block_name = block_name or "vertex_animation"
	binding_index = binding_index or 0
	local fields = {
		"\t\t\t\tfloat Time;",
		"\t\t\t\tfloat PrevTime;",
		"\t\t\t\tfloat WindAmplitude;",
		"\t\t\t\tfloat WindFrequency;",
		"\t\t\t\tfloat WindDetailAmplitude;",
		"\t\t\t\tfloat WindDetailFrequency;",
		"\t\t\t\tfloat WindPhaseScale;",
		"\t\t\t\tfloat WindNormalInfluence;",
		"\t\t\t\tvec3 WindDirection;",
		"\t\t\t\tint BranchHelperCount;",
	}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		fields[#fields + 1] = string.format("\t\t\t\tvec4 BranchHelper%d;", i)
	end

	return (
		[[
			layout(scalar, binding = %d) uniform VertexAnimation_t {
		%s
			} %s;
	]]
	):format(binding_index, table.concat(fields, "\n"), block_name)
end

function model_pipeline.FillVertexAnimationData(block, material)
	material = material or get_material()
	local wind_amplitude = material:GetWindAmplitude()
	local wind_detail_amplitude = material:GetWindDetailAmplitude()
	block.WindAmplitude = wind_amplitude
	block.WindDetailAmplitude = wind_detail_amplitude

	if wind_amplitude <= 0 and wind_detail_amplitude <= 0 then
		block.BranchHelperCount = 0
		return block
	end

	block.Time = system.GetElapsedTime()
	block.PrevTime = render3d.GetPreviousElapsedTime()
	block.WindFrequency = material:GetWindFrequency()
	block.WindDetailFrequency = material:GetWindDetailFrequency()
	block.WindPhaseScale = material:GetWindPhaseScale()
	block.WindNormalInfluence = material:GetWindNormalInfluence()
	local wind_direction = material:GetWindDirection()
	block.WindDirection[0] = wind_direction.x
	block.WindDirection[1] = wind_direction.y
	block.WindDirection[2] = wind_direction.z
	local polygon = render3d.GetCurrentPolygon3D()
	local pivots = polygon and
		polygon.GetBranchHelperPivots and
		polygon:GetBranchHelperPivots() or
		nil
	local helper_count = math.min(pivots and #pivots or 0, MAX_BRANCH_HELPERS)
	block.BranchHelperCount = helper_count

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		local field = block[BRANCH_HELPER_KEYS[i + 1]]
		local pivot = pivots and pivots[i + 1] or nil

		if i < helper_count and pivot then
			field[0] = pivot.x
			field[1] = pivot.y
			field[2] = pivot.z
			field[3] = 1
		else
			field[0] = 0
			field[1] = 0
			field[2] = 0
			field[3] = 0
		end
	end
end

function model_pipeline.GetVertexAnimationBlock()
	local block = {
		{"Time", "float"},
		{"PrevTime", "float"},
		{"WindAmplitude", "float"},
		{"WindFrequency", "float"},
		{"WindDetailAmplitude", "float"},
		{"WindDetailFrequency", "float"},
		{"WindPhaseScale", "float"},
		{"WindNormalInfluence", "float"},
		{"WindDirection", "vec3"},
		{"BranchHelperCount", "int"},
	}

	for i = 1, MAX_BRANCH_HELPERS do
		block[#block + 1] = {BRANCH_HELPER_KEYS[i], "vec4"}
	end

	return block
end

function model_pipeline.WriteVertexAnimationBlock(self, block)
	return model_pipeline.FillVertexAnimationData(block)
end

function model_pipeline.GetVertexAnimationUploadKey()
	local material = get_material()

	if not material then return render3d.GetDefaultMaterial() end

	if material:GetWindAmplitude() > 0 or material:GetWindDetailAmplitude() > 0 then
		return nil
	end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.BuildVertexAnimationGlsl(block_name, helper_world_matrix_expr)
	block_name = block_name or "vertex_animation"
	helper_world_matrix_expr = helper_world_matrix_expr or "mat4(1.0)"
	local helper_cases = {}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		helper_cases[#helper_cases + 1] = string.format(
			"\t\t\t\tif (index == %d) return (%s * vec4(%s.BranchHelper%d.xyz, 1.0)).xyz;",
			i,
			helper_world_matrix_expr,
			block_name,
			i
		)
	end

	return [[
			bool has_authored_vertex_animation(vec4 vertex_color) {
				return dot(vertex_color, vec4(1.0)) > 0.0001;
			}

			float get_vertex_animation_weight(vec2 uv, float texture_blend, vec4 vertex_color) {
				if (has_authored_vertex_animation(vertex_color)) {
					float leaf_mask = clamp(vertex_color.r, 0.0, 1.0);
					float broad_bend = clamp(vertex_color.a, 0.0, 1.0);
					return leaf_mask * broad_bend;
				}

				return clamp(max(texture_blend, uv.y), 0.0, 1.0);
			}

			bool has_vertex_animation() {
				return ]] .. block_name .. [[.WindAmplitude > 0.0 || ]] .. block_name .. [[.WindDetailAmplitude > 0.0;
			}

			vec3 get_branch_helper_pivot(int index) {
			]] .. table.concat(helper_cases, "\n") .. [[
				return vec3(0.0);
			}

			int get_nearest_branch_helper_index(vec3 world_pos) {
				int helper_count = ]] .. block_name .. [[.BranchHelperCount;
				if (helper_count <= 0) return -1;

				int nearest_helper = 0;
				float nearest_dist_sq = 1e30;

				for (int i = 0; i < helper_count; i++) {
					vec3 helper_pivot = get_branch_helper_pivot(i);
					vec2 to_helper = world_pos.xz - helper_pivot.xz;
					float dist_sq = dot(to_helper, to_helper);

					if (dist_sq < nearest_dist_sq) {
						nearest_dist_sq = dist_sq;
						nearest_helper = i;
					}
				}

				return nearest_helper;
			}

			float get_branch_helper_height(vec3 world_pos) {
				int nearest_helper = get_nearest_branch_helper_index(world_pos);
				if (nearest_helper < 0) return 0.0;
				vec3 pivot = get_branch_helper_pivot(nearest_helper);
				return max(world_pos.y - pivot.y, 0.0);
			}

			vec3 get_branch_helper_offset(vec3 world_pos, vec3 wind_dir, float carrier_bend) {
				if (abs(carrier_bend) <= 0.00001) return wind_dir * carrier_bend;
				int nearest_helper = get_nearest_branch_helper_index(world_pos);
				if (nearest_helper < 0) return wind_dir * carrier_bend;
				vec3 pivot = get_branch_helper_pivot(nearest_helper);
				float rel_height = max(world_pos.y - pivot.y, 0.0);
				return wind_dir * (rel_height * carrier_bend);
			}

			vec3 get_vertex_animation_offset_at_time(vec3 world_pos, vec3 world_normal, vec3 world_tangent, vec2 uv, float texture_blend, vec4 vertex_color, float anim_time) {
				if (!has_vertex_animation()) return vec3(0.0);

				vec3 wind_dir = ]] .. block_name .. [[.WindDirection;
				float wind_len = length(wind_dir.xz);
				if (wind_len <= 0.0001) wind_dir = vec3(1.0, 0.0, 0.0);
				else wind_dir = normalize(vec3(wind_dir.x, 0.0, wind_dir.z));

				vec4 authored = clamp(vertex_color, 0.0, 1.0);
				bool use_authored = has_authored_vertex_animation(authored);
				float weight = get_vertex_animation_weight(uv, texture_blend, authored);
				float leaf_mask = use_authored ? authored.r : weight;
				float carrier_weight = use_authored ? authored.g : weight;
				float edge_weight = use_authored ? clamp(1.0 - authored.b, 0.0, 1.0) : clamp(1.0 - abs(uv.x * 2.0 - 1.0), 0.0, 1.0);
				float broad_bend = use_authored ? authored.a : weight;
				float helper_height = get_branch_helper_height(world_pos);
				float white_rgb = use_authored ? smoothstep(0.95, 0.999, min(authored.r, min(authored.g, authored.b))) : 0.0;
				float root_release = smoothstep(0.35, 1.5, helper_height);
				float white_anchor = mix(0.05, 1.0, root_release);
				float stiffness = use_authored ? clamp((1.0 - authored.r) * authored.b, 0.0, 1.0) : clamp(1.0 - weight, 0.0, 1.0);
				stiffness = max(stiffness, white_rgb * (1.0 - root_release) * 0.95);
				float flexibility = (1.0 - stiffness) * mix(1.0, white_anchor, white_rgb);
				float carrier_flexibility = flexibility * flexibility;
				broad_bend *= mix(1.0, white_anchor, white_rgb);
				float phase_offset = uv.x * 6.2831853;
				float carrier_phase = anim_time * (]] .. block_name .. [[.WindFrequency * 0.65);
				float carrier_wave = sin(carrier_phase);
				float phase = anim_time * ]] .. block_name .. [[.WindFrequency;
				phase += dot(world_pos.xz, wind_dir.xz) * ]] .. block_name .. [[.WindPhaseScale;
				phase += phase_offset;
				float main_wave = sin(phase);

				vec2 detail_dir = vec2(-wind_dir.z, wind_dir.x);
				float detail_phase = anim_time * (]] .. block_name .. [[.WindFrequency * ]] .. block_name .. [[.WindDetailFrequency);
				detail_phase += dot(world_pos.xz, detail_dir) * (]] .. block_name .. [[.WindPhaseScale * 2.7);
				detail_phase += phase_offset * 1.37;
				float detail_wave = sin(detail_phase);

				vec3 tangent_dir = normalize(world_tangent - world_normal * dot(world_tangent, world_normal));
				if (length(tangent_dir) <= 0.0001) tangent_dir = normalize(cross(world_normal, vec3(0.0, 1.0, 0.0)));
				if (length(tangent_dir) <= 0.0001) tangent_dir = vec3(1.0, 0.0, 0.0);

				float carrier_bend = carrier_wave * ]] .. block_name .. [[.WindAmplitude * carrier_weight * broad_bend * carrier_flexibility * 0.18;
				float branch_bend = main_wave * ]] .. block_name .. [[.WindAmplitude * broad_bend * leaf_mask * flexibility;
				float edge_bend = detail_wave * ]] .. block_name .. [[.WindDetailAmplitude * broad_bend * edge_weight * leaf_mask * flexibility;
				vec3 offset = get_branch_helper_offset(world_pos, wind_dir, carrier_bend);
				offset += wind_dir * branch_bend;
				offset += tangent_dir * edge_bend;
				return offset;
			}

			vec3 get_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec3 world_tangent, vec2 uv, float texture_blend, vec4 vertex_color) {
				return get_vertex_animation_offset_at_time(world_pos, world_normal, world_tangent, uv, texture_blend, vertex_color, ]] .. block_name .. [[.Time);
			}

			vec3 get_previous_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec3 world_tangent, vec2 uv, float texture_blend, vec4 vertex_color) {
				return get_vertex_animation_offset_at_time(world_pos, world_normal, world_tangent, uv, texture_blend, vertex_color, ]] .. block_name .. [[.PrevTime);
			}

			vec3 bend_vertex_animation_direction(vec3 direction, vec3 world_offset) {
				float offset_len = length(world_offset);
				if (offset_len <= 0.00001 || ]] .. block_name .. [[.WindNormalInfluence <= 0.0) return normalize(direction);
				return normalize(direction + normalize(world_offset) * (offset_len * ]] .. block_name .. [[.WindNormalInfluence));
			}
	]]
end

function model_pipeline.BuildAlphaDiscardGlsl(alpha_cutoff_expr)
	alpha_cutoff_expr = alpha_cutoff_expr or "model.AlphaCutoff"
	return (
		[[
			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
					if (alpha < %s) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}
			}
		]]
	):format(alpha_cutoff_expr)
end

function model_pipeline.BuildBindlessAlphaSamplingGlsl(texture_index_expr, color_multiplier_a_expr, opacity_texture_index_expr)
	texture_index_expr = texture_index_expr or "pc.albedo_texture_index"
	color_multiplier_a_expr = color_multiplier_a_expr or "pc.color_multiplier_a"
	opacity_texture_index_expr = opacity_texture_index_expr or "-1"
	return (
		[[
			float get_alpha_uv(vec2 uv) {
				if (%s != -1) {
					vec4 mask = textureLod(textures[nonuniformEXT(%s)], uv, 0.0);
					return clamp(max(max(mask.r, mask.g), max(mask.b, mask.a)), 0.0, 1.0) * %s;
				}

				if (
					%s == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return %s;
				}

				return textureLod(textures[nonuniformEXT(%s)], uv, 0.0).a * %s;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
		]]
	):format(
		opacity_texture_index_expr,
		opacity_texture_index_expr,
		color_multiplier_a_expr,
		texture_index_expr,
		color_multiplier_a_expr,
		texture_index_expr,
		color_multiplier_a_expr
	)
end

function model_pipeline.BuildSurfaceSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			vec4 get_surface_color() {
				vec4 color = ]] .. model_var .. [[.ColorMultiplier;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					color *= texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv);
				}

				return color;
			}

			void discard_surface_alpha(vec4 color) {
				if (AlphaTest && color.a < ]] .. model_var .. [[.AlphaCutoff) discard;
			}

			vec3 get_surface_emissive(vec3 albedo) {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;

					if (]] .. model_var .. [[.AlbedoTexture != -1) {
						mask = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv).a;
					}

					return albedo * mask * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				if (]] .. model_var .. [[.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(]] .. model_var .. [[.EmissiveTexture), in_uv).rgb;
					return emissive * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				return vec3(0.0);
			}
	]]
end

function model_pipeline.GetPBRUniformBuffers()
	return {
		{
			name = "model",
			upload_scope = "persistent_keyed",
			upload_key = render3d.GetMaterialUploadKey,
			block = model_pipeline.GetPBRMaterialBlock(),
			write = model_pipeline.WritePBRMaterialBlock,
		},
		{
			name = "color_model",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRColorUploadKey,
			block = model_pipeline.GetPBRColorMaterialBlock(),
			write = model_pipeline.WritePBRColorMaterialBlock,
		},
		{
			name = "factor_model",
			upload_scope = "persistent_keyed",
			upload_key = model_pipeline.GetPBRFactorUploadKey,
			block = model_pipeline.GetPBRFactorMaterialBlock(),
			write = model_pipeline.WritePBRFactorMaterialBlock,
		},
		{
			name = "detail_model",
			upload_scope = "persistent_keyed",
			upload_key = model_pipeline.GetPBRDetailUploadKey,
			block = model_pipeline.GetPBRDetailMaterialBlock(),
			write = model_pipeline.WritePBRDetailMaterialBlock,
		},
		{
			name = "aux_model",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRAuxUploadKey,
			block = model_pipeline.GetPBRAuxMaterialBlock(),
			write = model_pipeline.WritePBRAuxMaterialBlock,
		},
		{
			name = "displacement_model",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRDisplacementUploadKey,
			block = model_pipeline.GetPBRDisplacementMaterialBlock(),
			write = model_pipeline.WritePBRDisplacementMaterialBlock,
		},
		{
			name = "terrain_model",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRTerrainUploadKey,
			block = model_pipeline.GetPBRTerrainMaterialBlock(),
			write = model_pipeline.WritePBRTerrainMaterialBlock,
		},
		{
			name = "transmission_model",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRTransmissionUploadKey,
			block = model_pipeline.GetPBRTransmissionMaterialBlock(),
			write = model_pipeline.WritePBRTransmissionMaterialBlock,
		},
	}
end

-- The material side of a lit surface: what the gbuffer writes and the
-- forward passes shade. Wants the GetPBRUniformBuffers blocks and a vertex
-- stage with position, normal, tangent, uv, texture_blend and vertex_color.
function model_pipeline.BuildPBRSurfaceGlsl()
	local model_var = "model"
	local terrain_var = "terrain_model"
	local displacement_var = "displacement_model"
	local detail_var = "detail_model"
	local factor_var = "factor_model"
	local color_var = "color_model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			bool has_heightmap() {
				return ]] .. displacement_var .. [[.HeightTexture != -1 && ]] .. displacement_var .. [[.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(]] .. displacement_var .. [[.HeightTexture), uv).r;
			}

			float get_height_centered_sample(vec2 uv) {
				return get_height_sample(uv) - ]] .. displacement_var .. [[.HeightCenter;
			}

			int get_height_layers() {
				return clamp(]] .. displacement_var .. [[.HeightLayers, 4, 64);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. detail_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				// source blendmodulate: g is the transition center, r its half width
				vec2 modulate = texture(TEXTURE(]] .. detail_var .. [[.BlendTexture), uv).rg;
				return smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), in_texture_blend);
			}

			float get_texture_blend() {
				return get_texture_blend_uv(in_uv);
			}

			vec3 get_terrain_world_normal(vec2 uv) {
				if (]] .. model_var .. [[.NormalTexture == -1) {
					return vec3(0.0, 1.0, 0.0);
				}

				vec2 n = texture(TEXTURE(]] .. model_var .. [[.NormalTexture), uv).xy * 2.0 - 1.0;
				return normalize(vec3(n.x, sqrt(max(1.0 - dot(n, n), 0.0)), n.y));
			}

			vec3 get_terrain_triplanar_weights(vec3 normal) {
				vec3 w = pow(abs(normal), vec3(4.0));
				return w / max(w.x + w.y + w.z, 0.0001);
			}

			vec4 sample_terrain_layer_triplanar(int tex, vec3 world_pos, float scale, vec3 blend) {
				float safe_scale = max(scale, 0.0001);
				vec4 result = vec4(0.0);

				if (blend.y > 0.001) {
					result += texture(TEXTURE(tex), world_pos.xz / safe_scale) * blend.y;
				}

				if (blend.x > 0.001) {
					result += texture(TEXTURE(tex), world_pos.zy / safe_scale) * blend.x;
				}

				if (blend.z > 0.001) {
					result += texture(TEXTURE(tex), world_pos.xy / safe_scale) * blend.z;
				}

				return result;
			}

			vec4 sample_terrain_layer_normal_triplanar(int tex, vec3 world_pos, float scale, vec3 blend, vec3 N) {
				float safe_scale = max(scale, 0.0001);
				vec3 n = vec3(0.0);
				float ao = 0.0;

				if (blend.y > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.xz / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xz, abs(tn.z) * N.y);
					n += tn.xzy * blend.y;
					ao += t.a * blend.y;
				}

				if (blend.x > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.zy / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.zy, abs(tn.z) * N.x);
					n += tn.zyx * blend.x;
					ao += t.a * blend.x;
				}

				if (blend.z > 0.001) {
					vec4 t = texture(TEXTURE(tex), world_pos.xy / safe_scale);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xy, abs(tn.z) * N.z);
					n += tn.xyz * blend.z;
					ao += t.a * blend.z;
				}

				return vec4(n, ao);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. terrain_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. terrain_var .. [[.TerrainMaterialTexture), uv);
				weights = max(weights, vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) {
					return vec4(0.0);
				}

				return weights / weight_sum;
			}

			struct TerrainLayerSample {
				vec3 albedo;
				float roughness;
				vec3 normal;
				float ao;
				float normal_weight;
			};

			TerrainLayerSample terrain_layer_cache;
			bool terrain_layer_cache_valid = false;

			void accumulate_terrain_layer(inout TerrainLayerSample s, int albedo_tex, int normal_tex, vec3 world_pos, vec3 blend, vec3 N, float weight, float scale) {
				if (weight <= 0.001) {
					return;
				}

				if (albedo_tex != -1) {
					vec4 albedo = sample_terrain_layer_triplanar(albedo_tex, world_pos, scale, blend);
					s.albedo += albedo.rgb * weight;
					s.roughness += albedo.a * weight;
				} else {
					s.albedo += vec3(weight);
					s.roughness += weight;
				}

				if (normal_tex != -1) {
					vec4 n = sample_terrain_layer_normal_triplanar(normal_tex, world_pos, scale, blend, N);
					s.normal += n.xyz * weight;
					s.ao += n.w * weight;
					s.normal_weight += weight;
				}
			}

			TerrainLayerSample get_terrain_layer_sample(vec2 uv, vec3 world_pos) {
				if (terrain_layer_cache_valid) {
					return terrain_layer_cache;
				}

				TerrainLayerSample s;
				s.albedo = vec3(0.0);
				s.roughness = 0.0;
				s.normal = vec3(0.0);
				s.ao = 0.0;
				s.normal_weight = 0.0;
				vec4 weights = get_terrain_material_weights_uv(uv);
				vec3 N = get_terrain_world_normal(uv);
				vec3 blend = get_terrain_triplanar_weights(N);
				vec4 scales = ]] .. terrain_var .. [[.TerrainLayerScales;
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer1Texture, ]] .. terrain_var .. [[.TerrainLayer1NormalTexture, world_pos, blend, N, weights.x, scales.x);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer2Texture, ]] .. terrain_var .. [[.TerrainLayer2NormalTexture, world_pos, blend, N, weights.y, scales.y);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer3Texture, ]] .. terrain_var .. [[.TerrainLayer3NormalTexture, world_pos, blend, N, weights.z, scales.z);
				accumulate_terrain_layer(s, ]] .. terrain_var .. [[.TerrainLayer4Texture, ]] .. terrain_var .. [[.TerrainLayer4NormalTexture, world_pos, blend, N, weights.w, scales.w);

				if (s.normal_weight > 0.001) {
					s.normal = normalize(mix(N, normalize(s.normal), s.normal_weight));
					s.ao = mix(1.0, s.ao / s.normal_weight, s.normal_weight);
				} else {
					s.normal = N;
					s.ao = 1.0;
				}

				terrain_layer_cache = s;
				terrain_layer_cache_valid = true;
				return s;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. color_var .. [[.ColorMultiplier.rgb;
				}

				vec3 color = get_terrain_layer_sample(uv, world_pos).albedo;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. color_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. terrain_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. color_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. detail_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. detail_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				if (]] .. detail_var .. [[.DetailTexture != -1) {
					vec2 detail_uv = uv * ]] .. detail_var .. [[.DetailTiling;
					float detail = texture(TEXTURE(]] .. detail_var .. [[.DetailTexture), detail_uv).a + texture(TEXTURE(]] .. detail_var .. [[.DetailTexture), detail_uv * 2.0).a;
					rgb1 = mix(rgb1, rgb1 * detail, ]] .. detail_var .. [[.DetailBlendAmount);
				}

				return rgb1 * ]] .. color_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}

			float get_alpha_uv(vec2 uv) {
				if (
					]] .. model_var .. [[.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return ]] .. color_var .. [[.ColorMultiplier.a;
				}

				return texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).a * ]] .. color_var .. [[.ColorMultiplier.a;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
	]] .. model_pipeline.BuildAlphaDiscardGlsl("factor_model.AlphaCutoff") .. [[
			vec3 get_vertex_normal() {
				vec3 N = in_normal;

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			mat3 get_tbn() {
				vec3 normal = normalize(in_normal);
				vec3 tangent = normalize(in_tangent.xyz);
				vec3 bitangent = cross(normal, tangent) * in_tangent.w;

				if (DoubleSided && gl_FrontFacing) {
					normal = -normal;
					bitangent = -bitangent;
				}

				return mat3(tangent, bitangent, normal);
			}

			vec3 get_height_normal_tangent(vec2 uv) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(displacement_model.HeightTexture), 0));
				float left = get_height_centered_sample(uv - vec2(texel.x, 0.0));
				float right = get_height_centered_sample(uv + vec2(texel.x, 0.0));
				float down = get_height_centered_sample(uv - vec2(0.0, texel.y));
				float up = get_height_centered_sample(uv + vec2(0.0, texel.y));
				return normalize(vec3(left - right, down - up, max(displacement_model.HeightScale, 0.0001)));
			}

			vec3 decode_normal_map(vec2 xy) {
				xy = xy * 2.0 - 1.0;

				if (ReverseXZNormalMap) {
					xy = -xy;
				}

				return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
			}

			vec3 get_normal_map(vec2 uv) {
				vec3 N = vec3(0.0, 0.0, 1.0);

				if (model.NormalTexture != -1) {
					N = decode_normal_map(texture(TEXTURE(model.NormalTexture), uv).xy);
				} else if (has_heightmap()) {
					N = get_height_normal_tangent(uv);
				}

				if (detail_model.Normal2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						N = normalize(mix(N, decode_normal_map(texture(TEXTURE(detail_model.Normal2Texture), uv).xy), blend));
					}
				}

				// crysis detail bump: two octaves centered on 0.5 offset the normal's slope
				if (detail_model.DetailTexture != -1) {
					vec2 detail_uv = uv * detail_model.DetailTiling;
					vec2 detail = texture(TEXTURE(detail_model.DetailTexture), detail_uv).xy + texture(TEXTURE(detail_model.DetailTexture), detail_uv * 2.0).xy;
					detail = (detail - 1.0) * detail_model.DetailBumpScale;
					N.xy += ReverseXZNormalMap ? -detail : detail;
				}

				return normalize(N);
			}

			vec3 get_combined_normal(vec2 uv, mat3 tbn) {
				vec3 N = tbn * get_normal_map(uv);

				if (DoubleSided && gl_FrontFacing) {
					N = -N;
				}

				return normalize(N);
			}

			vec3 get_normal(vec2 uv, mat3 tbn) {
				vec3 N = get_combined_normal(uv, tbn);

				if (terrain_model.TerrainMaterialTexture != -1) {
					return get_terrain_layer_sample(uv, in_position).normal;
				}

				return N;
			}

			float get_metallic(vec2 uv) {
				float val = 1.0;

				if (aux_model.MetallicTexture != -1) {
					val = texture(TEXTURE(aux_model.MetallicTexture), uv).r;
				} else if (aux_model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).b;
				} else {
					val = factor_model.MetallicMultiplier;
					val = clamp(val, 0, 1);
					return val;
				}

				val *= factor_model.MetallicMultiplier;
				val = clamp(val, 0, 1);

				return val;
			}

			float get_roughness(vec2 uv) {
				float val = 1.0;

				if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = texture(TEXTURE(model.AlbedoTexture), uv).a;
				} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					val = -texture(TEXTURE(model.NormalTexture), uv).a + 1.0;
				} else if (AlbedoLuminanceIsRoughness) {
					val = dot(get_albedo_uv(uv), vec3(0.2126, 0.7152, 0.0722));
				} else if (aux_model.RoughnessTexture != -1) {
					val = texture(TEXTURE(aux_model.RoughnessTexture), uv).r;
				} else if (aux_model.MetallicRoughnessTexture != -1) {
					val = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).g;
				} else if (terrain_model.TerrainMaterialTexture != -1) {
					val = dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerRoughness) * get_terrain_layer_sample(uv, in_position).roughness;
				} else {
					val = factor_model.RoughnessMultiplier;
					return clamp(val * val, 0.002, 1.0);
				}

				val *= factor_model.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				// perceptual roughness in, GGX alpha out
				val *= val;
				val = clamp(val, 0.002, 1.0);
				return val;
			}

			float get_subsurface(vec2 uv) {
				if (!Subsurface) return 0.0;

				float strength = DoubleSided ? 1.0 : 0.35;

				if (model.AlbedoTexture != -1) {
					strength *= clamp(texture(TEXTURE(model.AlbedoTexture), uv).g, 0.35, 1.0);
				}

				return clamp(strength, 0.0, 1.0);
			}

			float get_transmission_view_dependency() {
				if (!Subsurface) return 0.0;
				return clamp(transmission_model.TransmissionViewDependency, 0.0, 1.0);
			}

			vec3 get_transmission_color() {
				if (!Subsurface) return vec3(0.0);
				return transmission_model.TransmissionColor.rgb * transmission_model.TransmissionColor.a;
			}

			float get_transmission_blocking(vec2 uv) {
				if (!Subsurface) return 0.0;

				float blocking = transmission_model.TransmissionBlocking;

				if (aux_model.RoughnessTexture != -1) {
					blocking *= texture(TEXTURE(aux_model.RoughnessTexture), uv).a;
					return clamp(blocking, 0.0, 1.0);
				}

				if (aux_model.OpacityTexture != -1) {
					vec4 mask = texture(TEXTURE(aux_model.OpacityTexture), uv);
					blocking *= max(max(mask.r, mask.g), max(mask.b, mask.a));
					return clamp(blocking, 0.0, 1.0);
				}

				blocking *= get_alpha_uv(uv);
				return clamp(blocking, 0.0, 1.0);
			}

			]] .. render3d.GetEmissiveGLSL() .. [[

			vec3 get_emissive(vec2 uv) {
				if (Subsurface) {
					return get_transmission_color();
				}

				vec3 emissive = vec3(0.0);

				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(model.AlbedoTexture), uv).a;
					}
					emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (aux_model.EmissiveTexture != -1) {
					float mask = texture(TEXTURE(aux_model.EmissiveTexture), uv).r;
					emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (aux_model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(aux_model.MetallicTexture), uv).a;
					emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else {
					return vec3(0.0);
				}

				return min(emissive * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
			}

			// half the multiplier, so 1 lands mid range and 2 still fits the unorm target
			float get_specular() {
				return clamp(factor_model.SpecularMultiplier * 0.5, 0.0, 1.0);
			}

			float get_ao(vec2 uv) {
				if (aux_model.AmbientOcclusionTexture == -1) {
					if (terrain_model.TerrainMaterialTexture != -1) {
						return dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerAmbientOcclusion) * get_terrain_layer_sample(uv, in_position).ao * aux_model.AmbientOcclusionMultiplier;
					}

					return 1.0 * aux_model.AmbientOcclusionMultiplier;
				}

				return texture(TEXTURE(aux_model.AmbientOcclusionTexture), uv).r * aux_model.AmbientOcclusionMultiplier;
			}
	]]
end

return model_pipeline
