local glsl_common = import("goluwa/render3d/glsl_common.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local terrain_layer_rules = import("goluwa/render3d/terrain_layer_rules.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local trace_break = import("goluwa/jit/tracebreak.lua")
local deformation = import("goluwa/render3d/deformation.lua")
local model_pipeline = {}
local SURFACE_MATERIAL_FIELDS = {
	{type = "flags", name = "Flags", getter = "GetFillFlags"},
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
	{type = "flags", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
}
local PBR_COLOR_FIELDS = {
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "float",
		name = "ExposureCompensation",
		getter = "GetExposureCompensation",
	},
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
	{
		type = "float",
		name = "EmissiveAlbedoFactor",
		getter = "GetEmissiveAlbedoFactor",
	},
	{type = "float", name = "NormalMapMultiplier", getter = "GetNormalMapMultiplier"},
}
local FEATURE_BLOCK_FIELDS = {}

for _, feature in ipairs(surface_features.list) do
	for _, param in ipairs(feature.params or {}) do
		local field = {
			type = param.kind or "float",
			name = param.name,
			getter = "Get" .. param.name,
			param_group = shader_features.GetParamGroup(feature.name),
		}

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
		name = "MetallicRoughness2Texture",
		getter = "GetMetallicRoughness2Texture",
	},
	{type = "float", name = "PackedSpecularScale", getter = "GetPackedSpecularScale"},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "texture", name = "MetallicTexture", getter = "GetMetallicTexture"},
	{type = "texture", name = "RoughnessTexture", getter = "GetRoughnessTexture"},
}
local PROBE_MATERIAL_FIELDS = {
	{type = "flags", name = "Flags", getter = "GetFillFlags"},
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

function model_pipeline.GetVertexBindings()
	return {
		{
			binding = 0,
			input_rate = "vertex",
			attributes = vertex_layout.GetInputAttributes(vertex_layout.CORE),
		},
		{
			binding = vertex_layout.EXTRAS_BINDING,
			input_rate = "vertex",
			attributes = vertex_layout.GetInputAttributes(vertex_layout.EXTRAS),
		},
	}
end

local INSTANCE_WORLD_EXPR = "mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
local INSTANCE_PREV_WORLD_EXPR = "mat4(in_instance_prev_world_row_0, in_instance_prev_world_row_1, in_instance_prev_world_row_2, in_instance_prev_world_row_3)"

local function build_vertex_shader(options, world_expr, prev_world_expr, main_prologue)
	local lines = {}

	if options.enable_vertex_animation ~= false then
		local camera = options.camera_block_name
		lines[#lines + 1] = deformation.BuildGlsl(
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

	if options.instance_overlay then
		lines[#lines + 1] = "\tout_instance_overlay = " .. (options.instance_overlay_expr or "0.0") .. ";"
	end

	if options.instance_dynamic then
		lines[#lines + 1] = "\tout_instance_dynamic = " .. (options.instance_dynamic_expr or "0.0") .. ";"
	end

	if options.instance_thickness_expr then
		lines[#lines + 1] = "\tout_instance_thickness = " .. options.instance_thickness_expr .. ";"
	end

	lines[#lines + 1] = "\tvec4 vertex_color = in_vertex_color;"
	lines[#lines + 1] = [[
	vec3 local_position = in_position;
	mat3 world_matrix3 = mat3(world);
	mat3 inv_world_matrix3 = inverse(world_matrix3);
	vec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);
	vec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);]]

	if options.enable_vertex_animation ~= false then
		lines[#lines + 1] = "\tDeformation deformed = deform(in_position, in_normal, uint(gl_VertexIndex), " .. (
				options.velocity and
				prev_world_expr .. ", true" or
				"world, false"
			) .. ");"
		lines[#lines + 1] = [[
	vec3 world_position = deformed.position;
	local_position += inv_world_matrix3 * deformed.offset;]]

		if options.velocity then
			lines[#lines + 1] = "\tvec3 prev_world_position = deformed.previous_position;"
		end
	else
		lines[#lines + 1] = "\tvec3 world_position = (world * vec4(local_position, 1.0)).xyz;"

		if options.velocity then
			lines[#lines + 1] = "\tvec3 prev_world_position = (" .. prev_world_expr .. " * vec4(in_position, 1.0)).xyz;"
		end
	end

	if options.shell_offset_expr then
		lines[#lines + 1] = "\tvec3 shell_offset = " .. options.shell_offset_expr .. ";"
		lines[#lines + 1] = "\tworld_position += shell_offset;"

		if options.velocity then
			lines[#lines + 1] = "\tprev_world_position += shell_offset;"
		end
	end

	if options.camera_block_name then
		lines[#lines + 1] = (
			"\tgl_Position = %s.projection * %s.view * vec4(world_position, 1.0);"
		):format(options.camera_block_name, options.camera_block_name)
	else
		lines[#lines + 1] = "\tgl_Position = vertex.projection_view_world * vec4(local_position, 1.0);"
	end

	lines[#lines + 1] = "\tout_position = world_position;"

	if options.effect_space then
		lines[#lines + 1] = "\tbool overlaid = out_instance_overlay > 0.0;"
		lines[#lines + 1] = "\tout_effect_position = overlaid ? local_position : world_position;"
		lines[#lines + 1] = "\tout_effect_normal = overlaid ? in_normal : world_normal;"
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

	if options.instance_overlay then
		outputs[#outputs + 1] = {"instance_overlay", "float"}
	end

	if options.instance_dynamic then
		outputs[#outputs + 1] = {"instance_dynamic", "float"}
	end

	if options.effect_space then
		outputs[#outputs + 1] = {"effect_position", "vec3"}
		outputs[#outputs + 1] = {"effect_normal", "vec3"}
	end

	if options.instance_thickness_expr then
		outputs[#outputs + 1] = {"instance_thickness", "float"}
	end

	return outputs
end

model_pipeline.GetVertexStageOutputs = get_vertex_stage_outputs

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
			upload_key = deformation.GetUploadKey,
			block = deformation.GetBlock(),
			write = deformation.WriteBlock,
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
		bindings = model_pipeline.GetVertexBindings(),
		outputs = model_pipeline.GetVertexAttributes(),
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
		shader = vertex_layout.PACKING_GLSL .. build_vertex_shader(
				options,
				"vertex.world",
				"vertex.prev_world",
				vertex_layout.BuildInputDecodeGlsl()
			),
	}

	if
		options.velocity or
		options.lod_fade or
		options.instance_overlay or
		options.instance_dynamic or
		options.effect_space
	then
		local outputs = model_pipeline.GetVertexAttributes()

		if options.velocity then
			outputs[#outputs + 1] = {"prev_position", "vec3"}
		end

		if options.lod_fade then outputs[#outputs + 1] = {"lod_fade", "float"} end

		if options.instance_overlay then
			outputs[#outputs + 1] = {"instance_overlay", "float"}
		end

		if options.instance_dynamic then
			outputs[#outputs + 1] = {"instance_dynamic", "float"}
		end

		if options.effect_space then
			outputs[#outputs + 1] = {"effect_position", "vec3"}
			outputs[#outputs + 1] = {"effect_normal", "vec3"}
		end

		stage.outputs = outputs
	end

	return stage
end

function model_pipeline.CreateInstancedVertexStage(options)
	local bindings = {
		model_pipeline.GetVertexBindings()[1],
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

	bindings[#bindings + 1] = model_pipeline.GetVertexBindings()[2]
	return {
		bindings = bindings,
		outputs = get_vertex_stage_outputs(options),
		uniform_buffers = get_vertex_stage_uniform_buffers(options),
		shader = vertex_layout.PACKING_GLSL .. build_vertex_shader(
				options,
				INSTANCE_WORLD_EXPR,
				INSTANCE_PREV_WORLD_EXPR,
				vertex_layout.BuildInputDecodeGlsl()
			),
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
			record_blocks[#record_blocks + 1] = {
				name = ubo.name,
				field = "m_" .. ubo.name,
				block = ubo.block,
				write = ubo.write,
				param_group = ubo.param_group,
				fields = ubo.fields,
			}
		end

		record_blocks[#record_blocks + 1] = {
			name = "refraction_record",
			field = "m_refraction_record",
			block = {
				{"amount", "float"},
				{"ior", "float"},
				{"abbe", "float"},
			},
			write = function(self, block)
				local material = get_material()
				block.amount = material:GetRefraction()
				block.ior = material:GetEffectiveIOR()
				block.abbe = material:GetAbbeNumber()
			end,
		}
		record_blocks[#record_blocks + 1] = {
			name = "vertex_animation",
			field = "m_vertex_animation",
			block = deformation.GetBlock(),
			write = deformation.WriteBlock,
		}
		return record_blocks
	end

	function model_pipeline.GetPBRBatchRecordType()
		if record_type then return record_type end

		local ffi_fields = {
			"uint32_t addresses[4];",
			"uint32_t extras_address[2];",
			"uint32_t index_is_32;",
		}
		local glsl = {}
		local glsl_fields = {"\tuvec4 addresses;", "\tuvec2 extras_address;", "\tuint index_is_32;"}

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

	local defaults_glsl

	-- a variant without a param group's bit reads that group's params as a default material's values, so their glsl folds away; draw.SetRow gives a row the bits of the groups its material moves a param of (Material:GetSurfaceParamBits)
	local function get_defaults_glsl()
		if defaults_glsl then return defaults_glsl end

		local material = Material.New()
		local floats = ffi.new("float[4]")

		local function literal(def)
			local value = material[def.getter](material)

			if def.type == "texture" then
				assert(value == nil, def.name .. " has a default texture")
				return "-1"
			elseif def.type == "int" then
				return string.format("%d", value)
			elseif def.type == "float" then
				return string.format("%.9e", value)
			end

			value:CopyToFloatPointer(floats)
			local parts = {}

			for i = 0, tonumber(def.type:sub(4)) - 1 do
				parts[i + 1] = string.format("%.9e", floats[i])
			end

			return def.type .. "(" .. table.concat(parts, ", ") .. ")"
		end

		local lines = {}

		for _, group in ipairs(shader_features.param_groups) do
			lines[#lines + 1] = shader_features.GetDefaultGLSL(group.name)
		end

		for _, info in ipairs(get_record_blocks()) do
			if info.param_group then
				local values = {}

				for i, def in ipairs(info.fields) do
					values[i] = literal(def)
				end

				lines[#lines + 1] = string.format(
					"#define %s_default PBRBatch_%s(%s)",
					info.name,
					info.name,
					table.concat(values, ", ")
				)
			elseif info.name == "factor_model" then
				lines[#lines + 1] = "PBRBatch_factor_model factor_model_grouped(PBRBatch_factor_model f) {"

				for _, def in ipairs(info.fields) do
					if def.param_group then
						lines[#lines + 1] = string.format(
							"#if %s == 0\n\tf.%s = %s;\n#endif",
							def.param_group.define,
							def.name,
							literal(def)
						)
					end
				end

				lines[#lines + 1] = "\treturn f;\n}"
			end
		end

		defaults_glsl = table.concat(lines, "\n") .. "\n"
		return defaults_glsl
	end

	function model_pipeline.BuildPBRBatchRecordGlsl(batch_expr)
		model_pipeline.GetPBRBatchRecordType()

		if not batch_expr then return record_glsl end

		local defines = {}

		for _, info in ipairs(get_record_blocks()) do
			if info.name ~= "vertex_animation" then
				local source = "(" .. batch_expr .. ")." .. info.field

				if info.param_group then
					defines[#defines + 1] = string.format(
						"#if %s\n#define %s %s\n#else\n#define %s %s_default\n#endif",
						info.param_group.define,
						info.name,
						source,
						info.name,
						info.name
					)
				elseif info.name == "factor_model" then
					defines[#defines + 1] = "#define factor_model factor_model_grouped(" .. source .. ")"
				else
					defines[#defines + 1] = "#define " .. info.name .. " " .. source
				end
			end
		end

		return record_glsl .. get_defaults_glsl() .. table.concat(defines, "\n") .. "\n"
	end

	local write_record

	function model_pipeline.WritePBRBatchRecord(pipeline, record)
		if not write_record then
			local blocks = get_record_blocks()
			local lines = {
				"local blocks, trace_break = ...",
				"return function(pipeline, record)",
			}

			for i, info in ipairs(blocks) do
				if i > 1 then lines[#lines + 1] = "\ttrace_break()" end

				lines[#lines + 1] = string.format("\tblocks[%d].write(pipeline, record.%s)", i, info.field)
			end

			lines[#lines + 1] = "end"
			write_record = assert(loadstring(table.concat(lines, "\n"), "pbr_batch_record_writer"))(blocks, trace_break)
		end

		return write_record(pipeline, record)
	end

	function model_pipeline.WritePBRBatchAnimationRecord(pipeline, record)
		deformation.WriteBlock(pipeline, record.m_vertex_animation)
	end

	function model_pipeline.CreateMultiDrawVertexStage(options)
		local outputs = get_vertex_stage_outputs(options)
		local batch_location = #outputs
		local fetch = {}

		for _, field in ipairs(vertex_layout.Fields) do
			fetch[#fetch + 1] = string.format(
				"\t%s in_%s = pbr_vertex_%s(%s, vertex_index);",
				field.glsl,
				field.name,
				field.alias:lower(),
				field.group == "core" and "data" or "extras"
			)
		end

		local main_prologue = [[
	uint batch_index = ]] .. (
				options.batch_index_expr or
				"uint(gl_DrawID)"
			) .. [[;
	out_batch = batch_index;
	out_instance = uint(gl_InstanceIndex);
	out_triangle = uint(gl_VertexIndex) / 3u;
	out_draw = uint(gl_DrawID);
	out_vertex = uint(gl_VertexIndex);
	PBRBatchData batch_data = PBRBatchData(]] .. options.batches_expr .. [[);
	uvec4 addresses = batch_data.b[batch_index].addresses;

	if (addresses.x == 0u && addresses.y == 0u) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
		return;
	}

	uint vertex_index = uint(gl_VertexIndex);
	PBRBatchVertexData data = PBRBatchVertexData(packUint2x32(addresses.xy));
	PBRBatchVertexData extras = PBRBatchVertexData(packUint2x32(batch_data.b[batch_index].extras_address));
]] .. table.concat(fetch, "\n") .. [[

	multi_draw_instance_world = PBRBatchInstanceData(]] .. options.instances_expr .. [[).worlds[gl_InstanceIndex];
	multi_draw_instance_prev_world = PBRBatchInstanceData(]] .. options.prev_instances_expr .. [[).worlds[gl_InstanceIndex];
	vertex_animation = batch_data.b[batch_index].m_vertex_animation;
	vertex_animation.Time = ]] .. options.time_expr .. [[;
	vertex_animation.PrevTime = ]] .. options.prev_time_expr .. [[;
	vertex_animation.DetailTime = ]] .. options.detail_time_expr .. [[;
	vertex_animation.PrevDetailTime = ]] .. options.prev_detail_time_expr .. [[;
]]
		options.instance_overlay_expr = "world[1][3]"
		options.instance_dynamic_expr = "world[2][3]"
		return {
			outputs = outputs,
			batch_location = batch_location,
			uniform_buffers = options.uniform_buffers,
			custom_declarations = model_pipeline.BuildPBRBatchRecordGlsl() .. [[
layout(buffer_reference, scalar) readonly buffer PBRBatchVertexData { float v[]; };
]] .. vertex_layout.BuildGlslAccessors("pbr_vertex", "PBRBatchVertexData") .. [[
layout(buffer_reference, scalar) readonly buffer PBRBatchInstanceData { mat4 worlds[]; };
layout(buffer_reference, scalar) readonly buffer PBRDrawGroupData { uint g[]; };
layout(buffer_reference, scalar) readonly buffer PBRBatchThicknessData { float t[]; };
layout(location = ]] .. batch_location .. [[) flat out uint out_batch;
layout(location = ]] .. (
					batch_location + 1
				) .. [[) flat out uint out_instance;
layout(location = ]] .. (
					batch_location + 2
				) .. [[) flat out uint out_triangle;
layout(location = ]] .. (
					batch_location + 3
				) .. [[) flat out uint out_draw;
layout(location = ]] .. (
					batch_location + 4
				) .. [[) flat out uint out_vertex;
mat4 multi_draw_instance_world;
mat4 multi_draw_instance_prev_world;
PBRBatch_vertex_animation vertex_animation;

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

	for _, def in ipairs(field_defs) do
		if def.type == "texture" then
			block[#block + 1] = {def.name, "int"}
		elseif def.type == "flags" then
			for _, field in ipairs(Material.FlagSet:GetBlockFields(def.name)) do
				block[#block + 1] = field
			end
		else
			block[#block + 1] = {def.name, def.type}
		end
	end

	return block
end

local function build_material_block_writer(name, field_defs)
	local lines = {
		"return function(get_material, trace_break)",
		"\treturn function(self, block, material)",
		"\tmaterial = material or get_material()",
	}

	for i, def in ipairs(field_defs) do
		-- one trace for a long block exceeds the snapshot and tail call limits and runs interpreted
		if i % 8 == 0 then lines[#lines + 1] = "\ttrace_break()" end

		local info = Material.objects_variables[def.name]
		local value = info and
			def.getter == info.get_name and
			Material[def.getter] == info.default_getter and
			"material." .. def.name or
			"material:" .. def.getter .. "()"

		if def.type == "flags" then
			for word = 0, Material.FlagSet:GetWordCount() - 1 do
				lines[#lines + 1] = string.format(
					"\tblock.%s = material:%s(%d)",
					Material.FlagSet.GetFieldName(def.name, word),
					def.getter,
					word
				)
			end
		elseif def.type == "texture" then
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
	return assert(loadstring(table.concat(lines, "\n"), name .. "_material_block_writer"))()(get_material, trace_break)
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
		"GetEmissiveAlbedoFactor",
	}
	local SCALAR_DEFAULTS = {1.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.0, 1.0, 0.5, 0.0}
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

function model_pipeline.BuildAlphaDiscardGlsl(alpha_cutoff_expr, coverage_expr, phase_expr)
	local decal = phase_expr and
		[[
					float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + $PHASE * 9.04165, vec2(0.06711056, 0.00583715))));
					if (alpha <= noise) discard;
		]] or
		[[
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > alpha) discard;
		]]
	local alpha_test = phase_expr and
		[[
					if (AlphaCoverage) {
						float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + $PHASE * 9.04165, vec2(0.06711056, 0.00583715))));
						if (alpha <= noise) discard;
					} else {
						float coverage = clamp((alpha - $CUTOFF) / max(fwidth(alpha), 0.0001) + 0.5, 0.0, 1.0);
						float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + $PHASE * 9.04165, vec2(0.06711056, 0.00583715))));
						if (coverage <= noise) discard;
					}
		]] or
		[[
					if (AlphaCoverage) {
						if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > alpha) discard;
					} else if (alpha < $CUTOFF) {
						discard;
					}
		]]
	local code = [[
			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
]] .. alpha_test .. [[
				} else if (Decal) {
]] .. decal .. [[
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > ($COVERAGE)) discard;
				}
			}
		]]
	local replacements = {
		CUTOFF = alpha_cutoff_expr,
		PHASE = phase_expr or "0.0",
		COVERAGE = coverage_expr or "alpha * alpha",
	}
	return (code:gsub("%$(%u+)", replacements))
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
	return Material.FlagSet:BuildGlsl("model.Flags") .. model_pipeline.BuildNormalDecodeGlsl() .. [[

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
				param_group = shader_features.GetParamGroup(feature.name),
				fields = FEATURE_BLOCK_FIELDS[feature],
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
			fields = PBR_FACTOR_FIELDS,
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

model_pipeline.TERRAIN_RELIEF_GLSL = [=[
#ifndef MODEL_PIPELINE_TERRAIN_RELIEF
#define MODEL_PIPELINE_TERRAIN_RELIEF
			bool has_terrain_layers() {
				return TERRAIN_LAYERS != 0 && terrain_model.TerrainMaterialTexture != -1;
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

			float sample_terrain_layer_height(int height_tex, vec3 p, float safe_scale, vec3 blend, vec2 gx[3], vec2 gy[3]) {
				vec2 uv[3] = vec2[3](p.zy / safe_scale, p.xz / safe_scale, p.xy / safe_scale);
				float h = 0.0;

				for (int i = 0; i < 3; i++) {
					if (blend[i] > 0.001) {
						h += textureGrad(TEXTURE(height_tex), uv[i], gx[i], gy[i]).r * blend[i];
					}
				}

				return h / max(blend.x + blend.y + blend.z, 0.001);
			}

]=] .. terrain_layer_rules .. [=[


			void get_terrain_material_weights_both_uv(vec2 uv, vec3 N, float world_y, out vec4 weights, out vec4 weights2) {
				weights = vec4(0.0);
				weights2 = vec4(0.0);

				if (!has_terrain_layers()) {
					return;
				}

				weights = max(texture(TEXTURE(terrain_model.TerrainMaterialTexture), uv), vec4(0.0));

				if (terrain_model.TerrainMaterial2Texture != -1) {
					weights2 = max(texture(TEXTURE(terrain_model.TerrainMaterial2Texture), uv), vec4(0.0));
				}

				float steepness = 1.0 - (N.y * 0.5 + 0.5);
				bool has_second_set = terrain_model.TerrainMaterial2Texture != -1;

				if (any(greaterThan(terrain_model.TerrainLayerSlopeMin, vec4(-1.0))) || any(lessThan(terrain_model.TerrainLayerSlopeMax, vec4(2.0)))) {
					weights *= get_terrain_slope_mask(steepness, terrain_model.TerrainLayerSlopeMin, terrain_model.TerrainLayerSlopeMax, terrain_model.TerrainLayerSlopeBlend);
				}

				if (has_second_set && (any(greaterThan(terrain_model.TerrainLayerSlopeMin2, vec4(-1.0))) || any(lessThan(terrain_model.TerrainLayerSlopeMax2, vec4(2.0))))) {
					weights2 *= get_terrain_slope_mask(steepness, terrain_model.TerrainLayerSlopeMin2, terrain_model.TerrainLayerSlopeMax2, terrain_model.TerrainLayerSlopeBlend2);
				}

				bool has_cover = any(greaterThan(terrain_model.TerrainLayerCoverSlope, vec4(0.0))) || (has_second_set && any(greaterThan(terrain_model.TerrainLayerCoverSlope2, vec4(0.0))));
				vec4 cover = vec4(0.0);
				vec4 cover2 = vec4(0.0);

				if (has_cover) {
					cover = get_terrain_cover(steepness, world_y, terrain_model.TerrainLayerCoverSlope, terrain_model.TerrainLayerCoverStart, terrain_model.TerrainLayerCoverRange, terrain_model.TerrainLayerCoverPower, terrain_model.TerrainLayerCoverBlend);
					cover2 = get_terrain_cover(steepness, world_y, terrain_model.TerrainLayerCoverSlope2, terrain_model.TerrainLayerCoverStart2, terrain_model.TerrainLayerCoverRange2, terrain_model.TerrainLayerCoverPower2, terrain_model.TerrainLayerCoverBlend2);
				}


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

				if (has_cover && cover_sum > 0.0001) {
					float covered = max(max(max(cover.x, cover.y), max(cover.z, cover.w)), max(max(cover2.x, cover2.y), max(cover2.z, cover2.w)));
					weights = weights * (1.0 - covered) + cover * (covered / cover_sum);
					weights2 = weights2 * (1.0 - covered) + cover2 * (covered / cover_sum);
				}
			}

		struct TerrainShellWeights {
			vec4 weights;
			vec4 weights2;
			vec3 blend;
			vec2 uv;
		};

		TerrainShellWeights terrain_shell_weights(vec2 uv, vec3 normal, float world_y) {
			TerrainShellWeights w;
			w.uv = clamp(uv, 0.0, 1.0);
			get_terrain_material_weights_both_uv(w.uv, normal, world_y, w.weights, w.weights2);
			vec3 blend = get_terrain_triplanar_weights(normal);
			blend = max(blend - 0.2, vec3(0.0));
			w.blend = blend / max(blend.x + blend.y + blend.z, 0.0001);
			return w;
		}

		float terrain_shell_relief_set(vec4 weights, ivec4 height_textures, vec4 height_scales, vec4 scales, vec4 height_blend, vec4 cover_slope, vec4 cover_depth, vec3 q, vec3 blend, vec2 gx[3], vec2 gy[3], inout float weight_sum, inout float cover_amount, inout float cover_level) {
			float relief = 0.0;

			for (int i = 0; i < 4; i++) {
				if (weights[i] <= 0.001) {
					continue;
				}

				float h = height_textures[i] != -1 ? sample_terrain_layer_height(height_textures[i], q, max(scales[i], 0.0001), blend, gx, gy) : 0.5;

				if (cover_slope[i] > 0.0) {
					cover_amount += weights[i];
					cover_level += weights[i] * (cover_depth[i] + (height_textures[i] != -1 ? h * height_scales[i] * scales[i] : 0.0));
					continue;
				}

				float w = weights[i] * mix(1.0, h * 2.0, height_blend[i]);
				weight_sum += w;

				if (height_textures[i] != -1) {
					relief += w * h * height_scales[i] * scales[i];
				}
			}

			return relief;
		}

		float terrain_shell_relief(vec3 q, TerrainShellWeights w, vec2 gx[3], vec2 gy[3]) {
			float weight_sum = 0.0;
			float cover_amount = 0.0;
			float cover_level = 0.0;
			float relief = terrain_shell_relief_set(w.weights, ivec4(terrain_model.TerrainLayer1HeightTexture, terrain_model.TerrainLayer2HeightTexture, terrain_model.TerrainLayer3HeightTexture, terrain_model.TerrainLayer4HeightTexture), terrain_model.TerrainLayerHeightScales, terrain_model.TerrainLayerScales, terrain_model.TerrainLayerHeightBlend, terrain_model.TerrainLayerCoverSlope, terrain_model.TerrainLayerCoverDepth, q, w.blend, gx, gy, weight_sum, cover_amount, cover_level);

			if (terrain_model.TerrainMaterial2Texture != -1) {
				relief += terrain_shell_relief_set(w.weights2, ivec4(terrain_model.TerrainLayer5HeightTexture, terrain_model.TerrainLayer6HeightTexture, terrain_model.TerrainLayer7HeightTexture, terrain_model.TerrainLayer8HeightTexture), terrain_model.TerrainLayerHeightScales2, terrain_model.TerrainLayerScales2, terrain_model.TerrainLayerHeightBlend2, terrain_model.TerrainLayerCoverSlope2, terrain_model.TerrainLayerCoverDepth2, q, w.blend, gx, gy, weight_sum, cover_amount, cover_level);
			}

			float base = weight_sum > 0.0001 ? relief / weight_sum : 0.0;

			if (cover_amount <= 0.0) {
				return base;
			}

			return mix(base, max(base, cover_level / cover_amount), min(cover_amount, 1.0));
		}

#endif
]=]

function model_pipeline.BuildPBRSurfaceGlsl(camera_block_name, mip_bias)
	local glsl = glsl_common.GetLuminanceGLSL() .. Material.FlagSet:BuildGlsl("model.Flags") .. [=[
			vec3 get_surface_camera_position() {
				return ]=] .. camera_block_name .. [=[.camera_position;
			}

			bool terrain_layers_hidden() {
				return ]=] .. camera_block_name .. [=[.terrain_only != 0;
			}

			]=] .. shader_features.GetDefaultGLSL("terrain") .. [=[

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

]=] .. model_pipeline.TERRAIN_RELIEF_GLSL .. [=[

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

			vec3 sample_terrain_layer_normal_texel(int tex, vec2 uv, float anti_tiling) {
				vec4 t = texture(TEXTURE(tex), uv);
				vec3 tn = t.xyz * 2.0 - 1.0;

				if (anti_tiling > 0.0) {
					vec4 t2 = texture(TEXTURE(tex), terrain_tiling_variant(uv));
					vec3 tn2 = t2.xyz * 2.0 - 1.0;
					tn2.xy = tn2.xy * TERRAIN_TILING_TURN;
					float m = terrain_tiling_mask(uv) * anti_tiling;
					tn = mix(tn, tn2, m);
				}

				return tn;
			}

			vec4 sample_terrain_layer_triplanar(int tex, TerrainLayerUV uv, vec3 blend, float anti_tiling) {
				vec4 result = vec4(0.0);

				for (int a = 0; a < 3; a++) {
					float w = a == 0 ? blend.y : (a == 1 ? blend.x : blend.z);

					if (w > 0.001) {
						result += sample_terrain_layer_texel(tex, a == 0 ? uv.y : (a == 1 ? uv.x : uv.z), anti_tiling) * w;
					}
				}

				return result;
			}

			vec3 sample_terrain_layer_normal_triplanar(int tex, TerrainLayerUV uv, vec3 blend, vec3 N, float anti_tiling, int detail_tex, float detail_tiling, float detail_scale) {
				vec3 n = vec3(0.0);

				for (int a = 0; a < 3; a++) {
					float w = a == 0 ? blend.y : (a == 1 ? blend.x : blend.z);

					if (w > 0.001) {
						vec2 axis_uv = a == 0 ? uv.y : (a == 1 ? uv.x : uv.z);
						vec3 t = sample_terrain_layer_normal_texel(tex, axis_uv, anti_tiling);

						if (detail_tex != -1) {
							vec2 detail_uv = axis_uv * detail_tiling;
							t.xy += (texture(TEXTURE(detail_tex), detail_uv).xy + texture(TEXTURE(detail_tex), detail_uv * 2.0).xy - 1.0) * detail_scale;
						}

						vec3 tn = vec3(t.xy + (a == 0 ? N.xz : (a == 1 ? N.zy : N.xy)), abs(t.z) * (a == 0 ? N.y : (a == 1 ? N.x : N.z)));
						n += (a == 0 ? tn.xzy : (a == 1 ? tn.zyx : tn.xyz)) * w;
					}
				}

				return n;
			}

			TerrainLayerUV get_terrain_layer_uv(int height_tex, vec3 world_pos, float scale, vec3 blend, vec3 N, vec3 V, float displacement) {
				float safe_scale = max(scale, 0.0001);
				vec3 p = world_pos;

				if (height_tex != -1 && displacement > 0.0) {
					const int STEPS = 24;
					float facing = dot(V, N);
					float fade = smoothstep(0.05, 0.25, facing);
					float depth = displacement * safe_scale * fade;

					if (depth > 0.0) {
						vec2 gx[3] = vec2[3](dFdx(world_pos.zy) / safe_scale, dFdx(world_pos.xz) / safe_scale, dFdx(world_pos.xy) / safe_scale);
						vec2 gy[3] = vec2[3](dFdy(world_pos.zy) / safe_scale, dFdy(world_pos.xz) / safe_scale, dFdy(world_pos.xy) / safe_scale);
						vec3 to_top = V * (depth / max(facing, 0.05));
						float level = 1.0;
						float prev_level = 1.0;
						float height = sample_terrain_layer_height(height_tex, world_pos + to_top, safe_scale, blend, gx, gy);

						for (int i = 0; i < STEPS && height < level; i++) {
							prev_level = level;
							level -= 1.0 / float(STEPS);
							height = sample_terrain_layer_height(height_tex, world_pos + to_top * level, safe_scale, blend, gx, gy);
						}

						float lo = level;
						float hi = prev_level;

						for (int i = 0; i < 4; i++) {
							float mid = 0.5 * (lo + hi);

							if (mid <= sample_terrain_layer_height(height_tex, world_pos + to_top * mid, safe_scale, blend, gx, gy)) {
								lo = mid;
							} else {
								hi = mid;
							}
						}

						p = world_pos + to_top * (0.5 * (lo + hi));
					}
				}

				return TerrainLayerUV(p.zy / safe_scale, p.xz / safe_scale, p.xy / safe_scale);
			}

			struct TerrainLayerSample {
				vec3 albedo;
				float roughness;
				vec3 normal;
				float normal_weight;
				vec4 weights;
				vec4 weights2;
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

			void accumulate_terrain_layer(inout TerrainLayerSample s, vec3 base, int albedo_tex, int normal_tex, int height_tex, vec3 world_pos, vec3 blend, vec3 N, vec3 V, float distance_to_camera, float weight, float scale, float detail_strength, float additive_detail, float displacement, vec4 far, float fade_distance, float fade_distance_xy, float anti_tiling, int detail_tex, float detail_tiling, float detail_scale) {
				if (weight <= 0.001) {
					return;
				}

				float far_a = far.x > 0.0 ? smoothstep(far.y * 0.5, far.y, distance_to_camera) : 0.0;
				float far_b = far.z > 0.0 ? smoothstep(far.w * 0.5, far.w, distance_to_camera) : 0.0;
				float fade = 0.0;

				if (fade_distance > 0.0) {
					float fade_up = 1.0 - sqrt(max(1.0 - pow(min(distance_to_camera / fade_distance, 1.0), 4.0), 0.0));
					float fade_side = fade_distance_xy > 0.0 ? 1.0 - sqrt(max(1.0 - pow(min(distance_to_camera / fade_distance_xy, 1.0), 4.0), 0.0)) : fade_up;
					fade = mix(fade_side, fade_up, blend.y);
				}
				vec4 albedo = vec4(0.0);
				vec3 n = vec3(0.0);
				anti_tiling *= 1.0 - smoothstep(100.0, 200.0, distance_to_camera);

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
						n += sample_terrain_layer_normal_triplanar(normal_tex, uv, blend, N, anti_tiling, i == 0 ? detail_tex : -1, detail_tiling, detail_scale) * w;
					}
				}

				if (fade > 0.0) {
					if (albedo_tex != -1) {
						albedo += texture_average(albedo_tex) * fade;
					}

					if (normal_tex != -1) {
						n += N * fade;
					}
				}

				if (albedo_tex != -1) {
					if (detail_strength > 0.0) {
						if (additive_detail > 0.0) {
							vec3 base_gamma = pow(base, vec3(1.0 / 2.2));
							vec3 detail = albedo.rgb - texture_average(albedo_tex).rgb * fade - 0.5 * (1.0 - fade);
							albedo.rgb = pow(max(base_gamma + detail * detail_strength, vec3(0.0)), vec3(2.2)) * mix(additive_detail, 1.0, fade);
						} else {
							vec3 average = texture_average(albedo_tex).rgb;
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
					s.normal += n * weight;
					s.normal_weight += weight;
				}
			}

			int terrain_layer_albedo_texture(int k) {
				switch (k) {
					case 0: return terrain_model.TerrainLayer1Texture;
					case 1: return terrain_model.TerrainLayer2Texture;
					case 2: return terrain_model.TerrainLayer3Texture;
					case 3: return terrain_model.TerrainLayer4Texture;
					case 4: return terrain_model.TerrainLayer5Texture;
					case 5: return terrain_model.TerrainLayer6Texture;
					case 6: return terrain_model.TerrainLayer7Texture;
					case 7: return terrain_model.TerrainLayer8Texture;
				}

				return -1;
			}

			int terrain_layer_normal_texture(int k) {
				switch (k) {
					case 0: return terrain_model.TerrainLayer1NormalTexture;
					case 1: return terrain_model.TerrainLayer2NormalTexture;
					case 2: return terrain_model.TerrainLayer3NormalTexture;
					case 3: return terrain_model.TerrainLayer4NormalTexture;
					case 4: return terrain_model.TerrainLayer5NormalTexture;
					case 5: return terrain_model.TerrainLayer6NormalTexture;
					case 6: return terrain_model.TerrainLayer7NormalTexture;
					case 7: return terrain_model.TerrainLayer8NormalTexture;
				}

				return -1;
			}

			int terrain_layer_detail_texture(int k) {
				switch (k) {
					case 0: return terrain_model.TerrainLayer1DetailTexture;
					case 1: return terrain_model.TerrainLayer2DetailTexture;
					case 2: return terrain_model.TerrainLayer3DetailTexture;
					case 3: return terrain_model.TerrainLayer4DetailTexture;
					case 4: return terrain_model.TerrainLayer5DetailTexture;
					case 5: return terrain_model.TerrainLayer6DetailTexture;
					case 6: return terrain_model.TerrainLayer7DetailTexture;
					case 7: return terrain_model.TerrainLayer8DetailTexture;
				}

				return -1;
			}

			int terrain_layer_height_texture(int k) {
				switch (k) {
					case 0: return terrain_model.TerrainLayer1HeightTexture;
					case 1: return terrain_model.TerrainLayer2HeightTexture;
					case 2: return terrain_model.TerrainLayer3HeightTexture;
					case 3: return terrain_model.TerrainLayer4HeightTexture;
					case 4: return terrain_model.TerrainLayer5HeightTexture;
					case 5: return terrain_model.TerrainLayer6HeightTexture;
					case 6: return terrain_model.TerrainLayer7HeightTexture;
					case 7: return terrain_model.TerrainLayer8HeightTexture;
				}

				return -1;
			}

			void compute_terrain_layer_sample(vec2 uv, vec3 world_pos) {
				TerrainLayerSample s;
				s.albedo = vec3(0.0);
				s.roughness = 0.0;
				s.normal = vec3(0.0);
				s.normal_weight = 0.0;
				vec3 N = get_terrain_world_normal(uv);
				vec4 weights, weights2;
				get_terrain_material_weights_both_uv(uv, N, in_position.y, weights, weights2);
				s.weights = weights;
				s.weights2 = weights2;
				vec3 blend = max(get_terrain_triplanar_weights(N) - 0.05, vec3(0.0));
				blend /= max(blend.x + blend.y + blend.z, 0.0001);
				vec4 scales = terrain_model.TerrainLayerScales;
				vec4 detail = terrain_model.TerrainLayerDetailStrength;
				vec4 additive_detail = terrain_model.TerrainLayerAdditiveDetail;
				vec3 base = model.AlbedoTexture != -1 ? texture(TEXTURE(model.AlbedoTexture), uv).rgb : vec3(1.0);

				if (terrain_layers_hidden()) {
					s.albedo = base;
					s.roughness = 1.0;
					s.normal = N;
					terrain_layer_cache = s;
					return;
				}

				vec3 to_camera = get_surface_camera_position() - world_pos;
				vec3 V = normalize(to_camera);
				float distance_to_camera = length(to_camera);
				float fade = 1.0 - pow(min(distance_to_camera / max(terrain_model.TerrainLayerHeightDistance, 0.001), 1.0), 4.0);
				fade *= terrain_model.TerrainShell > 0.0 ? 0.0 : 1.0;
				vec4 displacement = terrain_model.TerrainLayerHeightScales * fade;


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

				for (int k = 0; k < (has_second_set ? 8 : 4); k++) {
					int i = k & 3;
					bool second = k >= 4;
					accumulate_terrain_layer(s, base, terrain_layer_albedo_texture(k), terrain_layer_normal_texture(k), terrain_layer_height_texture(k), world_pos, blend, N, V, distance_to_camera, second ? weights2[i] : weights[i], second ? terrain_model.TerrainLayerScales2[i] : terrain_model.TerrainLayerScales[i], second ? terrain_model.TerrainLayerDetailStrength2[i] : terrain_model.TerrainLayerDetailStrength[i], second ? terrain_model.TerrainLayerAdditiveDetail2[i] : terrain_model.TerrainLayerAdditiveDetail[i], (second ? terrain_model.TerrainLayerHeightScales2[i] : terrain_model.TerrainLayerHeightScales[i]) * fade, second ? vec4(terrain_model.TerrainLayerFarScales2[i], terrain_model.TerrainLayerFarDistances2[i], terrain_model.TerrainLayerFarScaleB2[i], terrain_model.TerrainLayerFarDistanceB2[i]) : vec4(terrain_model.TerrainLayerFarScales[i], terrain_model.TerrainLayerFarDistances[i], terrain_model.TerrainLayerFarScaleB[i], terrain_model.TerrainLayerFarDistanceB[i]), second ? terrain_model.TerrainLayerFadeDistance2[i] : terrain_model.TerrainLayerFadeDistance[i], second ? terrain_model.TerrainLayerFadeDistanceXY2[i] : terrain_model.TerrainLayerFadeDistanceXY[i], second ? terrain_model.TerrainLayerAntiTiling2[i] : terrain_model.TerrainLayerAntiTiling[i], terrain_layer_detail_texture(k), second ? terrain_model.TerrainLayerDetailBumpTiling2[i] : terrain_model.TerrainLayerDetailBumpTiling[i], second ? terrain_model.TerrainLayerDetailBumpScale2[i] : terrain_model.TerrainLayerDetailBumpScale[i]);
				}

				if (s.normal_weight > 0.001) {
					vec3 layer_normal = normalize(s.normal);
					float along = dot(layer_normal, N);
					layer_normal = normalize(N * along + (layer_normal - N * along) * ]=] .. camera_block_name .. [=[.normal_map_strength);
					s.normal = normalize(mix(N, layer_normal, s.normal_weight));
				} else {
					s.normal = N;
				}

				terrain_layer_cache = s;
			}

			void prepare_terrain_layers(vec2 uv, vec3 world_pos) {
				if (has_terrain_layers()) compute_terrain_layer_sample(uv, world_pos);
			}

			float get_terrain_weighted_value(vec4 values, vec4 values2) {
				if (terrain_layers_hidden()) {
					return 1.0;
				}

				return dot(terrain_layer_cache.weights, values) + dot(terrain_layer_cache.weights2, values2);
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				if (!terrain_layers_hidden() && dot(terrain_layer_cache.weights, vec4(1.0)) + dot(terrain_layer_cache.weights2, vec4(1.0)) <= 0.0001) {
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
				if (has_terrain_layers()) {
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

				if (detail_model.DetailColorTexture != -1) {
					vec3 detail_color = texture(TEXTURE(detail_model.DetailColorTexture), base_uv(uv) * detail_model.DetailTiling).rgb;

					if (detail_model.DetailColorMode < 1.5) {
						rgb1 *= mix(vec3(1.0), detail_color * 1.9922, detail_model.DetailBlendAmount);
					} else {
						vec3 gamma = pow(max(rgb1, vec3(0.0)), vec3(1.0 / 2.2));
						detail_color *= 0.9961;
						vec3 screen = 1.0 - (1.0 - detail_color) * (1.0 - gamma) * 2.0;
						vec3 multiply = detail_color * gamma * 2.0;
						vec3 overlay = mix(multiply, screen, greaterThanEqual(gamma, vec3(0.5)));
						rgb1 = mix(rgb1, pow(max(overlay, vec3(0.0)), vec3(2.2)), detail_model.DetailBlendAmount);
					}
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
				vec3 bitangent = cross(normal, tangent) * sign(in_tangent.w);

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

				if (detail_model.DetailNormalTexture != -1) {
					vec3 detail_normal = decode_normal_map(texture(TEXTURE(detail_model.DetailNormalTexture), base_uv(uv) * detail_model.DetailTiling).xy);
					detail_normal = mix(vec3(0.0, 0.0, 1.0), detail_normal, detail_model.DetailBlendAmount * detail_model.DetailBumpScale);
					N = normalize(N * detail_normal.z + vec3(N.z * detail_normal.z * detail_normal.xy, 0.0));
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

				if (has_terrain_layers()) {
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
					float roughness = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).g;

					if (aux_model.MetallicRoughness2Texture != -1) {
						roughness = mix(roughness, texture(TEXTURE(aux_model.MetallicRoughness2Texture), uv).g, get_texture_blend_uv(uv));
					}

					return roughness;
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

					if (aux_model.MetallicRoughness2Texture != -1) {
						packed_texel = mix(packed_texel, texture(TEXTURE(aux_model.MetallicRoughness2Texture), uv).rgb, get_texture_blend_uv(uv));
					}

					val = MetallicRoughnessIsMR ? packed_texel.r : packed_texel.b;
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
					if (has_terrain_layers()) {
						val = get_terrain_weighted_value(terrain_model.TerrainLayerRoughness, terrain_model.TerrainLayerRoughness2) * terrain_layer_cache.roughness;
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
					vec3 source = EmissiveTextureIsColor ? mix(texel, texel * get_albedo_uv(uv), factor_model.EmissiveAlbedoFactor) : get_albedo_uv(uv) * texel.r;
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

				if (aux_model.PackedSpecularScale > 0.0 && aux_model.MetallicRoughnessTexture != -1) {
					float packed_specular = texture(TEXTURE(aux_model.MetallicRoughnessTexture), uv).b;

					if (aux_model.MetallicRoughness2Texture != -1) {
						packed_specular = mix(packed_specular, texture(TEXTURE(aux_model.MetallicRoughness2Texture), uv).b, get_texture_blend_uv(uv));
					}

					val = factor_model.SpecularMultiplier * packed_specular * aux_model.PackedSpecularScale;
				}

				if (has_terrain_layers()) {
					val *= get_terrain_weighted_value(terrain_model.TerrainLayerSpecular, terrain_model.TerrainLayerSpecular2);
				}

				return clamp(val, 0.0, 2.0);
			}

			]] .. surface_features.GetSurfaceGLSL() .. surface_features.GetInitFunctionGLSL() .. [[
	]]

	if not mip_bias then return glsl end

	return (
		glsl:gsub("%f[%w_]texture(%b())", function(args)
			local inner = args:sub(2, -2)
			local depth = 0
			local commas = {}

			for i = 1, #inner do
				local c = inner:sub(i, i)

				if c == "(" then
					depth = depth + 1
				elseif c == ")" then
					depth = depth - 1
				elseif c == "," and depth == 0 then
					commas[#commas + 1] = i
				end
			end

			if commas[2] then
				return "texture(" .. inner:sub(1, commas[2]) .. " (" .. inner:sub(commas[2] + 1) .. ") + " .. camera_block_name .. ".mip_bias)"
			end

			return "texture(" .. inner .. ", " .. camera_block_name .. ".mip_bias)"
		end)
	)
end

return model_pipeline
