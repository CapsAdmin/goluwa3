local glsl_common = import("goluwa/render3d/glsl_common.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local Material = import("goluwa/render3d/material.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local terrain_layer_rules = import("goluwa/render3d/terrain_layer_rules.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local model_pipeline = {}
local SURFACE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "NormalMapMultiplier", getter = "GetNormalMapMultiplier"},
	{type = "vec4", name = "RimColor", getter = "GetRimColor"},
	{type = "float", name = "RimPower", getter = "GetRimPower"},
	{type = "float", name = "OcclusionRadius", getter = "GetOcclusionRadius"},
	{type = "float", name = "OcclusionSoftness", getter = "GetOcclusionSoftness"},
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
	{type = "float", name = "RoughnessMin", getter = "GetRoughnessMin"},
	{type = "float", name = "RoughnessMax", getter = "GetRoughnessMax"},
	{type = "float", name = "MetallicMaskMin", getter = "GetMetallicMaskMin"},
	{type = "float", name = "MetallicMaskMax", getter = "GetMetallicMaskMax"},
	{type = "float", name = "EmissiveAlphaFloor", getter = "GetEmissiveAlphaFloor"},
	{type = "float", name = "SpecularMultiplier", getter = "GetSpecularMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
	{type = "float", name = "NormalMapMultiplier", getter = "GetNormalMapMultiplier"},
}
local FEATURE_BLOCK_FIELDS = {}

for _, feature in ipairs(surface_features.list) do
	for _, param in ipairs(feature.params or {}) do
		local field = {type = param.kind or "float", name = param.name, getter = "Get" .. param.name}

		if feature.block == "none" or param.block == false then

		elseif feature.block == "own" then
			FEATURE_BLOCK_FIELDS[feature] = FEATURE_BLOCK_FIELDS[feature] or {}
			table.insert(FEATURE_BLOCK_FIELDS[feature], field)
		else
			assert(
				field.type == "float",
				"only a feature with a block of its own can have a " .. field.type .. " param"
			)
			table.insert(PBR_FACTOR_FIELDS, field)
		end
	end
end

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

function model_pipeline.GetVertexAttributes()
	return vertex_layout.GetShaderAttributes()
end

function model_pipeline.GetVertexStride()
	return vertex_layout.Stride
end

function model_pipeline.GetVertexBufferBinding(binding_index)
	return {
		binding = binding_index or 0,
		stride = vertex_layout.Stride,
		input_rate = "vertex",
	}
end

function model_pipeline.GetVertexAttributeLayout(binding_index)
	return vertex_layout.GetAttributes(binding_index)
end

local INSTANCE_WORLD_EXPR = "mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
local INSTANCE_PREV_WORLD_EXPR = "mat4(in_instance_prev_world_row_0, in_instance_prev_world_row_1, in_instance_prev_world_row_2, in_instance_prev_world_row_3)"

local function build_vertex_shader(options, world_expr, prev_world_expr, main_prologue)
	local lines = {}

	if options.enable_vertex_animation ~= false then
		local camera = options.camera_block_name
		lines[#lines + 1] = model_pipeline.BuildVertexAnimationGlsl(
			world_expr,
			camera and camera .. ".camera_position",
			camera and
				string.format("(abs(%s.projection[1][1]) * %s.render_size.y * 0.5)", camera, camera)
		)
	end

	lines[#lines + 1] = "void main() {"

	if main_prologue then lines[#lines + 1] = main_prologue end

	lines[#lines + 1] = "\tmat4 world = " .. world_expr .. ";"

	if options.lod_fade then
		lines[#lines + 1] = "\tout_lod_fade = world[0][3];"
	end

	if options.instance_tint then
		lines[#lines + 1] = "\tout_instance_tint = " .. (options.instance_tint_expr or "vec3(1.0)") .. ";"
	end

	if options.instance_effects then
		lines[#lines + 1] = "\tout_instance_effects_a = " .. (
				options.instance_effects_a_expr or
				"vec3(0.0)"
			) .. ";"
		lines[#lines + 1] = "\tout_instance_effects_b = " .. (
				options.instance_effects_b_expr or
				"vec3(0.0)"
			) .. ";"
	end

	if options.instance_thickness_expr then
		lines[#lines + 1] = "\tout_instance_thickness = " .. options.instance_thickness_expr .. ";"
	end

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

	if options.instance_effects then
		lines[#lines + 1] = "\tbool object_effects = any(greaterThan(out_instance_effects_a + out_instance_effects_b, vec3(0.0)));"
		lines[#lines + 1] = "\tout_effect_position = object_effects ? local_position : world_position;"
		lines[#lines + 1] = "\tout_effect_normal = object_effects ? in_normal : world_normal;"
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

	if options.lod_fade then outputs[#outputs + 1] = {"lod_fade", "float"} end

	if options.instance_tint then
		outputs[#outputs + 1] = {"instance_tint", "vec3"}
	end

	if options.instance_effects then
		outputs[#outputs + 1] = {"instance_effects_a", "vec3"}
		outputs[#outputs + 1] = {"instance_effects_b", "vec3"}
		outputs[#outputs + 1] = {"effect_position", "vec3"}
		outputs[#outputs + 1] = {"effect_normal", "vec3"}
	end

	if options.instance_thickness_expr then
		outputs[#outputs + 1] = {"instance_thickness", "float"}
	end

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
			memo_key = model_pipeline.GetMaterialMemoKey,
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

	if
		options.velocity or
		options.lod_fade or
		options.instance_tint or
		options.instance_effects
	then
		local outputs = model_pipeline.GetVertexAttributes()

		if options.velocity then
			outputs[#outputs + 1] = {"prev_position", "vec3"}
		end

		if options.lod_fade then outputs[#outputs + 1] = {"lod_fade", "float"} end

		if options.instance_tint then
			outputs[#outputs + 1] = {"instance_tint", "vec3"}
		end

		if options.instance_effects then
			outputs[#outputs + 1] = {"instance_effects_a", "vec3"}
			outputs[#outputs + 1] = {"instance_effects_b", "vec3"}
			outputs[#outputs + 1] = {"effect_position", "vec3"}
			outputs[#outputs + 1] = {"effect_normal", "vec3"}
		end

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
			name = "refraction_record",
			field = "m_refraction_record",
			block = {
				{"amount", "float"},
				{"ior", "float"},
				{"abbe", "float"},
				{"attenuation", "float"},
			},
			write = function(self, block)
				local material = get_material()
				block.amount = material:GetRefraction()
				block.ior = math.max(material:GetIndexOfRefraction(), 1)
				block.abbe = material:GetAbbeNumber()
				block.attenuation = material:GetAttenuationDistance()
			end,
		}
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

	local write_record

	function model_pipeline.WritePBRBatchRecord(pipeline, record)
		if not write_record then
			local blocks = get_record_blocks()
			local lines = {"local blocks = ...", "return function(pipeline, record)"}

			for i, info in ipairs(blocks) do
				lines[#lines + 1] = string.format("\tblocks[%d].write(pipeline, record.%s)", i, info.field)
			end

			lines[#lines + 1] = "end"
			write_record = assert(loadstring(table.concat(lines, "\n"), "pbr_batch_record_writer"))(blocks)
		end

		return write_record(pipeline, record)
	end

	function model_pipeline.WritePBRBatchAnimationRecord(pipeline, record)
		model_pipeline.WriteVertexAnimationBlock(pipeline, record.m_vertex_animation)
	end

	function model_pipeline.CreateMultiDrawVertexStage(options)
		local outputs = get_vertex_stage_outputs(options)
		local batch_location = #outputs
		local fetch = {}

		for _, field in ipairs(vertex_layout.Fields) do
			local components = {}

			for i = 0, field.count - 1 do
				components[#components + 1] = "data.v[base + " .. (field.float_offset + i) .. "u]"
			end

			fetch[#fetch + 1] = string.format(
				"\t%s in_%s = %s(%s);",
				field.glsl,
				field.name,
				field.glsl,
				table.concat(components, ", ")
			)
		end

		local main_prologue = [[
	uint batch_index = ]] .. (
				options.batch_index_expr or
				"uint(gl_DrawID)"
			) .. [[;
	out_batch = batch_index;
	PBRBatchData batch_data = PBRBatchData(]] .. options.batches_expr .. [[);
	uvec4 addresses = batch_data.b[batch_index].addresses;

	if (addresses.x == 0u && addresses.y == 0u) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		return;
	}

	uint vertex_index = uint(gl_VertexIndex);
	PBRBatchVertexData data = PBRBatchVertexData(packUint2x32(addresses.xy));
	uint base = vertex_index * ]] .. vertex_layout.FloatStride .. [[u;
]] .. table.concat(fetch, "\n") .. [[

	multi_draw_instance_world = PBRBatchInstanceData(]] .. options.instances_expr .. [[).worlds[gl_InstanceIndex];
	multi_draw_instance_prev_world = PBRBatchInstanceData(]] .. options.prev_instances_expr .. [[).worlds[gl_InstanceIndex];
	vertex_animation = batch_data.b[batch_index].m_vertex_animation;
	vertex_animation.Time = ]] .. options.time_expr .. [[;
	vertex_animation.PrevTime = ]] .. options.prev_time_expr .. [[;
	vertex_animation.DetailTime = ]] .. options.detail_time_expr .. [[;
	vertex_animation.PrevDetailTime = ]] .. options.prev_detail_time_expr .. [[;
]]
		options.instance_tint_expr = "multi_draw_instance_tint(world[1][3])"
		options.instance_effects_a_expr = "multi_draw_instance_effects(world[2][3])"
		options.instance_effects_b_expr = "multi_draw_instance_effects(multi_draw_instance_prev_world[2][3])"
		return {
			outputs = outputs,
			batch_location = batch_location,
			uniform_buffers = options.uniform_buffers,
			custom_declarations = model_pipeline.BuildPBRBatchRecordGlsl() .. [[
layout(buffer_reference, scalar) readonly buffer PBRBatchVertexData { float v[]; };
layout(buffer_reference, scalar) readonly buffer PBRBatchInstanceData { mat4 worlds[]; };
layout(buffer_reference, scalar) readonly buffer PBRBatchIdData { uvec2 ids[]; };
layout(buffer_reference, scalar) readonly buffer PBRBatchThicknessData { float t[]; };
layout(location = ]] .. batch_location .. [[) flat out uint out_batch;
mat4 multi_draw_instance_world;
mat4 multi_draw_instance_prev_world;
PBRBatch_vertex_animation vertex_animation;

vec3 multi_draw_instance_tint(float packed) {
	uint bits = floatBitsToUint(packed);
	return bits == 0u ? vec3(1.0) : unpackUnorm4x8(bits).rgb * 2.0;
}

vec3 multi_draw_instance_effects(float packed) {
	uint bits = floatBitsToUint(packed);

	if ((bits & 0xFF800000u) != 0x3F800000u) return vec3(0.0);

	return vec3(uvec3(bits, bits >> 7u, bits >> 14u) & 127u) / 127.0;
}
]],
			shader = build_vertex_shader(
				options,
				"multi_draw_instance_world",
				"multi_draw_instance_prev_world",
				main_prologue
			),
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
		local info = Material.objects_variables[def.name]
		local value = info and
			def.getter == info.get_name and
			Material[def.getter] == info.default_getter and
			"material." .. def.name or
			"material:" .. def.getter .. "()"

		if def.type == "texture" then
			lines[#lines + 1] = string.format("\tblock.%s = self:GetTextureIndex(%s)", def.name, value)
		elseif def.type == "vec2" or def.type == "vec3" or def.type == "vec4" then
			lines[#lines + 1] = string.format("\t%s:CopyToFloatPointer(block.%s)", value, def.name)
		else
			lines[#lines + 1] = string.format("\tblock.%s = %s", def.name, value)
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
local PBR_AUX_BLOCK = build_material_block(PBR_AUX_FIELDS)
local WRITE_SURFACE_MATERIAL_BLOCK = build_material_block_writer("surface", SURFACE_MATERIAL_FIELDS)
local WRITE_PBR_MATERIAL_BLOCK = build_material_block_writer("pbr", PBR_MATERIAL_FIELDS)
local WRITE_PBR_COLOR_BLOCK = build_material_block_writer("pbr_color", PBR_COLOR_FIELDS)
local WRITE_PBR_FACTOR_BLOCK = build_material_block_writer("pbr_factor", PBR_FACTOR_FIELDS)
local WRITE_PBR_AUX_BLOCK = build_material_block_writer("pbr_aux", PBR_AUX_FIELDS)
local WRITE_PROBE_MATERIAL_BLOCK = build_material_block_writer("probe", PROBE_MATERIAL_FIELDS)
local NO_PBR_COLOR_KEY = {}
local NO_PBR_FACTOR_KEY = {}
local NO_PBR_AUX_KEY = {}

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

function model_pipeline.GetPBRAuxMaterialBlock()
	return PBR_AUX_BLOCK
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

function model_pipeline.WritePBRAuxMaterialBlock(self, block)
	return WRITE_PBR_AUX_BLOCK(self, block)
end

function model_pipeline.WriteProbeMaterialBlock(self, block)
	return WRITE_PROBE_MATERIAL_BLOCK(self, block)
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

function model_pipeline.GetMaterialMemoKey()
	local material = get_material()

	if material:HasVertexAnimation() then return nil end

	return material, material.property_version
end

do
	local SCALAR_GETTERS = {
		"GetMetallicMultiplier",
		"GetRoughnessMultiplier",
		"GetRoughnessMin",
		"GetRoughnessMax",
		"GetMetallicMaskMin",
		"GetMetallicMaskMax",
		"GetEmissiveAlphaFloor",
		"GetSpecularMultiplier",
		"GetAlphaCutoff",
	}
	local SCALAR_DEFAULTS = {1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.5}
	local FEATURE_GETTERS = {}
	local FEATURE_DEFAULTS = {}

	for _, feature in ipairs(surface_features.list) do
		if feature.block == nil then
			for _, param in ipairs(feature.params or {}) do
				FEATURE_GETTERS[#FEATURE_GETTERS + 1] = "Get" .. param.name
				FEATURE_DEFAULTS[#FEATURE_DEFAULTS + 1] = param.default
			end
		end
	end

	function model_pipeline.GetPBRFactorUploadKey()
		local material = get_material()

		if not material then return NO_PBR_FACTOR_KEY end

		if material.factor_key_version ~= material.property_version then
			material.factor_key_version = material.property_version
			local is_default = true

			for i = 1, #SCALAR_GETTERS do
				if material[SCALAR_GETTERS[i]](material) ~= SCALAR_DEFAULTS[i] then
					is_default = false

					break
				end
			end

			if is_default then
				for i = 1, #FEATURE_GETTERS do
					if material[FEATURE_GETTERS[i]](material) ~= FEATURE_DEFAULTS[i] then
						is_default = false

						break
					end
				end
			end

			material.factor_key_is_default = is_default
		end

		if material.factor_key_is_default then return NO_PBR_FACTOR_KEY end

		return render3d.GetMaterialUploadKey()
	end

	function model_pipeline.GetPBRAuxUploadKey()
		local material = get_material()

		if not material then return NO_PBR_AUX_KEY end

		if material.aux_key_version ~= material.property_version then
			material.aux_key_version = material.property_version
			material.aux_key_is_default = not (
				material:GetMetallicRoughnessTexture() ~= nil or
				material:GetMetallicTexture() ~= nil or
				material:GetRoughnessTexture() ~= nil or
				material:GetAmbientOcclusionTexture() ~= nil or
				material:GetAmbientOcclusionMultiplier() ~= 1.0 or
				material:GetEmissiveTexture() ~= nil or
				material:GetAlbedoAlphaIsEmissive() or
				material:GetAdditive() or
				material:GetMetallicTextureAlphaIsEmissive()
			)
		end

		if material.aux_key_is_default then return NO_PBR_AUX_KEY end

		return render3d.GetMaterialUploadKey()
	end
end

pvars.StartGroup("Rendering", "Wind", {store = false})
local still_version = 0
local still_pixels = pvars.Setup2{
	key = "r_wind_still_pixels",
	default = 2,
	min = 0,
	help = "a plant whose movement in the wind spans fewer pixels than this stands still in the pose it has at time 0 (its lean, without the sway and the flutter), over a band of twice that. far plants only shimmer. 0 moves every plant at every distance",
	callback = function()
		still_version = still_version + 1
	end,
}
pvars.EndGroup()

do
	local FIELDS = {
		{"Time", "float", "float Time;"},
		{"PrevTime", "float", "float PrevTime;"},
		{"DetailTime", "float", "float DetailTime;"},
		{"PrevDetailTime", "float", "float PrevDetailTime;"},
		{"MainBending", "float", "float MainBending;"},
		{"BendHeight", "float", "float BendHeight;"},
		{"BendSpeed", "float", "float BendSpeed;"},
		{"BendDirection", "vec3", "float BendDirection[3];"},
		{"DetailBending", "int", "int DetailBending;"},
		{"DetailFrequency", "float", "float DetailFrequency;"},
		{"DetailLeafAmplitude", "float", "float DetailLeafAmplitude;"},
		{"DetailBranchAmplitude", "float", "float DetailBranchAmplitude;"},
		{"DetailPhase", "float", "float DetailPhase;"},
		{"Motion", "float", "float Motion;"},
	}
	local DETAIL_BENDING_MODES = {none = 0, leaves = 1, grass = 2}
	local MAIN_MOTION = 0.015 * 12 * 0.45
	local DETAIL_MOTION = 2
	local BEND_RESPONSE = 0.25
	local MAX_DETAIL_BENDING = 6
	local DETAIL_SPEED = 0.3
	local BEND_PER_HEIGHT = 0.25
	local MAX_BENDING = 7
	local BENDING_SPEED = 22

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
		local detail_speed = DETAIL_SPEED * wind_length * MAX_DETAIL_BENDING / (
				MAX_DETAIL_BENDING + wind_length
			)
		local lean = (wind:GetLength() / BENDING_SPEED) ^ 1.6
		local bending = MAX_BENDING * lean / (1 + lean)
		local polygon = render3d.GetCurrentPolygon3D()
		local height = polygon and polygon:GetBendHeight() or 0
		block.Time = atmosphere.GetWindTime()
		block.PrevTime = atmosphere.GetPreviousWindTime()
		block.DetailTime = atmosphere.GetWindDetailTime()
		block.PrevDetailTime = atmosphere.GetPreviousWindDetailTime()
		block.MainBending = height > 0 and bending * material:GetBending() * height * BEND_PER_HEIGHT or 0
		block.BendHeight = height
		block.BendSpeed = detail_speed
		block.BendDirection[0] = wind_length > 0 and wind_x / wind_length or 1
		block.BendDirection[1] = 0
		block.BendDirection[2] = wind_length > 0 and wind_z / wind_length or 0
		block.DetailBending = DETAIL_BENDING_MODES[material:GetDetailBending()]
		block.DetailFrequency = material:GetBendDetailFrequency()
		block.DetailLeafAmplitude = material:GetBendDetailLeafAmplitude()
		block.DetailBranchAmplitude = material:GetBendDetailBranchAmplitude()
		block.DetailPhase = material:GetBendDetailPhase()
		local motion = block.MainBending * MAIN_MOTION

		if block.DetailBending ~= 0 and detail_speed > 0 then
			local strength = detail_speed * block.DetailFrequency

			if block.DetailBending == 2 then
				strength = strength * (height > 0 and height or 1)
			end

			local amplitude = strength < 0.5 and strength * 2 or math.sqrt(strength * 2)
			motion = motion + DETAIL_MOTION * amplitude * math.max(block.DetailLeafAmplitude, block.DetailBranchAmplitude)
		end

		local pixels = still_pixels:Get()
		block.Motion = pixels > 0 and motion / pixels or 1e9
		return block
	end
end

function model_pipeline.GetVertexAnimationVersion()
	return atmosphere.GetWindVersion() + still_version
end

do
	local frame, position, pixel_scale = -1, nil, 0

	function model_pipeline.GetVertexAnimationView()
		local now = system.GetFrameNumber()

		if now ~= frame then
			local camera = render3d.GetCamera()
			position = camera:GetPosition()
			pixel_scale = math.abs(camera:BuildProjectionMatrix().m11) * render3d.GetRenderSize().y * 0.5
			frame = now
		end

		return position, pixel_scale
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

function model_pipeline.BuildVertexAnimationGlsl(world_matrix_expr, camera_position_expr, pixel_scale_expr)
	local still = camera_position_expr and
		(
			[[
				mat4 world = ]] .. world_matrix_expr .. [[;
				float meters = vertex_animation.Motion * length(world[1].xyz);
				float pixels = meters * ]] .. pixel_scale_expr .. [[ / max(distance(world[3].xyz, ]] .. camera_position_expr .. [[), 0.5);
				return 1.0 - smoothstep(1.0, 2.0, pixels);
		]]
		)
		or
		"return 0.0;"
	return [[

			bool has_vertex_animation() {
				return vertex_animation.MainBending > 0.0 || (vertex_animation.DetailBending != 0 && vertex_animation.BendSpeed > 0.0);
			}

			vec4 vegetation_smooth_triangle_wave(vec4 x) {
				vec4 t = abs(fract(x + 0.5) * 2.0 - 1.0);
				return t * t * (3.0 - 2.0 * t);
			}

			vec3 get_instance_conform_offset(vec3 world_pos) {
				mat4 world = ]] .. world_matrix_expr .. [[;
				uint bits = floatBitsToUint(world[3][3]);

				if ((bits & 0x80000000u) == 0u) return vec3(0.0);

				float radius = 0.02 * pow(1.12, float((bits >> 24u) & 63u));
				mat3 world_matrix3 = mat3(world);
				vec3 local = inverse(world_matrix3) * (world_pos - world[3].xyz);
				vec2 edge = clamp(local.xz / radius, -1.0, 1.0);
				vec4 heights = vec4(float(int(bits & 31u) - 16), float(int((bits >> 5u) & 31u) - 16), float(int((bits >> 10u) & 31u) - 16), float(int((bits >> 15u) & 31u) - 16)) / 15.0;
				float lift = (heights.x - heights.y) * 0.5 * edge.x + (heights.x + heights.y) * 0.5 * edge.x * edge.x + (heights.z - heights.w) * 0.5 * edge.y + (heights.z + heights.w) * 0.5 * edge.y * edge.y;
				float follow = 1.0 - smoothstep(0.0, radius, max(local.y, 0.0));
				return world_matrix3 * vec3(0.0, lift * radius * follow, 0.0);
			}

			vec3 get_vertex_animation_offset_at_time(vec3 world_pos, vec3 world_normal, vec4 vertex_color, float anim_time, float detail_time) {
				vec3 conform = get_instance_conform_offset(world_pos);

				if (!has_vertex_animation()) return conform;

				mat4 world = ]] .. world_matrix_expr .. [[;
				mat3 world_matrix3 = mat3(world);
				mat3 inv_world_matrix3 = inverse(world_matrix3);
				vec3 origin = world[3].xyz;
				vec3 start_pos = inv_world_matrix3 * (world_pos - origin);
				vec3 pos = start_pos;
				float speed = vertex_animation.BendSpeed;
				float instance_phase = fract(sin(dot(origin, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
				vec2 bend_dir = normalize((inv_world_matrix3 * vertex_animation.BendDirection).xz);

				if (vertex_animation.DetailBending != 0) {
					vec4 color = clamp(vertex_color, 0.0, 1.0);
					float edge_atten = color.r;
					float branch_atten = 1.0 - color.b;
					float detail_speed = speed;
					if (vertex_animation.DetailBending == 2) detail_speed *= pos.y;

					float branch_phase = color.g + instance_phase * 7.0;
					float vertex_phase = dot(pos, vec3(vertex_animation.DetailPhase + branch_phase));
					vec2 waves_in = detail_time + vec2(vertex_phase, branch_phase);
					vec4 waves = vegetation_smooth_triangle_wave(waves_in.xxyy * vec4(1.975, 0.793, 0.375, 0.193)) - 0.5;
					float strength = detail_speed * vertex_animation.DetailFrequency;
					float amplitude = strength < 0.5 ? strength * 2.0 : sqrt(strength * 2.0);
					vec2 waves_sum = (waves.xz + waves.yw) * amplitude;
					vec3 object_normal = normalize(transpose(world_matrix3) * world_normal);
					vec2 facing = object_normal.xz;
					pos.xz += facing * (waves_sum.x + dot(facing, bend_dir) * (amplitude + waves_sum.y) * 0.5) * edge_atten * vertex_animation.DetailLeafAmplitude;
					pos.y += waves_sum.y * branch_atten * vertex_animation.DetailBranchAmplitude;
					pos.xz += bend_dir * ((amplitude + waves_sum.y) * 0.5 * branch_atten * vertex_animation.DetailBranchAmplitude);
				}

				if (vertex_animation.MainBending > 0.0) {
					vec2 bend = bend_dir * vertex_animation.MainBending;

					float gust_time = anim_time - dot(origin.xz, vertex_animation.BendDirection.xz) / 6.0 + instance_phase * 3.0;
					float gust = 0.5 * sin(gust_time * 0.71) + 0.3 * sin(gust_time * 1.63 + 1.7) + 0.2 * sin(gust_time * 2.87 + 4.1);
					float sway_time = anim_time * 6.2832 * 1.2 / sqrt(max(vertex_animation.BendHeight, 0.5)) + instance_phase * 6.2832;
					float strength = 0.6 + 0.4 * gust;
					float along = 0.25 * gust + 0.15 * strength * sin(sway_time);
					float across = 0.12 * strength * sin(sway_time * 1.13 + 1.3);
					bend += (bend_dir * along + vec2(-bend_dir.y, bend_dir.x) * across) * vertex_animation.MainBending;
					bend *= 0.015;

					float bend_factor = pos.y / vertex_animation.BendHeight + 1.0;
					bend_factor *= bend_factor;
					bend_factor = bend_factor * bend_factor - bend_factor;
					float len = length(pos);

					if (len > 0.0) {
						vec3 bent = pos;
						bent.xz += bend * bend_factor;
						pos = normalize(bent) * len;
					}
				}

				return conform + world_matrix3 * (pos - start_pos);
			}

			float get_vertex_animation_still() {
				]] .. still .. [[
			}

			vec3 get_vertex_animation_offset_still(vec3 world_pos, vec3 world_normal, vec4 vertex_color, float anim_time, float detail_time) {
				if (!has_vertex_animation()) return get_instance_conform_offset(world_pos);

				float still = get_vertex_animation_still();

				if (still <= 0.0) return get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, anim_time, detail_time);

				vec3 at_rest = get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, 0.0, 0.0);

				if (still >= 1.0) return at_rest;

				return mix(get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, anim_time, detail_time), at_rest, still);
			}

			vec3 get_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color) {
				return get_vertex_animation_offset_still(world_pos, world_normal, vertex_color, vertex_animation.Time, vertex_animation.DetailTime);
			}

			vec3 get_previous_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color) {
				return get_vertex_animation_offset_still(world_pos, world_normal, vertex_color, vertex_animation.PrevTime, vertex_animation.PrevDetailTime);
			}
	]]
end

function model_pipeline.BuildAlphaDiscardGlsl(alpha_cutoff_expr, coverage_expr, phase_expr)
	local decal = phase_expr and
		[[
					if (SharpAlpha) alpha = smoothstep(0.3, 0.7, alpha);
					float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))) + %s);
					if (alpha <= noise) discard;
		]] or
		[[
					if (SharpAlpha) alpha = smoothstep(0.3, 0.7, alpha);
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > alpha) discard;
		]]
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
				} else if (Decal) {
]] .. decal .. [[
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (%s)) discard;
				}
			}
		]]
	):format(
		alpha_cutoff_expr,
		phase_expr or coverage_expr or "alpha * alpha",
		phase_expr and phase_expr or nil,
		phase_expr and (coverage_expr or "alpha * alpha") or nil
	)
end

function model_pipeline.SampleTextureGlsl(texture, uv)
	return "texture(TEXTURE(" .. texture .. "), " .. uv .. ")"
end

function model_pipeline.BuildAlphaSamplingGlsl(options)
	return (
		[[
			float get_alpha_uv(vec2 uv) {
				if (NormalAlphaIsCoverage && %s != -1) {
					return %s.a * %s;
				}

				if (
					%s == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive ||
					BlendTintByBaseAlpha ||
					!(AlphaTest || Translucent || Additive)
				) {
					return %s;
				}

				if (Additive) {
					vec3 albedo = %s;
					return max(albedo.r, max(albedo.g, albedo.b)) * %s;
				}

				return %s.a * %s;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
		]]
	):format(
		options.normal_texture,
		options.sample(options.normal_texture, "bump_uv(uv)"),
		options.color_alpha,
		options.albedo_texture,
		options.color_alpha,
		options.albedo_rgb,
		options.color_alpha,
		options.sample(options.albedo_texture, "base_uv(uv)"),
		options.color_alpha
	)
end

function model_pipeline.BuildNormalDecodeGlsl()
	return [[
			vec3 decode_normal_map(vec2 xy) {
				xy = xy * 2.0 - 1.0;

				return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
			}

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
]]
end

function model_pipeline.BuildSurfaceSamplingGlsl()
	return Material.BuildGlslFlags("model.Flags") .. model_pipeline.BuildNormalDecodeGlsl() .. [[

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

			vec3 get_surface_normal(vec3 normal, vec4 tangent, vec2 uv) {
				normal = normalize(normal);

				if (model.NormalTexture == -1) {
					return normal;
				}

				vec3 t = normalize(tangent.xyz);
				vec3 b = cross(normal, t) * tangent.w;

				vec3 n = decode_normal_texture(texture(TEXTURE(model.NormalTexture), uv));

				return normalize(mat3(t, b, normal) * vec3(n.xy * model.NormalMapMultiplier, n.z));
			}

			vec3 get_surface_emissive(vec3 albedo) {
				if (Additive) {
					return albedo * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}

				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;

					if (model.AlbedoTexture != -1) {
						mask = texture(TEXTURE(model.AlbedoTexture), in_uv).a;
					}

					return albedo * mask * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}

				if (model.EmissiveTexture != -1) {
					vec3 texel = texture(TEXTURE(model.EmissiveTexture), in_uv).rgb;
					vec3 emissive = EmissiveTextureIsColor ? texel : albedo * texel.r;
					return emissive * model.EmissiveMultiplier.rgb * model.EmissiveMultiplier.a;
				}

				return vec3(0.0);
			}
	]]
end

local FEATURE_BLOCKS = {}

for _, feature in ipairs(surface_features.list) do
	if feature.block == "own" then
		local no_key = {}
		local version_field = feature.name .. "_active_version"
		local active_field = feature.name .. "_active"
		local write = build_material_block_writer(feature.name, FEATURE_BLOCK_FIELDS[feature])
		table.insert(
			FEATURE_BLOCKS,
			{
				name = feature.name .. "_model",
				upload_scope = "frame_keyed",
				memo_key = model_pipeline.GetMaterialMemoKey,
				upload_key = function()
					local material = get_material()

					if not material then return no_key end

					if material[version_field] ~= material.property_version then
						material[version_field] = material.property_version
						material[active_field] = feature.active(material)
					end

					if not material[active_field] then return no_key end

					return render3d.GetMaterialUploadKey()
				end,
				block = build_material_block(FEATURE_BLOCK_FIELDS[feature]),
				write = function(self, block)
					return write(self, block)
				end,
			}
		)
	end
end

function model_pipeline.GetPBRUniformBuffers()
	local buffers = {
		{
			name = "model",
			memo_key = model_pipeline.GetMaterialMemoKey,
			upload_scope = "persistent_keyed",
			upload_key = render3d.GetMaterialUploadKey,
			block = model_pipeline.GetPBRMaterialBlock(),
			write = model_pipeline.WritePBRMaterialBlock,
		},
		{
			name = "color_model",
			memo_key = model_pipeline.GetMaterialMemoKey,
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRColorUploadKey,
			block = model_pipeline.GetPBRColorMaterialBlock(),
			write = model_pipeline.WritePBRColorMaterialBlock,
		},
		{
			name = "factor_model",
			memo_key = model_pipeline.GetMaterialMemoKey,
			upload_scope = "persistent_keyed",
			upload_key = model_pipeline.GetPBRFactorUploadKey,
			block = model_pipeline.GetPBRFactorMaterialBlock(),
			write = model_pipeline.WritePBRFactorMaterialBlock,
		},
		{
			name = "aux_model",
			memo_key = model_pipeline.GetMaterialMemoKey,
			upload_scope = "frame_keyed",
			upload_key = model_pipeline.GetPBRAuxUploadKey,
			block = model_pipeline.GetPBRAuxMaterialBlock(),
			write = model_pipeline.WritePBRAuxMaterialBlock,
		},
	}

	for _, buffer in ipairs(FEATURE_BLOCKS) do
		table.insert(buffers, buffer)
	end

	return buffers
end

function model_pipeline.BuildPBRSurfaceGlsl(camera_block_name)
	return glsl_common.GetLuminanceGLSL() .. Material.BuildGlslFlags("model.Flags") .. [=[
			vec3 get_surface_camera_position() {
				return ]=] .. camera_block_name .. [=[.camera_position;
			}

			bool terrain_layers_hidden() {
				return ]=] .. camera_block_name .. [=[.terrain_only != 0;
			}

			bool has_heightmap() {
				return displacement_model.HeightTexture != -1 && displacement_model.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				vec4 texel = texture(TEXTURE(displacement_model.HeightTexture), uv);
				return HeightTextureIsAlpha ? texel.a : texel.r;
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
				vec3 w = abs(normal);
				w = pow(w / max(max(w.x, w.y), max(w.z, 0.0001)), vec3(max(terrain_model.TerrainTriplanarSharpness, 1.0)));
				return w / max(w.x + w.y + w.z, 0.0001);
			}

			struct TerrainLayerUV {
				vec2 x;
				vec2 y;
				vec2 z;
			};

			float terrain_tiling_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
			}

			float terrain_tiling_mask(vec2 uv) {
				vec2 p = uv * 0.37 + vec2(17.3, 5.1);
				vec2 i = floor(p);
				vec2 f = fract(p);
				f = f * f * (3.0 - 2.0 * f);
				float noise = mix(mix(terrain_tiling_hash(i), terrain_tiling_hash(i + vec2(1.0, 0.0)), f.x), mix(terrain_tiling_hash(i + vec2(0.0, 1.0)), terrain_tiling_hash(i + vec2(1.0, 1.0)), f.x), f.y);
				return smoothstep(0.3, 0.7, noise);
			}

			const mat2 TERRAIN_TILING_TURN = mat2(0.8, 0.6, -0.6, 0.8);

			vec2 terrain_tiling_variant(vec2 uv) {
				return TERRAIN_TILING_TURN * uv * 1.13 + vec2(0.37, 0.71);
			}

			vec4 sample_terrain_layer_texel(int tex, vec2 uv, float anti_tiling) {
				vec4 t = texture(TEXTURE(tex), uv);

				if (anti_tiling > 0.0) {
					t = mix(t, texture(TEXTURE(tex), terrain_tiling_variant(uv)), terrain_tiling_mask(uv) * anti_tiling);
				}

				return t;
			}

			vec4 sample_terrain_layer_normal_texel(int tex, vec2 uv, float anti_tiling) {
				vec4 t = texture(TEXTURE(tex), uv);
				vec3 tn = t.xyz * 2.0 - 1.0;
				float ao = t.a;

				if (anti_tiling > 0.0) {
					vec4 t2 = texture(TEXTURE(tex), terrain_tiling_variant(uv));
					vec3 tn2 = t2.xyz * 2.0 - 1.0;
					tn2.xy = tn2.xy * TERRAIN_TILING_TURN;
					float m = terrain_tiling_mask(uv) * anti_tiling;
					tn = mix(tn, tn2, m);
					ao = mix(ao, t2.a, m);
				}

				return vec4(tn, ao);
			}

			vec4 sample_terrain_layer_triplanar(int tex, TerrainLayerUV uv, vec3 blend, float anti_tiling) {
				vec4 result = vec4(0.0);

				if (blend.y > 0.001) {
					result += sample_terrain_layer_texel(tex, uv.y, anti_tiling) * blend.y;
				}

				if (blend.x > 0.001) {
					result += sample_terrain_layer_texel(tex, uv.x, anti_tiling) * blend.x;
				}

				if (blend.z > 0.001) {
					result += sample_terrain_layer_texel(tex, uv.z, anti_tiling) * blend.z;
				}

				return result;
			}

			vec4 sample_terrain_layer_normal_triplanar(int tex, TerrainLayerUV uv, vec3 blend, vec3 N, float anti_tiling) {
				vec3 n = vec3(0.0);
				float ao = 0.0;

				if (blend.y > 0.001) {
					vec4 t = sample_terrain_layer_normal_texel(tex, uv.y, anti_tiling);
					vec3 tn = vec3(t.xy + N.xz, abs(t.z) * N.y);
					n += tn.xzy * blend.y;
					ao += t.a * blend.y;
				}

				if (blend.x > 0.001) {
					vec4 t = sample_terrain_layer_normal_texel(tex, uv.x, anti_tiling);
					vec3 tn = vec3(t.xy + N.zy, abs(t.z) * N.x);
					n += tn.zyx * blend.x;
					ao += t.a * blend.x;
				}

				if (blend.z > 0.001) {
					vec4 t = sample_terrain_layer_normal_texel(tex, uv.z, anti_tiling);
					vec3 tn = vec3(t.xy + N.xy, abs(t.z) * N.z);
					n += tn.xyz * blend.z;
					ao += t.a * blend.z;
				}

				return vec4(n, ao);
			}

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

			]=] .. terrain_layer_rules .. [=[

			void get_terrain_material_weights_both_uv(vec2 uv, out vec4 weights, out vec4 weights2) {
				weights = vec4(0.0);
				weights2 = vec4(0.0);

				if (terrain_model.TerrainMaterialTexture == -1) {
					return;
				}

				weights = max(texture(TEXTURE(terrain_model.TerrainMaterialTexture), uv), vec4(0.0));

				if (terrain_model.TerrainMaterial2Texture != -1) {
					weights2 = max(texture(TEXTURE(terrain_model.TerrainMaterial2Texture), uv), vec4(0.0));
				}

				float steepness = 1.0 - (get_terrain_world_normal(uv).y * 0.5 + 0.5);
				weights *= get_terrain_slope_mask(steepness, terrain_model.TerrainLayerSlopeMin, terrain_model.TerrainLayerSlopeMax, terrain_model.TerrainLayerSlopeBlend);
				weights2 *= get_terrain_slope_mask(steepness, terrain_model.TerrainLayerSlopeMin2, terrain_model.TerrainLayerSlopeMax2, terrain_model.TerrainLayerSlopeBlend2);

				vec4 cover = get_terrain_cover(steepness, in_position.y, terrain_model.TerrainLayerCoverSlope, terrain_model.TerrainLayerCoverStart, terrain_model.TerrainLayerCoverRange, terrain_model.TerrainLayerCoverPower, terrain_model.TerrainLayerCoverBlend);
				vec4 cover2 = get_terrain_cover(steepness, in_position.y, terrain_model.TerrainLayerCoverSlope2, terrain_model.TerrainLayerCoverStart2, terrain_model.TerrainLayerCoverRange2, terrain_model.TerrainLayerCoverPower2, terrain_model.TerrainLayerCoverBlend2);
				weights *= vec4(lessThanEqual(terrain_model.TerrainLayerCoverSlope, vec4(0.0)));
				weights2 *= vec4(lessThanEqual(terrain_model.TerrainLayerCoverSlope2, vec4(0.0)));
				float weight_sum = dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0));

				if (weight_sum > 0.0001) {
					weights /= weight_sum;
					weights2 /= weight_sum;
				} else {
					weights = vec4(0.0);
					weights2 = vec4(0.0);
				}

				float cover_sum = dot(cover, vec4(1.0)) + dot(cover2, vec4(1.0));

				if (cover_sum > 0.0001) {
					float covered = max(max(max(cover.x, cover.y), max(cover.z, cover.w)), max(max(cover2.x, cover2.y), max(cover2.z, cover2.w)));
					weights = weights * (1.0 - covered) + cover * (covered / cover_sum);
					weights2 = weights2 * (1.0 - covered) + cover2 * (covered / cover_sum);
				}
			}

			struct TerrainLayerSample {
				vec3 albedo;
				float roughness;
				vec3 normal;
				float ao;
				float normal_weight;
			};

			float get_terrain_layer_height_factor(int height_tex, vec3 world_pos, float scale, vec3 blend, float amount, float weight) {
				if (height_tex == -1 || amount <= 0.0 || weight <= 0.001) {
					return 1.0;
				}

				float safe_scale = max(scale, 0.0001);
				vec2 uv = blend.y >= blend.x && blend.y >= blend.z ? world_pos.xz / safe_scale : (blend.x >= blend.z ? world_pos.zy / safe_scale : world_pos.xy / safe_scale);
				return mix(1.0, texture(TEXTURE(height_tex), uv).r * 2.0, amount);
			}

			TerrainLayerSample terrain_layer_cache;

			void accumulate_terrain_layer(inout TerrainLayerSample s, vec3 base, int albedo_tex, int normal_tex, int height_tex, vec3 world_pos, vec3 blend, vec3 N, vec3 V, float distance_to_camera, float weight, float scale, float detail_strength, float additive_detail, float displacement, vec4 far, float fade_distance, float anti_tiling) {
				if (weight <= 0.001) {
					return;
				}

				float far_a = far.x > 0.0 ? smoothstep(far.y * 0.5, far.y, distance_to_camera) : 0.0;
				float far_b = far.z > 0.0 ? smoothstep(far.w * 0.5, far.w, distance_to_camera) : 0.0;
				float fade = fade_distance > 0.0 ? smoothstep(fade_distance * 0.5, fade_distance, distance_to_camera) : 0.0;
				vec4 albedo = vec4(0.0);
				vec4 n = vec4(0.0);

				for (int i = 0; i < 3; i++) {
					float w = (i == 0 ? (1.0 - far_a) * (1.0 - far_b) : (i == 1 ? far_a * (1.0 - far_b) : far_b)) * (1.0 - fade);

					if (w <= 0.0) {
						continue;
					}

					TerrainLayerUV uv = get_terrain_layer_uv(i == 0 ? height_tex : -1, world_pos, i == 0 ? scale : (i == 1 ? far.x : far.z), blend, N, V, i == 0 ? displacement * weight : 0.0);

					if (albedo_tex != -1) {
						albedo += sample_terrain_layer_triplanar(albedo_tex, uv, blend, anti_tiling) * w;
					}

					if (normal_tex != -1) {
						n += sample_terrain_layer_normal_triplanar(normal_tex, uv, blend, N, anti_tiling) * w;
					}
				}

				if (fade > 0.0) {
					if (albedo_tex != -1) {
						albedo += textureLod(TEXTURE(albedo_tex), vec2(0.5), 16.0) * fade;
					}

					if (normal_tex != -1) {
						n += vec4(N, 1.0) * fade;
					}
				}

				if (albedo_tex != -1) {
					if (detail_strength > 0.0) {
						if (additive_detail > 0.0) {
							vec3 base_gamma = pow(base, vec3(1.0 / 2.2));
							albedo.rgb = pow(max(base_gamma + (albedo.rgb - 0.5) * detail_strength, vec3(0.0)), vec3(2.2)) * additive_detail;
						} else {
							vec3 average = textureLod(TEXTURE(albedo_tex), vec2(0.5), 16.0).rgb;
							albedo.rgb = base * mix(vec3(1.0), albedo.rgb / max(average, vec3(0.01)), detail_strength);
						}
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
					s.normal += n.xyz * weight;
					s.ao += n.w * weight;
					s.normal_weight += weight;
				}
			}

			void compute_terrain_layer_sample(vec2 uv, vec3 world_pos) {
				TerrainLayerSample s;
				s.albedo = vec3(0.0);
				s.roughness = 0.0;
				s.normal = vec3(0.0);
				s.ao = 0.0;
				s.normal_weight = 0.0;
				vec4 weights, weights2;
				get_terrain_material_weights_both_uv(uv, weights, weights2);
				vec3 N = get_terrain_world_normal(uv);
				vec3 blend = get_terrain_triplanar_weights(N);
				vec4 scales = terrain_model.TerrainLayerScales;
				vec4 detail = terrain_model.TerrainLayerDetailStrength;
				vec4 additive_detail = terrain_model.TerrainLayerAdditiveDetail;
				vec3 base = model.AlbedoTexture != -1 ? texture(TEXTURE(model.AlbedoTexture), uv).rgb : vec3(1.0);

				if (terrain_layers_hidden()) {
					s.albedo = base;
					s.roughness = 1.0;
					s.normal = N;
					s.ao = 1.0;
					terrain_layer_cache = s;
					return;
				}

				vec3 to_camera = get_surface_camera_position() - world_pos;
				vec3 V = normalize(to_camera);
				float distance_to_camera = length(to_camera);
				float fade = 1.0 - pow(min(distance_to_camera / max(terrain_model.TerrainLayerHeightDistance, 0.001), 1.0), 4.0);
				vec4 displacement = terrain_model.TerrainLayerHeightScales * fade;
				ivec4 albedo_textures = ivec4(terrain_model.TerrainLayer1Texture, terrain_model.TerrainLayer2Texture, terrain_model.TerrainLayer3Texture, terrain_model.TerrainLayer4Texture);
				ivec4 normal_textures = ivec4(terrain_model.TerrainLayer1NormalTexture, terrain_model.TerrainLayer2NormalTexture, terrain_model.TerrainLayer3NormalTexture, terrain_model.TerrainLayer4NormalTexture);
				ivec4 height_textures = ivec4(terrain_model.TerrainLayer1HeightTexture, terrain_model.TerrainLayer2HeightTexture, terrain_model.TerrainLayer3HeightTexture, terrain_model.TerrainLayer4HeightTexture);

				vec4 height_blend = terrain_model.TerrainLayerHeightBlend;
				vec4 height_blend2 = terrain_model.TerrainLayerHeightBlend2;
				bool has_second_set = terrain_model.TerrainMaterial2Texture != -1;

				if (dot(height_blend, vec4(1.0)) + (has_second_set ? dot(height_blend2, vec4(1.0)) : 0.0) > 0.0) {
					for (int i = 0; i < 4; i++) {
						weights[i] *= get_terrain_layer_height_factor(height_textures[i], world_pos, scales[i], blend, height_blend[i], weights[i]);
					}

					if (has_second_set) {
						ivec4 height_textures2 = ivec4(terrain_model.TerrainLayer5HeightTexture, terrain_model.TerrainLayer6HeightTexture, terrain_model.TerrainLayer7HeightTexture, terrain_model.TerrainLayer8HeightTexture);

						for (int i = 0; i < 4; i++) {
							weights2[i] *= get_terrain_layer_height_factor(height_textures2[i], world_pos, terrain_model.TerrainLayerScales2[i], blend, height_blend2[i], weights2[i]);
						}
					}

					float weight_sum = dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0));
					weights /= max(weight_sum, 0.0001);
					weights2 /= max(weight_sum, 0.0001);
				}

				vec4 far_scales = terrain_model.TerrainLayerFarScales;
				vec4 far_distances = terrain_model.TerrainLayerFarDistances;
				vec4 far_scales_b = terrain_model.TerrainLayerFarScaleB;
				vec4 far_distances_b = terrain_model.TerrainLayerFarDistanceB;
				vec4 fade_distances = terrain_model.TerrainLayerFadeDistance;
				vec4 anti_tiling = terrain_model.TerrainLayerAntiTiling;

				for (int i = 0; i < 4; i++) {
					accumulate_terrain_layer(s, base, albedo_textures[i], normal_textures[i], height_textures[i], world_pos, blend, N, V, distance_to_camera, weights[i], scales[i], detail[i], additive_detail[i], displacement[i], vec4(far_scales[i], far_distances[i], far_scales_b[i], far_distances_b[i]), fade_distances[i], anti_tiling[i]);
				}

				if (terrain_model.TerrainMaterial2Texture != -1) {
					ivec4 albedo_textures2 = ivec4(terrain_model.TerrainLayer5Texture, terrain_model.TerrainLayer6Texture, terrain_model.TerrainLayer7Texture, terrain_model.TerrainLayer8Texture);
					ivec4 normal_textures2 = ivec4(terrain_model.TerrainLayer5NormalTexture, terrain_model.TerrainLayer6NormalTexture, terrain_model.TerrainLayer7NormalTexture, terrain_model.TerrainLayer8NormalTexture);
					ivec4 height_textures2 = ivec4(terrain_model.TerrainLayer5HeightTexture, terrain_model.TerrainLayer6HeightTexture, terrain_model.TerrainLayer7HeightTexture, terrain_model.TerrainLayer8HeightTexture);
					vec4 scales2 = terrain_model.TerrainLayerScales2;
					vec4 detail2 = terrain_model.TerrainLayerDetailStrength2;
					vec4 additive_detail2 = terrain_model.TerrainLayerAdditiveDetail2;
					vec4 displacement2 = terrain_model.TerrainLayerHeightScales2 * fade;
					vec4 far_scales2 = terrain_model.TerrainLayerFarScales2;
					vec4 far_distances2 = terrain_model.TerrainLayerFarDistances2;
					vec4 far_scales_b2 = terrain_model.TerrainLayerFarScaleB2;
					vec4 far_distances_b2 = terrain_model.TerrainLayerFarDistanceB2;
					vec4 fade_distances2 = terrain_model.TerrainLayerFadeDistance2;
					vec4 anti_tiling2 = terrain_model.TerrainLayerAntiTiling2;

					for (int i = 0; i < 4; i++) {
						accumulate_terrain_layer(s, base, albedo_textures2[i], normal_textures2[i], height_textures2[i], world_pos, blend, N, V, distance_to_camera, weights2[i], scales2[i], detail2[i], additive_detail2[i], displacement2[i], vec4(far_scales2[i], far_distances2[i], far_scales_b2[i], far_distances_b2[i]), fade_distances2[i], anti_tiling2[i]);
					}
				}

				if (s.normal_weight > 0.001) {
					s.normal = normalize(mix(N, normalize(s.normal), s.normal_weight));
					s.ao = mix(1.0, s.ao / s.normal_weight, s.normal_weight);
				} else {
					s.normal = N;
					s.ao = 1.0;
				}

				terrain_layer_cache = s;
			}

			void prepare_terrain_layers(vec2 uv, vec3 world_pos) {
				if (terrain_model.TerrainMaterialTexture != -1) compute_terrain_layer_sample(uv, world_pos);
			}

			float get_terrain_weighted_value(vec2 uv, vec4 values, vec4 values2) {
				if (terrain_layers_hidden()) {
					return 1.0;
				}

				vec4 weights, weights2;
				get_terrain_material_weights_both_uv(uv, weights, weights2);
				return dot(weights, values) + dot(weights2, values2);
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights, weights2;
				get_terrain_material_weights_both_uv(uv, weights, weights2);

				if (!terrain_layers_hidden() && dot(weights, vec4(1.0)) + dot(weights2, vec4(1.0)) <= 0.0001) {
					return color_model.ColorMultiplier.rgb;
				}

				return terrain_layer_cache.albedo * color_model.ColorMultiplier.rgb;
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

	]=] .. model_pipeline.BuildAlphaSamplingGlsl{
			albedo_texture = "model.AlbedoTexture",
			normal_texture = "model.NormalTexture",
			color_alpha = "color_model.ColorMultiplier.a",
			sample = model_pipeline.SampleTextureGlsl,
			albedo_rgb = "get_albedo_uv(uv)",
		} .. model_pipeline.BuildAlphaDiscardGlsl("factor_model.AlphaCutoff", nil, camera_block_name .. ".noise_phase") .. [[

			vec3 get_back_normal(vec3 N) {
				if (BentNormals) {
					vec3 face = normalize(cross(dFdx(in_position), dFdy(in_position)));
					return N - 2.0 * dot(N, face) * face;
				}

				return -N;
			}

			vec3 get_vertex_normal() {
				vec3 N = normalize(in_normal);

				if (DoubleSided && gl_FrontFacing) {
					N = get_back_normal(N);
				}

				return N;
			}

			mat3 get_tbn() {
				vec3 normal = normalize(in_normal);
				vec3 tangent = normalize(in_tangent.xyz);
				vec3 bitangent = cross(normal, tangent) * in_tangent.w;

				if (DoubleSided && gl_FrontFacing) {
					tangent = -tangent;
					bitangent = -bitangent;
					normal = get_back_normal(normal);
				}

				return mat3(tangent, bitangent, normal);
			}

			vec3 get_height_normal_tangent(vec2 uv) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(displacement_model.HeightTexture), 0));
				float left = get_height_sample(uv - vec2(texel.x, 0.0));
				float right = get_height_sample(uv + vec2(texel.x, 0.0));
				float down = get_height_sample(uv - vec2(0.0, texel.y));
				float up = get_height_sample(uv + vec2(0.0, texel.y));
				return normalize(vec3((left - right) / (2.0 * texel.x), (down - up) / (2.0 * texel.y), 1.0 / displacement_model.HeightScale));
			}

			]] .. model_pipeline.BuildNormalDecodeGlsl() .. [[
			vec3 get_normal_map(vec2 uv) {
				vec3 N = vec3(0.0, 0.0, 1.0);

				if (model.NormalTexture != -1) {
					N = decode_normal_texture(texture(TEXTURE(model.NormalTexture), bump_uv(uv)));
					N = normalize(vec3(N.xy * factor_model.NormalMapMultiplier, N.z));
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

				if (detail_model.DetailTexture != -1) {
					vec2 detail_uv = uv * detail_model.DetailTiling;
					vec2 detail = texture(TEXTURE(detail_model.DetailTexture), detail_uv).xy + texture(TEXTURE(detail_model.DetailTexture), detail_uv * 2.0).xy;
					detail = (detail - 1.0) * detail_model.DetailBumpScale;
					N.xy += detail;
				}

				if (micro_detail_model.MicroDetailTexture != -1 && micro_detail_model.MicroDetailNormal > 0.0) {
					vec2 grain_uv = uv * micro_detail_model.MicroDetailTiling;
					vec2 texel = 1.0 / vec2(textureSize(TEXTURE(micro_detail_model.MicroDetailTexture), 0));
					float height = texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv).r;
					float right = texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv + vec2(texel.x, 0.0)).r;
					float up = texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv + vec2(0.0, texel.y)).r;
					N.xy -= vec2(right - height, up - height) * micro_detail_model.MicroDetailNormal;
				}

				return normalize(N);
			}

			vec3 get_combined_normal(vec2 uv, mat3 tbn) {
				return normalize(tbn * get_normal_map(uv));
			}

			vec3 get_normal(vec2 uv, mat3 tbn) {
				vec3 N = get_combined_normal(uv, tbn);

				if (terrain_model.TerrainMaterialTexture != -1) {
					return terrain_layer_cache.normal;
				}

				return N;
			}

			float get_normal_alpha(vec2 uv) {
				float alpha = texture(TEXTURE(model.NormalTexture), bump_uv(uv)).a;

				if (detail_model.Normal2Texture != -1) {
					alpha = mix(alpha, texture(TEXTURE(detail_model.Normal2Texture), uv).a, get_texture_blend_uv(uv));
				}

				return alpha;
			}

			float get_gloss(vec2 uv) {
				if (SpecularFromRoughnessMask) {
					float mask = 1.0;

					if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
						mask = texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
					} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
						mask = get_normal_alpha(uv);
					} else if (AlbedoLuminanceIsRoughness) {
						mask = luminance(get_albedo_uv(uv));
					} else if (aux_model.RoughnessTexture != -1) {
						mask = texture(TEXTURE(aux_model.RoughnessTexture), uv).r;
					}

					return InvertRoughnessTexture ? mask : 1.0 - mask;
				}

				return 1.0;
			}

			float get_roughness_texel(vec2 uv) {
				if (model.AlbedoTexture != -1 && AlbedoTextureAlphaIsRoughness) {
					return texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a;
				} else if (model.NormalTexture != -1 && NormalTextureAlphaIsRoughness) {
					return get_normal_alpha(uv);
				} else if (AlbedoLuminanceIsRoughness) {
					return luminance(get_albedo_uv(uv));
				} else if (aux_model.RoughnessTexture != -1) {
					return texture(TEXTURE(aux_model.RoughnessTexture), uv).r;
				} else if (aux_model.MetallicRoughnessTexture != -1) {
					return texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).g;
				}

				return -1.0;
			}

			float get_metallic(vec2 uv) {
				float val = 1.0;

				if (MetallicFromRoughnessMask) {
					float texel = get_roughness_texel(uv);

					if (texel >= 0.0) {
						val = factor_model.RoughnessMax < factor_model.RoughnessMin ? texel : 1.0 - texel;
						val = clamp((val - factor_model.MetallicMaskMin) / (factor_model.MetallicMaskMax - factor_model.MetallicMaskMin), 0.0, 1.0);
						return clamp(val * factor_model.MetallicMultiplier, 0, 1);
					}
				}

				if (aux_model.MetallicTexture != -1) {
					val = texture(TEXTURE(aux_model.MetallicTexture), uv).r;
				} else if (aux_model.MetallicRoughnessTexture != -1) {
					vec3 packed_texel = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).rgb;
					val = MetallicRoughnessIsMRAO ? packed_texel.r : packed_texel.b;
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
				if (RoughnessMaskOnlyScalesSpecular) return clamp(factor_model.RoughnessMultiplier * factor_model.RoughnessMultiplier, 0.002, 1.0);

				float val = get_roughness_texel(uv);

				if (val < 0.0) {
					if (terrain_model.TerrainMaterialTexture != -1) {
						val = get_terrain_weighted_value(uv, terrain_model.TerrainLayerRoughness, terrain_model.TerrainLayerRoughness2) * terrain_layer_cache.roughness;
					} else {
						val = factor_model.RoughnessMultiplier;
						return clamp(val * val, 0.002, 1.0);
					}
				} else {
					val = mix(factor_model.RoughnessMin, factor_model.RoughnessMax, val);
				}

				val *= factor_model.RoughnessMultiplier;

				if (InvertRoughnessTexture) val = -val + 1.0;

				val *= val;
				val = clamp(val, 0.002, 1.0);
				return val;
			}

			float get_antialiased_roughness(vec3 N, float alpha) {
				vec3 dx = dFdx(N);
				vec3 dy = dFdy(N);
				float kernel = 2.0 * 0.15915494 * (dot(dx, dx) + dot(dy, dy)) * smoothstep(0.0, 0.05, alpha);
				return sqrt(clamp(alpha * alpha + min(kernel, 0.18), 0.0, 1.0));
			}

			]] .. render3d.GetEmissiveGLSL() .. [[

			vec3 get_emissive(vec2 uv) {
				vec3 emissive = vec3(0.0);

				if (Additive) {
					emissive = get_albedo_uv(uv) * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;
					if (model.AlbedoTexture != -1) {
						mask = clamp((texture(TEXTURE(model.AlbedoTexture), base_uv(uv)).a - factor_model.EmissiveAlphaFloor) / (1.0 - factor_model.EmissiveAlphaFloor), 0.0, 1.0);
					}
					emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (aux_model.EmissiveTexture != -1) {
					vec3 texel = texture(TEXTURE(aux_model.EmissiveTexture), uv).rgb;
					vec3 source = EmissiveTextureIsColor ? texel : get_albedo_uv(uv) * texel.r;
					emissive = source * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else if (aux_model.MetallicTexture != -1 && MetallicTextureAlphaIsEmissive) {
					float mask = texture(TEXTURE(aux_model.MetallicTexture), uv).a;
					emissive = get_albedo_uv(uv) * mask * aux_model.EmissiveMultiplier.rgb * aux_model.EmissiveMultiplier.a;
				} else {
					return vec3(0.0);
				}

				return min(emissive * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));
			}

			]] .. surface_features.GetGetterGLSL() .. [[

			float get_specular(vec2 uv) {
				float val = factor_model.SpecularMultiplier * get_gloss(uv);

				if (terrain_model.TerrainMaterialTexture != -1) {
					val *= get_terrain_weighted_value(uv, terrain_model.TerrainLayerSpecular, terrain_model.TerrainLayerSpecular2);
				}

				return clamp(val, 0.0, 2.0);
			}

			float get_ao(vec2 uv) {
				if (aux_model.AmbientOcclusionTexture == -1) {
					if (MetallicRoughnessIsMRAO && aux_model.MetallicRoughnessTexture != -1) {
						return texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).b * aux_model.AmbientOcclusionMultiplier;
					}

					if (terrain_model.TerrainMaterialTexture != -1) {
						return get_terrain_weighted_value(uv, terrain_model.TerrainLayerAmbientOcclusion, terrain_model.TerrainLayerAmbientOcclusion2) * terrain_layer_cache.ao * aux_model.AmbientOcclusionMultiplier;
					}

					return 1.0 * aux_model.AmbientOcclusionMultiplier;
				}

				return texture(TEXTURE(aux_model.AmbientOcclusionTexture), uv).r * aux_model.AmbientOcclusionMultiplier;
			}

			]] .. surface_features.GetSurfaceGLSL() .. surface_features.GetInitFunctionGLSL() .. [[
	]]
end

return model_pipeline
