local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Material = import("goluwa/render3d/material.lua")
local system = import("goluwa/system.lua")
local model_pipeline = library()
local FLOAT_SIZE = ffi.sizeof("float")
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
	{type = "float", name = "Clearcoat", getter = "GetClearcoat"},
	{type = "float", name = "ClearcoatRoughness", getter = "GetClearcoatRoughness"},
}
local PBR_DETAIL_FIELDS = {
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{type = "texture", name = "DetailTexture", getter = "GetDetailTexture"},
	{type = "vec2", name = "DetailTiling", getter = "GetDetailTiling"},
	{type = "float", name = "DetailBumpScale", getter = "GetDetailBumpScale"},
	{type = "float", name = "DetailBlendAmount", getter = "GetDetailBlendAmount"},
	{type = "texture", name = "GroundColorTexture", getter = "GetGroundColorTexture"},
	{type = "float", name = "GroundColorBlend", getter = "GetGroundColorBlend"},
	{type = "vec4", name = "GroundColorUV", getter = "GetGroundColorUV"},
	{
		type = "vec4",
		name = "BaseTextureTransformU",
		getter = "GetBaseTextureTransformU",
	},
	{
		type = "vec4",
		name = "BaseTextureTransformV",
		getter = "GetBaseTextureTransformV",
	},
	{type = "vec4", name = "BumpTransformU", getter = "GetBumpTransformU"},
	{type = "vec4", name = "BumpTransformV", getter = "GetBumpTransformV"},
	{type = "vec4", name = "Texture2TransformU", getter = "GetTexture2TransformU"},
	{type = "vec4", name = "Texture2TransformV", getter = "GetTexture2TransformV"},
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
	{type = "texture", name = "SpecularTexture", getter = "GetSpecularTexture"},
	{
		type = "texture",
		name = "TransmissionTexture",
		getter = "GetTransmissionTexture",
	},
}
local PBR_DISPLACEMENT_FIELDS = {
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightMidlevel", getter = "GetHeightMidlevel"},
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
	{
		type = "vec4",
		name = "TerrainLayerDetailStrength",
		getter = "GetTerrainLayerDetailStrength",
	},
	{
		type = "vec4",
		name = "TerrainLayerAdditiveDetail",
		getter = "GetTerrainLayerAdditiveDetail",
	},
	{
		type = "vec4",
		name = "TerrainLayerSpecular",
		getter = "GetTerrainLayerSpecular",
	},
	{
		type = "texture",
		name = "TerrainLayer1HeightTexture",
		getter = "GetTerrainLayer1HeightTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer2HeightTexture",
		getter = "GetTerrainLayer2HeightTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer3HeightTexture",
		getter = "GetTerrainLayer3HeightTexture",
	},
	{
		type = "texture",
		name = "TerrainLayer4HeightTexture",
		getter = "GetTerrainLayer4HeightTexture",
	},
	{
		type = "vec4",
		name = "TerrainLayerHeightScales",
		getter = "GetTerrainLayerHeightScales",
	},
	{
		type = "float",
		name = "TerrainLayerHeightDistance",
		getter = "GetTerrainLayerHeightDistance",
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
		name = "DiffuseTransmission",
		getter = "GetDiffuseTransmission",
	},
	{
		type = "float",
		name = "TransmissionScattering",
		getter = "GetTransmissionScattering",
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
	{type = "float", name = "HeightMidlevel", getter = "GetHeightMidlevel"},
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

local INSTANCE_WORLD_EXPR = "mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
local INSTANCE_PREV_WORLD_EXPR = "mat4(in_instance_prev_world_row_0, in_instance_prev_world_row_1, in_instance_prev_world_row_2, in_instance_prev_world_row_3)"

local function build_vertex_shader(options, world_expr, prev_world_expr, main_prologue)
	local lines = {}

	if options.enable_vertex_animation ~= false then
		lines[#lines + 1] = model_pipeline.BuildVertexAnimationGlsl(world_expr)
	end

	lines[#lines + 1] = "void main() {"

	if main_prologue then lines[#lines + 1] = main_prologue end

	lines[#lines + 1] = "\tmat4 world = " .. world_expr .. ";"
	lines[#lines + 1] = "\tbool skinned = in_vertex_color.a < " .. skinning.MOTION_THRESHOLD .. ";"
	lines[#lines + 1] = "\tvec3 skin_motion = skinned ? in_vertex_color.rgb : vec3(0.0);"
	lines[#lines + 1] = "\tvec4 vertex_color = skinned ? vec4(0.0) : in_vertex_color;"
	lines[#lines + 1] = [[
	vec3 local_position = in_position;
	vec3 world_position = (world * vec4(local_position, 1.0)).xyz;
	mat3 world_matrix3 = mat3(world);
	mat3 inv_world_matrix3 = inverse(world_matrix3);
	vec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);
	vec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);]]

	if options.velocity then
		lines[#lines + 1] = "\tvec3 prev_world_position = (" .. prev_world_expr .. " * vec4(in_position - skin_motion, 1.0)).xyz;"
	end

	if options.enable_vertex_animation ~= false then
		lines[#lines + 1] = "\tvec3 world_offset = get_vertex_animation_offset(world_position, world_normal, vertex_color);"

		if options.velocity then
			lines[#lines + 1] = "\tprev_world_position += get_previous_vertex_animation_offset(prev_world_position, world_normal, vertex_color);"
		end

		lines[#lines + 1] = [[
	if (dot(world_offset, world_offset) > 0.0) {
		local_position += inv_world_matrix3 * world_offset;
		world_position += world_offset;
	}]]
	end

	if options.camera_block_name then
		lines[#lines + 1] = (
			"\tgl_Position = %s.projection * %s.view * vec4(world_position, 1.0);"
		):format(options.camera_block_name, options.camera_block_name)
	else
		lines[#lines + 1] = "\tgl_Position = vertex.projection_view_world * vec4(local_position, 1.0);"
	end

	lines[#lines + 1] = "\tout_position = world_position;"

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
		lines[#lines + 1] = "\tout_vertex_color = vertex_color;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function get_vertex_stage_outputs(options)
	local outputs = {{"position", "vec3"}}

	if options.normal then outputs[#outputs + 1] = {"normal", "vec3"} end

	if options.tangent then outputs[#outputs + 1] = {"tangent", "vec4"} end

	if options.uv then outputs[#outputs + 1] = {"uv", "vec2"} end

	if options.texture_blend then
		outputs[#outputs + 1] = {"texture_blend", "float"}
	end

	if options.vertex_color then outputs[#outputs + 1] = {"vertex_color", "vec4"} end

	if options.velocity then outputs[#outputs + 1] = {"prev_position", "vec3"} end

	return outputs
end

local function get_vertex_stage_uniform_buffers(options)
	local uniform_buffers = {}

	if options.uniform_buffers then
		table.add(uniform_buffers, options.uniform_buffers)
	end

	if options.enable_vertex_animation ~= false then
		uniform_buffers[#uniform_buffers + 1] = {
			name = "vertex_animation",
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetVertexAnimationUploadKey,
			block = model_pipeline.GetVertexAnimationBlock(),
			write = model_pipeline.WriteVertexAnimationBlock,
		}
	end

	return uniform_buffers[1] and uniform_buffers or nil
end

function model_pipeline.CreateVertexStage(options)
	local camera_block = options.camera_block_name ~= nil
	local get_projection_view_world_matrix = options.get_projection_view_world_matrix or render3d.GetProjectionViewWorldMatrix
	local block = {}

	if not camera_block then
		block[#block + 1] = {"projection_view_world", "mat4"}
	end

	block[#block + 1] = {"world", "mat4"}

	if options.velocity then block[#block + 1] = {"prev_world", "mat4"} end

	local stage = {
		binding_index = 0,
		attributes = model_pipeline.GetVertexAttributes(),
		push_constants = {
			{
				name = "vertex",
				block = block,
				write = function(self, block)
					if not camera_block then
						get_projection_view_world_matrix():CopyToFloatPointer(block.projection_view_world)
					end

					render3d.GetWorldMatrix():CopyToFloatPointer(block.world)

					if options.velocity then
						render3d.GetPreviousWorldMatrix():CopyToFloatPointer(block.prev_world)
					end

					return block
				end,
			},
		},
		uniform_buffers = get_vertex_stage_uniform_buffers(options),
		shader = build_vertex_shader(options, "vertex.world", "vertex.prev_world"),
	}

	if options.velocity then
		local outputs = model_pipeline.GetVertexAttributes()
		outputs[#outputs + 1] = {"prev_position", "vec3"}
		stage.outputs = outputs
	end

	return stage
end

function model_pipeline.CreateInstancedVertexStage(options)
	local bindings = {
		{
			binding = 0,
			input_rate = "vertex",
			attributes = model_pipeline.GetVertexAttributes(),
		},
		{
			binding = 1,
			input_rate = "instance",
			attributes = {{"instance_world", "mat4"}},
		},
	}

	if options.velocity then
		bindings[#bindings + 1] = {
			binding = 2,
			input_rate = "instance",
			attributes = {{"instance_prev_world", "mat4"}},
		}
	end

	return {
		bindings = bindings,
		outputs = get_vertex_stage_outputs(options),
		uniform_buffers = get_vertex_stage_uniform_buffers(options),
		shader = build_vertex_shader(options, INSTANCE_WORLD_EXPR, INSTANCE_PREV_WORLD_EXPR),
	}
end

do
	local FFI_FIELD = {
		float = "float %s;",
		int = "int32_t %s;",
		vec2 = "float %s[2];",
		vec3 = "float %s[3];",
		vec4 = "float %s[4];",
	}
	local record_type
	local record_blocks
	local record_glsl

	local function get_record_blocks()
		if record_blocks then return record_blocks end

		record_blocks = {}

		for _, ubo in ipairs(model_pipeline.GetPBRUniformBuffers()) do
			record_blocks[#record_blocks + 1] = {name = ubo.name, field = "m_" .. ubo.name, block = ubo.block, write = ubo.write}
		end

		record_blocks[#record_blocks + 1] = {
			name = "vertex_animation",
			field = "m_vertex_animation",
			block = model_pipeline.GetVertexAnimationBlock(),
			write = model_pipeline.WriteVertexAnimationBlock,
		}
		return record_blocks
	end

	function model_pipeline.GetPBRBatchRecordType()
		if record_type then return record_type end

		local ffi_fields = {"uint32_t addresses[4];", "uint32_t index_is_32;"}
		local glsl = {}
		local glsl_fields = {"\tuvec4 addresses;", "\tuint index_is_32;"}

		for _, info in ipairs(get_record_blocks()) do
			local c_fields = {}
			local struct_name = "PBRBatch_" .. info.name
			glsl[#glsl + 1] = "struct " .. struct_name .. " {"

			for _, field in ipairs(info.block) do
				c_fields[#c_fields + 1] = FFI_FIELD[field[2]]:format(field[1])
				glsl[#glsl + 1] = "\t" .. field[2] .. " " .. field[1] .. ";"
			end

			glsl[#glsl + 1] = "};"
			ffi_fields[#ffi_fields + 1] = "struct { " .. table.concat(c_fields, " ") .. " } " .. info.field .. ";"
			glsl_fields[#glsl_fields + 1] = "\t" .. struct_name .. " " .. info.field .. ";"
		end

		glsl[#glsl + 1] = "struct PBRBatch {"
		glsl[#glsl + 1] = table.concat(glsl_fields, "\n")
		glsl[#glsl + 1] = "};"
		glsl[#glsl + 1] = "layout(buffer_reference, scalar) readonly buffer PBRBatchData { PBRBatch b[]; };"
		record_type = ffi.typeof("struct { " .. table.concat(ffi_fields, " ") .. " }")
		record_glsl = table.concat(glsl, "\n") .. "\n"
		return record_type
	end

	function model_pipeline.BuildPBRBatchRecordGlsl(batch_expr)
		model_pipeline.GetPBRBatchRecordType()

		if not batch_expr then return record_glsl end

		local defines = {}

		for _, info in ipairs(get_record_blocks()) do
			if info.name ~= "vertex_animation" then
				defines[#defines + 1] = "#define " .. info.name .. " (" .. batch_expr .. ")." .. info.field
			end
		end

		return record_glsl .. table.concat(defines, "\n") .. "\n"
	end

	function model_pipeline.WritePBRBatchRecord(pipeline, record)
		for _, info in ipairs(get_record_blocks()) do
			info.write(pipeline, record[info.field])
		end
	end

	function model_pipeline.CreateMultiDrawVertexStage(options)
		local outputs = get_vertex_stage_outputs(options)
		local batch_location = #outputs
		local fetch = {}
		local offset = 0

		for _, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
			local components = {}

			for i = 0, def.float_count - 1 do
				components[#components + 1] = "data.v[base + " .. (offset + i) .. "u]"
			end

			fetch[#fetch + 1] = string.format(
				"\t%s in_%s = %s(%s);",
				def.type,
				def.name,
				def.type,
				table.concat(components, ", ")
			)
			offset = offset + def.float_count
		end

		local main_prologue = [[
	uint batch_index = uint(gl_DrawID);
	out_batch = batch_index;
	PBRBatchData batch_data = PBRBatchData(]] .. options.batches_expr .. [[);
	uvec4 addresses = batch_data.b[batch_index].addresses;

	if (addresses.x == 0u && addresses.y == 0u) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		return;
	}

	uint vertex_index = uint(gl_VertexIndex);
	PBRBatchVertexData data = PBRBatchVertexData(packUint2x32(addresses.xy));
	uint base = vertex_index * ]] .. offset .. [[u;
]] .. table.concat(fetch, "\n") .. [[

	multi_draw_instance_world = PBRBatchInstanceData(]] .. options.instances_expr .. [[).worlds[gl_InstanceIndex];
	vertex_animation = batch_data.b[batch_index].m_vertex_animation;
	vertex_animation.Time = ]] .. options.time_expr .. [[;
	vertex_animation.PrevTime = ]] .. options.prev_time_expr .. [[;
]]
		return {
			outputs = outputs,
			batch_location = batch_location,
			uniform_buffers = options.uniform_buffers,
			custom_declarations = model_pipeline.BuildPBRBatchRecordGlsl() .. [[
layout(buffer_reference, scalar) readonly buffer PBRBatchVertexData { float v[]; };
layout(buffer_reference, scalar) readonly buffer PBRBatchInstanceData { mat4 worlds[]; };
layout(location = ]] .. batch_location .. [[) flat out uint out_batch;
mat4 multi_draw_instance_world;
PBRBatch_vertex_animation vertex_animation;
]],
			shader = build_vertex_shader(options, "multi_draw_instance_world", "multi_draw_instance_world", main_prologue),
		}
	end
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
		material:GetAlphaCutoff() == 0.5 and
		material:GetClearcoat() == 0.0

	if has_default_scalars then return NO_PBR_FACTOR_KEY end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.GetPBRAuxUploadKey()
	local material = get_material()

	if not material then return NO_PBR_AUX_KEY end

	local uses_metallic_detail = material:GetMetallicRoughnessTexture() ~= nil or
		material:GetMetallicTexture() ~= nil or
		material:GetRoughnessTexture() ~= nil or
		material:GetSpecularTexture() ~= nil or
		material:GetTransmissionTexture() ~= nil
	local uses_ao = material:GetAmbientOcclusionTexture() ~= nil or
		material:GetAmbientOcclusionMultiplier() ~= 1.0
	local uses_emissive = material:GetEmissiveTexture() ~= nil or
		material:GetAlbedoAlphaIsEmissive() or
		material:GetAdditive() or
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
		material:GetDetailTexture() == nil and
		material:GetGroundColorTexture() == nil and
		not material.has_uv_transform
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

	if not material:GetTransmissive() then return NO_PBR_TRANSMISSION_KEY end

	return render3d.GetMaterialUploadKey()
end

do
	local FIELDS = {
		{"Time", "float", "float Time;"},
		{"PrevTime", "float", "float PrevTime;"},
		{"MainBending", "float", "float MainBending;"},
		{"BendHeight", "float", "float BendHeight;"},
		{"BendSpeed", "float", "float BendSpeed;"},
		{"BendDirection", "vec3", "float BendDirection[3];"},
		{"DetailBending", "int", "int DetailBending;"},
		{"DetailFrequency", "float", "float DetailFrequency;"},
		{"DetailLeafAmplitude", "float", "float DetailLeafAmplitude;"},
		{"DetailBranchAmplitude", "float", "float DetailBranchAmplitude;"},
		{"DetailPhase", "float", "float DetailPhase;"},
	}
	local DETAIL_BENDING_MODES = {none = 0, leaves = 1, grass = 2}
	local BEND_RESPONSE = 0.25
	local MAX_BENDING = 2
	local BEND_PER_HEIGHT = 0.25

	function model_pipeline.GetVertexAnimationUniformBufferDecl()
		local fields = {}

		for i, field in ipairs(FIELDS) do
			fields[i] = field[3]
		end

		return ([[
			struct {
				%s
			}
		]]):format(table.concat(fields, "\n\t\t\t\t"))
	end

	function model_pipeline.BuildVertexAnimationUniformDeclaration(binding_index)
		local fields = {}

		for i, field in ipairs(FIELDS) do
			fields[i] = "\t\t\t\t" .. field[2] .. " " .. field[1] .. ";"
		end

		return (
			[[
				layout(scalar, binding = %d) uniform VertexAnimation_t {
			%s
				} vertex_animation;
		]]
		):format(binding_index, table.concat(fields, "\n"))
	end

	function model_pipeline.GetVertexAnimationBlock()
		local block = {}

		for i, field in ipairs(FIELDS) do
			block[i] = {field[1], field[2]}
		end

		return block
	end

	function model_pipeline.FillVertexAnimationData(block, material)
		material = material or get_material()
		local wind = atmosphere.GetWind()
		local wind_x = wind.x * BEND_RESPONSE
		local wind_z = wind.z * BEND_RESPONSE
		local wind_length = math.sqrt(wind_x * wind_x + wind_z * wind_z)
		local bending = wind_length * MAX_BENDING / (MAX_BENDING + wind_length)
		local polygon = render3d.GetCurrentPolygon3D()
		local height = polygon and polygon:GetBendHeight() or 0
		block.Time = system.GetElapsedTime()
		block.PrevTime = render3d.GetPreviousElapsedTime()
		block.MainBending = height > 0 and bending * material:GetBending() * height * BEND_PER_HEIGHT or 0
		block.BendHeight = height
		block.BendSpeed = wind_length
		block.BendDirection[0] = wind_length > 0 and wind_x / wind_length or 1
		block.BendDirection[1] = 0
		block.BendDirection[2] = wind_length > 0 and wind_z / wind_length or 0
		block.DetailBending = DETAIL_BENDING_MODES[material:GetDetailBending()]
		block.DetailFrequency = material:GetBendDetailFrequency()
		block.DetailLeafAmplitude = material:GetBendDetailLeafAmplitude()
		block.DetailBranchAmplitude = material:GetBendDetailBranchAmplitude()
		block.DetailPhase = material:GetBendDetailPhase()
		return block
	end
end

function model_pipeline.WriteVertexAnimationBlock(self, block)
	return model_pipeline.FillVertexAnimationData(block)
end

function model_pipeline.GetVertexAnimationUploadKey()
	local material = get_material()

	if not material then return render3d.GetDefaultMaterial() end

	if material:HasVertexAnimation() then return nil end

	return render3d.GetMaterialUploadKey()
end

function model_pipeline.BuildVertexAnimationGlsl(world_matrix_expr)
	return [[
			bool has_vertex_animation() {
				return vertex_animation.MainBending > 0.0 || (vertex_animation.DetailBending != 0 && vertex_animation.BendSpeed > 0.0);
			}

			vec4 vegetation_triangle_wave(vec4 x) {
				return abs(fract(x + 0.5) * 2.0 - 1.0);
			}

			vec4 vegetation_smooth_triangle_wave(vec4 x) {
				vec4 t = vegetation_triangle_wave(x);
				return t * t * (3.0 - 2.0 * t);
			}

			vec3 get_vertex_animation_offset_at_time(vec3 world_pos, vec3 world_normal, vec4 vertex_color, float anim_time) {
				if (!has_vertex_animation()) return vec3(0.0);

				mat4 world = ]] .. world_matrix_expr .. [[;
				mat3 world_matrix3 = mat3(world);
				mat3 inv_world_matrix3 = inverse(world_matrix3);
				vec3 origin = world[3].xyz;
				// object space is y up, cryengine's is z up, so its xy is our xz
				vec3 start_pos = inv_world_matrix3 * (world_pos - origin);
				vec3 pos = start_pos;
				float speed = vertex_animation.BendSpeed;

				if (vertex_animation.DetailBending != 0) {
					vec4 color = clamp(vertex_color, 0.0, 1.0);
					float edge_atten = color.r;
					float branch_atten = 1.0 - color.b;
					float detail_speed = speed;
					if (vertex_animation.DetailBending == 2) detail_speed *= pos.y;

					float branch_phase = color.g + dot(origin, vec3(2.0));
					float vertex_phase = dot(pos, vec3(vertex_animation.DetailPhase + branch_phase));
					vec2 waves_in = anim_time + vec2(vertex_phase, branch_phase);
					vec4 waves = (fract(waves_in.xxyy * vec4(1.975, 0.793, 0.375, 0.193)) * 2.0 - 1.0) * detail_speed * vertex_animation.DetailFrequency;
					waves = vegetation_triangle_wave(waves);
					vec2 waves_sum = waves.xz + waves.yw;
					vec3 object_normal = normalize(transpose(world_matrix3) * world_normal);
					// leaf edges flutter along the horizontal normal, branches move up and down
					pos.xz += waves_sum.x * edge_atten * vertex_animation.DetailLeafAmplitude * object_normal.xz;
					pos.y += waves_sum.y * branch_atten * vertex_animation.DetailBranchAmplitude;
				}

				if (vertex_animation.MainBending > 0.0) {
					vec3 wind_dir = inv_world_matrix3 * vertex_animation.BendDirection;
					vec2 bend_dir = normalize(wind_dir.xz);
					vec2 bend = bend_dir * vertex_animation.MainBending;

					// gusts, cryengine adds these on its object axes, here along and across the wind
					float wave_in = (anim_time + length(origin) * 2.0) * 2.0;
					vec4 waves = (fract(wave_in * vec4(0.95, 0.45793, 0.913, 0.5793) * 0.1) * 2.0 - 1.0) * 0.7 * speed;
					waves = vegetation_smooth_triangle_wave(waves);
					vec2 waves_sum = waves.xz + waves.yw;
					bend += (bend_dir * (waves_sum.x - 1.0) + vec2(-bend_dir.y, bend_dir.x) * (waves_sum.y - 1.0) * 0.5) * (0.3333 * vertex_animation.MainBending);
					bend *= 0.015;

					float bend_factor = pos.y / vertex_animation.BendHeight + 1.0;
					bend_factor *= bend_factor;
					bend_factor = bend_factor * bend_factor - bend_factor;
					float len = length(pos);

					// bending around the origin keeps the distance to it, trunks curve instead of stretching
					if (len > 0.0) {
						vec3 bent = pos;
						bent.xz += bend * bend_factor;
						pos = normalize(bent) * len;
					}
				}

				return world_matrix3 * (pos - start_pos);
			}

			vec3 get_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color) {
				return get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, vertex_animation.Time);
			}

			vec3 get_previous_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color) {
				return get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, vertex_animation.PrevTime);
			}
	]]
end

function model_pipeline.BuildAlphaDiscardGlsl(alpha_cutoff_expr, coverage_expr, phase_expr)
	local alpha_test = phase_expr and
		[[
					float coverage = clamp((alpha - %s) / max(fwidth(alpha), 0.0001) + 0.5, 0.0, 1.0);
					float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))) + %s);
					if (coverage <= noise) discard;
		]] or
		[[
					if (alpha < %s) discard;
		]]
	return (
		[[
			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
]] .. alpha_test .. [[
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (%s)) discard;
				}
			}
		]]
	):format(
		alpha_cutoff_expr,
		phase_expr or coverage_expr or "alpha * alpha",
		phase_expr and (coverage_expr or "alpha * alpha") or nil
	)
end

function model_pipeline.BuildBindlessAlphaSamplingGlsl(texture_index_expr, color_multiplier_a_expr)
	return (
		[[
			float get_alpha_uv(vec2 uv) {
				if (
					%s == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive ||
					BlendTintByBaseAlpha ||
					!(AlphaTest || Translucent || Additive)
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
		texture_index_expr,
		color_multiplier_a_expr,
		texture_index_expr,
		color_multiplier_a_expr
	)
end

function model_pipeline.BuildSurfaceSamplingGlsl()
	return Material.BuildGlslFlags("model.Flags") .. [[

			vec4 get_surface_color() {
				vec4 color = model.ColorMultiplier;

				if (model.AlbedoTexture != -1) {
					vec4 texel = texture(TEXTURE(model.AlbedoTexture), in_uv);

					if (BlendTintByBaseAlpha) {
						color = vec4(mix(vec3(1.0), color.rgb, texel.a) * texel.rgb, color.a);
					} else {
						color *= texel;
					}
				}

				return color;
			}

			void discard_surface_alpha(vec4 color) {
				if (AlphaTest && color.a < model.AlphaCutoff) discard;
			}

			vec3 get_surface_emissive(vec3 albedo) {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;

					if (model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(model.AlbedoTexture), in_uv).a;
					}

					return albedo * mask * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}

				if (model.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(model.EmissiveTexture), in_uv).rgb;
					return emissive * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
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

function model_pipeline.BuildPBRSurfaceGlsl(camera_block_name)
	return Material.BuildGlslFlags("model.Flags") .. [=[
			vec3 get_surface_camera_position() {
				return ]=] .. camera_block_name .. [=[.camera_position;
			}

			bool has_heightmap() {
				return displacement_model.HeightTexture != -1 && displacement_model.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(displacement_model.HeightTexture), uv).r;
			}

			int get_height_layers() {
				return clamp(displacement_model.HeightLayers, 4, 64);
			}

			vec2 base_uv(vec2 uv) {
				return vec2(dot(detail_model.BaseTextureTransformU.xy, uv) + detail_model.BaseTextureTransformU.z, dot(detail_model.BaseTextureTransformV.xy, uv) + detail_model.BaseTextureTransformV.z);
			}

			vec2 bump_uv(vec2 uv) {
				return vec2(dot(detail_model.BumpTransformU.xy, uv) + detail_model.BumpTransformU.z, dot(detail_model.BumpTransformV.xy, uv) + detail_model.BumpTransformV.z);
			}

			vec2 texture2_uv(vec2 uv) {
				return vec2(dot(detail_model.Texture2TransformU.xy, uv) + detail_model.Texture2TransformU.z, dot(detail_model.Texture2TransformV.xy, uv) + detail_model.Texture2TransformV.z);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (detail_model.BlendTexture == -1) {
					return in_texture_blend;
				}

				// source blendmodulate: g is the transition center, r its half width
				vec2 modulate = texture(TEXTURE(detail_model.BlendTexture), uv).rg;
				return smoothstep(clamp(modulate.g - modulate.r, 0.0, 1.0), clamp(modulate.g + modulate.r, 0.0, 1.0), in_texture_blend);
			}

			float get_texture_blend() {
				return get_texture_blend_uv(in_uv);
			}

			vec3 get_terrain_world_normal(vec2 uv) {
				if (model.NormalTexture == -1) {
					return vec3(0.0, 1.0, 0.0);
				}

				vec2 n = texture(TEXTURE(model.NormalTexture), uv).xy * 2.0 - 1.0;
				return normalize(vec3(n.x, sqrt(max(1.0 - dot(n, n), 0.0)), n.y));
			}

			vec3 get_terrain_triplanar_weights(vec3 normal) {
				vec3 w = pow(abs(normal), vec3(4.0));
				return w / max(w.x + w.y + w.z, 0.0001);
			}

			// a layer's texture coordinates in each of the three projections
			struct TerrainLayerUV {
				vec2 x;
				vec2 y;
				vec2 z;
			};

			vec4 sample_terrain_layer_triplanar(int tex, TerrainLayerUV uv, vec3 blend) {
				vec4 result = vec4(0.0);

				if (blend.y > 0.001) {
					result += texture(TEXTURE(tex), uv.y) * blend.y;
				}

				if (blend.x > 0.001) {
					result += texture(TEXTURE(tex), uv.x) * blend.x;
				}

				if (blend.z > 0.001) {
					result += texture(TEXTURE(tex), uv.z) * blend.z;
				}

				return result;
			}

			vec4 sample_terrain_layer_normal_triplanar(int tex, TerrainLayerUV uv, vec3 blend, vec3 N) {
				vec3 n = vec3(0.0);
				float ao = 0.0;

				if (blend.y > 0.001) {
					vec4 t = texture(TEXTURE(tex), uv.y);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xz, abs(tn.z) * N.y);
					n += tn.xzy * blend.y;
					ao += t.a * blend.y;
				}

				if (blend.x > 0.001) {
					vec4 t = texture(TEXTURE(tex), uv.x);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.zy, abs(tn.z) * N.x);
					n += tn.zyx * blend.x;
					ao += t.a * blend.x;
				}

				if (blend.z > 0.001) {
					vec4 t = texture(TEXTURE(tex), uv.z);
					vec3 tn = t.xyz * 2.0 - 1.0;
					tn = vec3(tn.xy + N.xy, abs(tn.z) * N.z);
					n += tn.xyz * blend.z;
					ao += t.a * blend.z;
				}

				return vec4(n, ao);
			}

			// crysis' terrain parallax occlusion mapping: march the height from 1 down to 0 along the
			// view ray, which moves the texture coordinates by up to displacement at the bottom.
			// view_uv is the direction to the camera along the projection's axes, view_n along its normal
			vec2 terrain_layer_parallax(int height_tex, vec2 uv, vec2 view_uv, float view_n, float displacement) {
				const int STEPS = 15;
				vec2 uv_dx = dFdx(uv);
				vec2 uv_dy = dFdy(uv);
				vec2 delta = -view_uv / max(view_n, 0.05) * displacement / float(STEPS);
				float layer = 1.0;
				float height = textureGrad(TEXTURE(height_tex), uv, uv_dx, uv_dy).r;
				vec2 prev_uv = uv;
				float prev_above = layer - height;

				for (int i = 0; i < STEPS && height < layer; i++) {
					prev_uv = uv;
					prev_above = layer - height;
					uv += delta;
					layer -= 1.0 / float(STEPS);
					height = textureGrad(TEXTURE(height_tex), uv, uv_dx, uv_dy).r;
				}

				float below = height - layer;
				return mix(prev_uv, uv, prev_above / max(prev_above + below, 0.0001));
			}

			TerrainLayerUV get_terrain_layer_uv(int height_tex, vec3 world_pos, float scale, vec3 blend, vec3 N, vec3 V, float displacement) {
				float safe_scale = max(scale, 0.0001);
				vec2 uv[3] = vec2[3](world_pos.zy / safe_scale, world_pos.xz / safe_scale, world_pos.xy / safe_scale);

				if (height_tex != -1 && displacement > 0.0) {
					vec2 view_uv[3] = vec2[3](V.zy, V.xz, V.xy);
					vec3 view_n = V * sign(N);

					// one call site, the driver takes seconds per pipeline when each projection inlines its own march
					for (int i = 0; i < 3; i++) {
						if (blend[i] > 0.001) {
							uv[i] = terrain_layer_parallax(height_tex, uv[i], view_uv[i], view_n[i], displacement);
						}
					}
				}

				return TerrainLayerUV(uv[0], uv[1], uv[2]);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (terrain_model.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(terrain_model.TerrainMaterialTexture), uv);
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

			void accumulate_terrain_layer(inout TerrainLayerSample s, vec3 base, int albedo_tex, int normal_tex, int height_tex, vec3 world_pos, vec3 blend, vec3 N, vec3 V, float weight, float scale, float detail_strength, float additive_detail, float displacement) {
				if (weight <= 0.001) {
					return;
				}

				// like crysis, a layer displaces as much as it covers
				TerrainLayerUV uv = get_terrain_layer_uv(height_tex, world_pos, scale, blend, N, V, displacement * weight);

				if (albedo_tex != -1) {
					vec4 albedo = sample_terrain_layer_triplanar(albedo_tex, uv, blend);

					if (detail_strength > 0.0) {
						if (additive_detail > 0.0) {
							// the detail is an offset around 0.5 in gamma space, adding it to the linear color
							// clips each channel at a different point and leaves saturated specks in dark spots
							vec3 base_gamma = pow(base, vec3(1.0 / 2.2));
							albedo.rgb = pow(max(base_gamma + (albedo.rgb - 0.5) * detail_strength, vec3(0.0)), vec3(2.2)) * additive_detail;
						} else {
							// the smallest mip is the average color of the layer
							vec3 average = textureLod(TEXTURE(albedo_tex), vec2(0.5), 16.0).rgb;
							albedo.rgb = base * mix(vec3(1.0), albedo.rgb / max(average, vec3(0.01)), detail_strength);
						}
						// a detail layer's alpha is not roughness, TerrainLayerRoughness alone decides it
						albedo.a = 1.0;
					} else {
						albedo.rgb *= base;
					}

					s.albedo += albedo.rgb * weight;
					s.roughness += albedo.a * weight;
				} else {
					s.albedo += base * weight;
					s.roughness += weight;
				}

				if (normal_tex != -1) {
					vec4 n = sample_terrain_layer_normal_triplanar(normal_tex, uv, blend, N);
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
				vec4 scales = terrain_model.TerrainLayerScales;
				vec4 detail = terrain_model.TerrainLayerDetailStrength;
				vec4 additive_detail = terrain_model.TerrainLayerAdditiveDetail;
				vec3 base = model.AlbedoTexture != -1 ? texture(TEXTURE(model.AlbedoTexture), uv).rgb : vec3(1.0);
				vec3 to_camera = get_surface_camera_position() - world_pos;
				vec3 V = normalize(to_camera);
				// crysis fades the displacement out towards the detail layers' view distance
				float fade = 1.0 - pow(min(length(to_camera) / max(terrain_model.TerrainLayerHeightDistance, 0.001), 1.0), 4.0);
				vec4 displacement = terrain_model.TerrainLayerHeightScales * fade;
				ivec4 albedo_textures = ivec4(terrain_model.TerrainLayer1Texture, terrain_model.TerrainLayer2Texture, terrain_model.TerrainLayer3Texture, terrain_model.TerrainLayer4Texture);
				ivec4 normal_textures = ivec4(terrain_model.TerrainLayer1NormalTexture, terrain_model.TerrainLayer2NormalTexture, terrain_model.TerrainLayer3NormalTexture, terrain_model.TerrainLayer4NormalTexture);
				ivec4 height_textures = ivec4(terrain_model.TerrainLayer1HeightTexture, terrain_model.TerrainLayer2HeightTexture, terrain_model.TerrainLayer3HeightTexture, terrain_model.TerrainLayer4HeightTexture);

				// a loop rather than four calls so the layer code is compiled once
				for (int i = 0; i < 4; i++) {
					accumulate_terrain_layer(s, base, albedo_textures[i], normal_textures[i], height_textures[i], world_pos, blend, N, V, weights[i], scales[i], detail[i], additive_detail[i], displacement[i]);
				}

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
					return color_model.ColorMultiplier.rgb;
				}

				return get_terrain_layer_sample(uv, world_pos).albedo * color_model.ColorMultiplier.rgb;
			}

			vec3 blend_ground_color(vec3 albedo, vec3 world_pos) {
				if (detail_model.GroundColorTexture == -1) return albedo;

				vec4 m = detail_model.GroundColorUV;
				vec2 ground_uv = vec2(dot(world_pos.xz, m.xy), dot(world_pos.xz, m.zw));
				vec3 ground = texture(TEXTURE(detail_model.GroundColorTexture), ground_uv).rgb;
				return mix(albedo, ground, detail_model.GroundColorBlend);
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (terrain_model.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (model.AlbedoTexture == -1) {
					return blend_ground_color(color_model.ColorMultiplier.rgb, world_pos);
				}

				vec4 albedo_texel = texture(TEXTURE(model.AlbedoTexture), base_uv(uv));
				vec3 rgb1 = albedo_texel.rgb;
				vec3 tint = color_model.ColorMultiplier.rgb;

				if (BlendTintByBaseAlpha) {
					tint = mix(vec3(1.0), tint, albedo_texel.a);
				}

				if (MultiplyAlbedo2 && detail_model.Albedo2Texture != -1) {
					rgb1 *= texture(TEXTURE(detail_model.Albedo2Texture), texture2_uv(uv)).rgb;
				} else if (detail_model.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(detail_model.Albedo2Texture), texture2_uv(uv)).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				if (detail_model.DetailTexture != -1) {
					vec2 detail_uv = uv * detail_model.DetailTiling;
					float detail = texture(TEXTURE(detail_model.DetailTexture), detail_uv).a + texture(TEXTURE(detail_model.DetailTexture), detail_uv * 2.0).a;
					rgb1 = mix(rgb1, rgb1 * detail, detail_model.DetailBlendAmount);
				}

				return blend_ground_color(rgb1 * tint, world_pos);
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}

			float get_alpha_uv(vec2 uv) {
				if (NormalAlphaIsCoverage && model.NormalTexture != -1) {
					return texture(TEXTURE(model.NormalTexture), bump_uv(uv)).a * color_model.ColorMultiplier.a;
				}

				if (
					model.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive ||
					BlendTintByBaseAlpha ||
					!(AlphaTest || Translucent || Additive)
				) {
					return color_model.ColorMultiplier.a;
				}

				if (Additive) {
					vec3 albedo = get_albedo_uv(uv);
					return max(albedo.r, max(albedo.g, albedo.b)) * color_model.ColorMultiplier.a;
				}

				return texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a * color_model.ColorMultiplier.a;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
	]=] .. model_pipeline.BuildAlphaDiscardGlsl("factor_model.AlphaCutoff", nil, camera_block_name .. ".noise_phase") .. [[
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

				// the back of a thin surface is the front mirrored through it, so a bump on
				// one side is a dent on the other and the whole frame flips
				if (DoubleSided && gl_FrontFacing) {
					tangent = -tangent;
					bitangent = -bitangent;
					normal = -normal;
				}

				return mat3(tangent, bitangent, normal);
			}

			vec3 get_height_normal_tangent(vec2 uv) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(displacement_model.HeightTexture), 0));
				float left = get_height_sample(uv - vec2(texel.x, 0.0));
				float right = get_height_sample(uv + vec2(texel.x, 0.0));
				float down = get_height_sample(uv - vec2(0.0, texel.y));
				float up = get_height_sample(uv + vec2(0.0, texel.y));
				// the slope in texture units, the height being HeightScale texture units deep
				return normalize(vec3((left - right) / (2.0 * texel.x), (down - up) / (2.0 * texel.y), 1.0 / displacement_model.HeightScale));
			}

			vec3 decode_normal_map(vec2 xy) {
				xy = xy * 2.0 - 1.0;

				return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
			}

			// source's bump basis, the directions an ssbump texel holds the light of
			vec3 decode_normal_texture(vec4 texel) {
				if (!NormalTextureIsSSBump) {
					return decode_normal_map(texel.xy);
				}

				vec3 w = sqrt(texel.rgb);
				vec3 n = normalize(
					w.r * vec3(0.81649661, 0.0, 0.57735026) +
					w.g * vec3(-0.40824821, 0.70710677, 0.57735026) +
					w.b * vec3(-0.40824821, -0.70710677, 0.57735026)
				);

				return n;
			}

			vec3 get_normal_map(vec2 uv) {
				vec3 N = vec3(0.0, 0.0, 1.0);

				if (model.NormalTexture != -1) {
					N = decode_normal_texture(texture(TEXTURE(model.NormalTexture), bump_uv(uv)));
				} else if (has_heightmap()) {
					N = get_height_normal_tangent(uv);
				}

				if (detail_model.Normal2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						N = normalize(mix(N, decode_normal_texture(texture(TEXTURE(detail_model.Normal2Texture), uv)), blend));
					}
				}

				N = normalize(vec3(N.xy * ]] .. camera_block_name .. [[.normal_map_strength, N.z));

				// crysis detail bump: two octaves centered on 0.5 offset the normal's slope
				if (detail_model.DetailTexture != -1) {
					vec2 detail_uv = uv * detail_model.DetailTiling;
					vec2 detail = texture(TEXTURE(detail_model.DetailTexture), detail_uv).xy + texture(TEXTURE(detail_model.DetailTexture), detail_uv * 2.0).xy;
					detail = (detail - 1.0) * detail_model.DetailBumpScale;
					N.xy += detail;
				}

				return normalize(N);
			}

			vec3 get_combined_normal(vec2 uv, mat3 tbn) {
				return normalize(tbn * get_normal_map(uv));
			}

			vec3 get_normal(vec2 uv, mat3 tbn) {
				vec3 N = get_combined_normal(uv, tbn);

				if (terrain_model.TerrainMaterialTexture != -1) {
					return get_terrain_layer_sample(uv, in_position).normal;
				}

				return N;
			}

			// the blended bump's alpha, source masks specular with the alpha of whichever bump is showing
			float get_normal_alpha(vec2 uv) {
				float alpha = texture(TEXTURE(model.NormalTexture), bump_uv(uv)).a;

				if (detail_model.Normal2Texture != -1) {
					alpha = mix(alpha, texture(TEXTURE(detail_model.Normal2Texture), uv).a, get_texture_blend_uv(uv));
				}

				return alpha;
			}

			// the gloss map's luminance, 1 without one
			float get_gloss(vec2 uv) {
				if (AlbedoAlphaIsSpecular && model.AlbedoTexture != -1) {
					return texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
				} else if (aux_model.SpecularTexture != -1) {
					return dot(texture(TEXTURE(aux_model.SpecularTexture), uv).rgb, vec3(0.2126, 0.7152, 0.0722));
				} else if (SpecularFromRoughnessMask) {
					// a source envmap or phong mask, 1 is shiny unless it is inverted
					float mask = 1.0;

					if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
						mask = texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
					} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
						mask = get_normal_alpha(uv);
					} else if (AlbedoLuminanceIsRoughness) {
						mask = dot(get_albedo_uv(uv), vec3(0.2126, 0.7152, 0.0722));
					} else if (aux_model.RoughnessTexture != -1) {
						mask = texture(TEXTURE(aux_model.RoughnessTexture), uv).r;
					}

					return InvertRoughnessTexture ? mask : 1.0 - mask;
				}

				return 1.0;
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

				if (RoughnessMaskOnlyScalesSpecular) return clamp(factor_model.RoughnessMultiplier * factor_model.RoughnessMultiplier, 0.002, 1.0);

				if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					val = texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
				} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					val = get_normal_alpha(uv);
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

					// the gloss map scales a phong power n whose roughness is (2 / (n + 2))^0.25
					if (GlossIsShininess) {
						float r4 = val * val * val * val;
						val = sqrt(sqrt(r4 / max(get_gloss(uv) * (1.0 - r4) + r4, 0.000001)));
					}

					return clamp(val * val, 0.002, 1.0);
				}

				val *= factor_model.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				// perceptual roughness in, GGX alpha out
				val *= val;
				val = clamp(val, 0.002, 1.0);
				return val;
			}

			// specular antialiasing (Tokuyoshi & Kaplanyan 2019, "Improved
			// Geometric Specular Antialiasing"). a normal that turns across the
			// pixel, on a small sphere, a thin pipe or a fine normal map, spreads
			// the pixel's reflection like roughness does. sampling one normal per
			// pixel instead catches or misses the highlight, which flickers as
			// things move. the turn is taken as a gaussian over the pixel filter
			// and its variance added to the ggx alpha squared, capped so a crease
			// or a tight curve doesn't go fully rough. a mirror is left alone: its
			// bevels and bumps are resolved detail, and roughening them hands those
			// pixels to the environment while the flat parts keep the traced
			// reflection, which draws their outline. ggx alpha in and out
			float get_antialiased_roughness(vec3 N, float alpha) {
				vec3 dx = dFdx(N);
				vec3 dy = dFdy(N);
				// the pixel filter's variance, 1 / (2 pi)
				float kernel = 2.0 * 0.15915494 * (dot(dx, dx) + dot(dy, dy)) * smoothstep(0.0, 0.05, alpha);
				return sqrt(clamp(alpha * alpha + min(kernel, 0.18), 0.0, 1.0));
			}

			float get_transmission(vec2 uv) {
				if (!Transmissive) return 0.0;

				float amount = transmission_model.DiffuseTransmission;

				if (aux_model.TransmissionTexture != -1) {
					amount *= dot(texture(TEXTURE(aux_model.TransmissionTexture), uv).rgb, vec3(0.2126, 0.7152, 0.0722));
				}

				return clamp(amount, 0.0, 1.0);
			}

			float get_transmission_scattering() {
				if (!Transmissive) return 0.0;
				return clamp(transmission_model.TransmissionScattering, 0.0, 1.0);
			}

			// only the hue, the brightness comes from DiffuseTransmission
			vec3 get_transmission_color() {
				if (!Transmissive) return vec3(1.0);
				vec3 tint = transmission_model.TransmissionColor.rgb;
				return tint / max(dot(tint, vec3(0.2126, 0.7152, 0.0722)), 0.001);
			}

			]] .. render3d.GetEmissiveGLSL() .. [[

			vec3 get_emissive(vec2 uv) {
				vec3 emissive = vec3(0.0);

				if (Additive) {
					emissive = get_albedo_uv(uv) * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
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

			float get_clearcoat() {
				return factor_model.Clearcoat;
			}

			// ggx alpha
			float get_clearcoat_roughness() {
				return factor_model.ClearcoatRoughness * factor_model.ClearcoatRoughness;
			}

			// the SpecularMultiplier; 1 is dielectric F0 0.04
			float get_specular(vec2 uv) {
				float val = factor_model.SpecularMultiplier * get_gloss(uv);

				// apply_gloss_metallic takes over above a dielectric
				if (SpecularSolvesMetallic) return min(val, 1.0);

				if (terrain_model.TerrainMaterialTexture != -1) {
					val *= dot(get_terrain_material_weights_uv(uv), terrain_model.TerrainLayerSpecular);
				}

				// as much as the gbuffer holds
				return clamp(val, 0.0, 2.0);
			}

			// specular/glossiness to metal/roughness, an F0 above a dielectric's 0.04 with a diffuse of albedo
			// is metallic that keeps both the diffuse and the specular energy. albedo becomes the base color
			void apply_gloss_metallic(vec2 uv, inout vec3 albedo, inout float metallic) {
				if (!SpecularSolvesMetallic) return;

				float f0 = factor_model.SpecularMultiplier * get_gloss(uv) * 0.04;

				if (f0 <= 0.04) return;

				float b = dot(albedo, vec3(0.2126, 0.7152, 0.0722)) * (1.0 - f0) / 0.96 + f0 - 0.08;
				metallic = clamp((-b + sqrt(b * b + 0.16 * (f0 - 0.04))) / 0.08, 0.0, 1.0);
				vec3 dielectric = albedo * (1.0 - f0) / (0.96 * max(1.0 - metallic, 0.0001));
				vec3 metal = vec3((f0 - 0.04 * (1.0 - metallic)) / max(metallic, 0.0001));
				albedo = clamp(mix(dielectric, metal, metallic * metallic), 0.0, 1.0);
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
