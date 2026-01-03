local ffi = require("ffi")
local prototype = require("prototype")
local render = require("render.render")
local UniformBuffer = require("render.uniform_buffer")
local EasyPipeline = prototype.CreateTemplate("render", "pipeline")

function EasyPipeline.GetColorFormats(config)
	local formats = {}

	if type(config.color_format) == "table" then
		for i, format in ipairs(config.color_format) do
			if type(format) == "table" then
				table.insert(formats, format[1])
			else
				table.insert(formats, format)
			end
		end
	end

	return formats
end

function EasyPipeline.New(config)
	local self = EasyPipeline:CreateObject()
	local glsl_to_ffi = {
		mat4 = "float",
		vec4 = "float",
		vec3 = "float",
		vec2 = "float",
		float = "float",
		int = "int",
		ivec4 = "int",
		ivec3 = "int",
		ivec2 = "int",
	}
	local glsl_to_array_size = {
		mat4 = 16,
		vec4 = 4,
		vec3 = 3,
		vec2 = 2,
		ivec4 = 4,
		ivec3 = 3,
		ivec2 = 2,
	}
	local push_constant_types = {}
	local stage_sizes = {vertex = 0, fragment = 0}
	local uniform_buffer_types = {}
	local uniform_buffers = {}
	local actual_color_formats = {}
	local fragment_outputs = ""

	if type(config.color_format) == "table" then
		for i, format in ipairs(config.color_format) do
			if type(format) == "table" then
				local actual_format = format[1]
				table.insert(actual_color_formats, actual_format)
				fragment_outputs = fragment_outputs .. string.format("layout(location = %d) out vec4 out_%d;\n", i - 1, i - 1)

				for j = 2, #format do
					local mapping = format[j]
					local name = mapping[1]
					local swizzle = mapping[2]
					local glsl_type = "float"

					if #swizzle == 2 then
						glsl_type = "vec2"
					elseif #swizzle == 3 then
						glsl_type = "vec3"
					elseif #swizzle == 4 then
						glsl_type = "vec4"
					end

					fragment_outputs = fragment_outputs .. string.format("void set_%s(%s val) { out_%d.%s = val; }\n", name, glsl_type, i - 1, swizzle)
				end
			else
				table.insert(actual_color_formats, format)
			end
		end
	end

	local function flatten_fields(fields, out)
		out = out or {}

		for _, field in ipairs(fields) do
			if type(field[1]) == "table" then
				flatten_fields(field, out)
			else
				table.insert(out, field)
			end
		end

		return out
	end

	local function get_field_info(field)
		local name = field[1]
		local glsl_type = field[2]
		local callback = field[3]
		local array_size = type(field[4]) == "number" and field[4] or nil
		return {
			name = name,
			glsl_type = glsl_type,
			callback = type(callback) == "function" and callback or nil,
			array_size = array_size,
		}
	end

	local function get_layout_info(layout, glsl_type, array_size)
		local base_alignment = 4
		local size = 4

		if glsl_type == "float" or glsl_type == "int" then
			base_alignment = 4
			size = 4
		elseif glsl_type == "vec2" then
			base_alignment = 8
			size = 8
		elseif glsl_type == "vec3" then
			base_alignment = 16
			size = 12
		elseif glsl_type == "vec4" then
			base_alignment = 16
			size = 16
		elseif glsl_type == "mat4" then
			base_alignment = 16
			size = 64
		end

		if layout == "scalar" then
			if glsl_type == "vec2" then
				base_alignment = 4
			elseif glsl_type == "vec3" then
				base_alignment = 4
			elseif glsl_type == "vec4" then
				base_alignment = 4
			elseif glsl_type == "mat4" then
				base_alignment = 4
			end
		end

		if layout == "std140" then
			if array_size then
				-- Rule 4: Each element is aligned to 16 bytes
				base_alignment = math.max(base_alignment, 16)
				local element_size = math.max(size, 16) -- Stride is at least 16
				size = element_size * array_size
			end
		else
			if array_size then size = size * array_size end
		end

		return base_alignment, size
	end

	local function verify_layout(layout, struct_name, fields, ctype)
		local current_offset = 0
		local max_alignment = (layout == "std140" or layout == "std430") and 16 or 4

		for _, field in ipairs(fields) do
			local info = get_field_info(field)
			local base_alignment, size = get_layout_info(layout, info.glsl_type, info.array_size)
			max_alignment = math.max(max_alignment, base_alignment)
			-- Round up current_offset to base_alignment
			current_offset = math.ceil(current_offset / base_alignment) * base_alignment
			local ffi_offset = tonumber(ffi.offsetof(ctype, info.name))

			if ffi_offset ~= current_offset then
				error(
					string.format(
						"Uniform buffer/Push constant '%s' field '%s' has incorrect alignment for layout '%s'!\n" .. "GLSL expected offset: %d\n" .. "FFI (C) actual offset: %d\n" .. "Type: %s%s",
						struct_name,
						info.name,
						layout,
						current_offset,
						ffi_offset,
						info.glsl_type,
						info.array_size and ("[" .. info.array_size .. "]") or ""
					)
				)
			end

			current_offset = current_offset + size
		end

		local expected_total_size = math.ceil(current_offset / max_alignment) * max_alignment

		if layout == "std140" then
			expected_total_size = math.ceil(expected_total_size / 16) * 16
		end

		local ffi_size = ffi.sizeof(ctype)
		local ffi_alignment = ffi.alignof(ctype)

		if ffi_size < expected_total_size then
			error(
				string.format(
					"Uniform buffer/Push constant '%s' has incorrect total size for layout '%s'!\n" .. "GLSL expected size: %d\n" .. "FFI (C) actual size: %d\n" .. "FFI (C) actual alignment: %d\n" .. "Hint: You might need to add padding or use __attribute__((aligned(%d)))",
					struct_name,
					layout,
					expected_total_size,
					ffi_size,
					ffi_alignment,
					max_alignment
				)
			)
		end
	end

	local function build_ffi_struct(layout, fields)
		local ffi_code = "struct __attribute__((packed, aligned(16))) {\n"
		local current_offset = 0
		local max_alignment = 16

		for _, field in ipairs(fields) do
			local info = get_field_info(field)
			local ffi_type = glsl_to_ffi[info.glsl_type] or info.glsl_type
			local base_size = glsl_to_array_size[info.glsl_type]
			local base_alignment, size = get_layout_info(layout, info.glsl_type, info.array_size)
			max_alignment = math.max(max_alignment, base_alignment)
			local aligned_offset = math.ceil(current_offset / base_alignment) * base_alignment

			if aligned_offset > current_offset then
				ffi_code = ffi_code .. string.format("    char _pad_%d[%d];\n", current_offset, aligned_offset - current_offset)
			end

			if info.array_size and base_size then
				ffi_code = ffi_code .. string.format("    %s %s[%d][%d];\n", ffi_type, info.name, info.array_size, base_size)
			elseif info.array_size or base_size then
				ffi_code = ffi_code .. string.format("    %s %s[%d];\n", ffi_type, info.name, info.array_size or base_size)
			else
				ffi_code = ffi_code .. string.format("    %s %s;\n", ffi_type, info.name)
			end

			current_offset = aligned_offset + size
		end

		local final_size = math.ceil(current_offset / max_alignment) * max_alignment

		if final_size > current_offset then
			ffi_code = ffi_code .. string.format("    char _pad_end[%d];\n", final_size - current_offset)
		end

		ffi_code = ffi_code .. "}"
		return ffi_code
	end

	local function build_glsl_fields(fields)
		local glsl_fields = ""

		for _, field in ipairs(fields) do
			local info = get_field_info(field)

			if info.array_size then
				glsl_fields = glsl_fields .. string.format("    %s %s[%d];\n", info.glsl_type, info.name, info.array_size)
			else
				glsl_fields = glsl_fields .. string.format("    %s %s;\n", info.glsl_type, info.name)
			end
		end

		return glsl_fields
	end

	-- Process push constants and uniform buffers
	for stage, stage_config in pairs(config) do
		if
			type(stage_config) ~= "table" or
			stage == "rasterizer" or
			stage == "color_blend" or
			stage == "multisampling" or
			stage == "depth_stencil"
		then
			goto continue
		end

		-- Process push constants
		if stage_config.push_constants then
			for _, block in ipairs(stage_config.push_constants) do
				block.block = flatten_fields(block.block)
				local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
				local ffi_code = build_ffi_struct("scalar", block.block)
				local ctype = ffi.typeof(ffi_code)
				verify_layout("scalar", struct_name, block.block, ctype)
				push_constant_types[struct_name] = ctype
				stage_sizes[stage] = stage_sizes[stage] + ffi.sizeof(ctype)
			end
		end

		-- Process uniform buffers
		if stage_config.uniform_buffers then
			for _, block in ipairs(stage_config.uniform_buffers) do
				block.block = flatten_fields(block.block)
				local ffi_code = build_ffi_struct("scalar", block.block)
				local glsl_fields = build_glsl_fields(block.block)
				local ubo = UniformBuffer.New(ffi_code)
				verify_layout("scalar", block.name, block.block, ubo.struct)
				local glsl_declaration = string.format(
					"layout(scalar, binding = %d) uniform %s {\n%s} %s;",
					block.binding_index,
					block.name:sub(1, 1):upper() .. block.name:sub(2),
					glsl_fields,
					block.name
				)
				uniform_buffer_types[block.name] = {ubo = ubo, block = block, glsl = glsl_declaration}
				uniform_buffers[block.name] = ubo
			end
		end

		::continue::
	end

	local function get_glsl_push_constants(stage)
		local stage_config = config[stage]

		if not stage_config or not stage_config.push_constants then return "" end

		local blocks = stage_config.push_constants
		local str = ""

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			str = str .. "struct " .. struct_name .. " {\n"

			for _, field in ipairs(block.block) do
				local info = get_field_info(field)

				if info.array_size then
					str = str .. string.format("    %s %s[%d];\n", info.glsl_type, info.name, info.array_size)
				else
					str = str .. string.format("    %s %s;\n", info.glsl_type, info.name)
				end
			end

			str = str .. "};\n\n"
		end

		str = str .. "layout(push_constant, scalar) uniform Constants {\n"

		if stage == "fragment" then
			str = str .. "    layout(offset = " .. stage_sizes.vertex .. ")\n"
		end

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			str = str .. "    " .. struct_name .. " " .. block.name .. ";\n"
		end

		str = str .. "} pc;\n\n"
		return str
	end

	local function get_glsl_uniform_buffers(stage)
		local stage_config = config[stage]

		if not stage_config or not stage_config.uniform_buffers then return "" end

		local glsl = ""

		for _, block in ipairs(stage_config.uniform_buffers) do
			glsl = glsl .. uniform_buffer_types[block.name].glsl .. "\n\n"
		end

		return glsl
	end

	-- Build constants upload function
	local constant_structs = {}

	for struct_name, ctype in pairs(push_constant_types) do
		constant_structs[struct_name] = ctype()
	end

	function self:UploadConstants(cmd)
		-- Vertex stage
		if config.vertex and config.vertex.push_constants then
			local offset = 0

			for _, block in ipairs(config.vertex.push_constants) do
				local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
				local constants = constant_structs[struct_name]

				for _, field in ipairs(block.block) do
					local info = get_field_info(field)

					if info.callback then info.callback(self, constants, info.name) end
				end

				self.pipeline:PushConstants(cmd, "vertex", offset, constants)
				offset = offset + ffi.sizeof(push_constant_types[struct_name])
			end
		end

		-- Fragment stage
		if config.fragment and config.fragment.push_constants then
			local offset = stage_sizes.vertex

			for _, block in ipairs(config.fragment.push_constants) do
				local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
				local constants = constant_structs[struct_name]

				for _, field in ipairs(block.block) do
					local info = get_field_info(field)

					if info.callback then info.callback(self, constants, info.name) end
				end

				self.pipeline:PushConstants(cmd, "fragment", offset, constants)
				offset = offset + ffi.sizeof(push_constant_types[struct_name])
			end
		end

		-- Update uniform buffers
		for name, info in pairs(uniform_buffer_types) do
			local ubo_data = info.ubo:GetData()

			for _, field in ipairs(info.block.block) do
				local field_info = get_field_info(field)

				if field_info.callback then
					field_info.callback(self, ubo_data, field_info.name)
				end
			end

			info.ubo:Upload()
		end
	end

	-- Store uniform buffers for external access
	self.uniform_buffers = uniform_buffers
	-- Build vertex attributes
	local attributes = {}
	local vertex_attributes_size = 0

	if config.vertex and config.vertex.attributes then
		for _, attribute in ipairs(config.vertex.attributes) do
			local offset = 0

			do
				local prev = attributes[#attributes]

				if prev then
					local size = render.GetVulkanFormatSize(prev.format)
					offset = prev.offset + size
				end
			end

			table.insert(
				attributes,
				{
					binding = config.vertex.binding_index or 0,
					location = #attributes,
					format = attribute[3],
					offset = offset,
				}
			)
			vertex_attributes_size = vertex_attributes_size + render.GetVulkanFormatSize(attribute[3])
		end
	end

	local bindings = {}

	if #attributes > 0 then
		bindings = {
			{
				binding = config.vertex.binding_index or 0,
				stride = vertex_attributes_size,
				input_rate = "vertex",
			},
		}
	end

	-- Build shader header and I/O
	local shader_header = [[
	#version 450
	#extension GL_EXT_nonuniform_qualifier : require
	#extension GL_EXT_scalar_block_layout : require
]]
	local vertex_input = ""
	local vertex_output = ""

	if config.vertex and config.vertex.attributes then
		for i, attr in ipairs(config.vertex.attributes) do
			vertex_input = vertex_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
			vertex_output = vertex_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
		end
	end

	-- Build shader stages
	local shader_stages = {}

	-- Vertex stage
	if config.vertex then
		local vertex_code = shader_header .. vertex_input .. vertex_output .. get_glsl_push_constants("vertex") .. (
				config.vertex.custom_declarations or
				""
			) .. (
				config.vertex.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "vertex",
				code = vertex_code,
				bindings = bindings,
				attributes = attributes,
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
				push_constants = stage_sizes.vertex > 0 and
					{
						size = stage_sizes.vertex,
						offset = 0,
					} or
					nil,
			}
		)
	end

	-- Fragment stage
	if config.fragment then
		local fragment_code = shader_header .. vertex_input .. [[
			layout(binding = 0) uniform sampler2D textures[1024];
			layout(binding = 1) uniform samplerCube cubemaps[1024];
			#define TEXTURE(idx) textures[nonuniformEXT(idx)]
			#define CUBEMAP(idx) cubemaps[nonuniformEXT(idx)]

		]] .. fragment_outputs .. (
				config.fragment.custom_declarations or
				""
			) .. get_glsl_push_constants("fragment") .. get_glsl_uniform_buffers("fragment") .. (
				config.fragment.shader or
				""
			)
		-- Build descriptor sets
		local descriptor_sets = {
			-- Texture array sampler (binding 0)
			{
				type = "combined_image_sampler",
				binding_index = 0,
				count = 1024,
			},
			-- Cubemap array sampler (binding 1)
			{
				type = "combined_image_sampler",
				binding_index = 1,
				count = 1024,
			},
		}

		-- Add custom descriptor sets if provided
		if config.fragment.descriptor_sets then
			for _, desc in ipairs(config.fragment.descriptor_sets) do
				if type(desc.args) == "function" then desc.args = desc.args() end

				table.insert(descriptor_sets, desc)
			end
		end

		-- Add uniform buffers from config
		if config.fragment.uniform_buffers then
			for _, block in ipairs(config.fragment.uniform_buffers) do
				table.insert(
					descriptor_sets,
					{
						type = "uniform_buffer",
						binding_index = block.binding_index,
						args = {uniform_buffers[block.name].buffer},
					}
				)
			end
		end

		table.insert(
			shader_stages,
			{
				type = "fragment",
				code = fragment_code,
				descriptor_sets = descriptor_sets,
				push_constants = stage_sizes.fragment > 0 and
					{
						size = stage_sizes.fragment,
						offset = stage_sizes.vertex,
					} or
					nil,
			}
		)
	end

	-- Create pipeline
	local pipeline_config = {
		color_format = #actual_color_formats > 0 and actual_color_formats or config.color_format,
		depth_format = config.depth_format,
		samples = config.samples,
		dynamic_states = {"viewport", "scissor", "cull_mode"},
		shader_stages = shader_stages,
		rasterizer = config.rasterizer or
			{
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "back",
				front_face = "counter_clockwise",
				depth_bias = 0,
			},
		color_blend = config.color_blend or
			{
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = false,
						src_color_blend_factor = "src_alpha",
						dst_color_blend_factor = "one_minus_src_alpha",
						color_blend_op = "add",
						src_alpha_blend_factor = "one",
						dst_alpha_blend_factor = "zero",
						alpha_blend_op = "add",
						color_write_mask = {"r", "g", "b", "a"},
					},
				},
			},
		multisampling = config.multisampling or
			{
				sample_shading = false,
				rasterization_samples = "1",
			},
		depth_stencil = config.depth_stencil or
			{
				depth_test = true,
				depth_write = true,
				depth_compare_op = "less",
				depth_bounds_test = false,
				stencil_test = false,
			},
	}
	self.pipeline = render.CreateGraphicsPipeline(pipeline_config)
	self.vertex_attributes = attributes
	return self
end

function EasyPipeline:Bind(cmd, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	frame_index = frame_index or render.GetCurrentFrame()
	self.pipeline:Bind(cmd, frame_index)
end

function EasyPipeline:GetVertexAttributes()
	return self.vertex_attributes
end

function EasyPipeline:GetTextureIndex(texture)
	return self.pipeline:GetTextureIndex(texture)
end

function EasyPipeline:PushConstants(...)
	return self.pipeline:PushConstants(...)
end

return EasyPipeline:Register()
