local ffi = require("ffi")
local prototype = require("prototype")
local render = require("render.render")
local UniformBuffer = require("render.uniform_buffer")
local Framebuffer = require("render.framebuffer")
local system = require("system")
local EasyPipeline = prototype.CreateTemplate("render_easy_pipeline")

function EasyPipeline.GetColorFormats(config)
	local formats = {}

	if type(config.color_format) == "table" then
		for i, format in ipairs(config.color_format) do
			if type(format) == "table" then
				local actual_format = format[1]

				-- Resolve function to get actual format
				if type(actual_format) == "function" then
					actual_format = actual_format()
				end

				table.insert(formats, actual_format)
			else
				-- Resolve function to get actual format
				if type(format) == "function" then format = format() end

				table.insert(formats, format)
			end
		end
	end

	return formats
end

function EasyPipeline.New(config)
	local self = EasyPipeline:CreateObject()
	self.on_draw = config.on_draw or nil

	-- Resolve format functions if they exist
	if type(config.depth_format) == "function" then
		config.depth_format = config.depth_format()
	end

	if type(config.samples) == "function" then config.samples = config.samples() end

	if not config.vertex then
		config.vertex = {
			shader = [[
				layout(location = 0) out vec2 out_uv;
				void main() {
					vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
					gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
					out_uv = uv;
				}
			]],
		}
		assert(config.fragment)
		config.fragment.custom_declarations = (config.fragment.custom_declarations or "") .. [[
			layout(location = 0) in vec2 in_uv;
		]]
	end

	-- Resolve color format functions
	if type(config.color_format) == "table" then
		for i, format in ipairs(config.color_format) do
			if type(format) == "table" then
				-- Resolve first element if it's a function
				if type(format[1]) == "function" then format[1] = format[1]() end
			end
		end
	end

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
		uint64_t = "uint64_t",
	}
	local glsl_to_array_size = {
		mat4 = 16,
		vec4 = 4,
		vec3 = 3,
		vec2 = 2,
		ivec4 = 4,
		ivec3 = 3,
		ivec2 = 2,
		uint64_t = 1,
	}
	local push_constant_types = {}
	local possible_stages = {"task_ext", "mesh_ext", "vertex", "fragment", "compute"}
	local push_constant_blocks = {}
	local push_constant_block_order = {}
	local push_constant_block_offsets = {}
	local uniform_buffer_types = {}
	local uniform_buffers = {}
	local actual_color_formats = {}
	local fragment_outputs = ""
	local debug_views = {}
	local color_formats = config.color_format

	if type(color_formats) == "string" then color_formats = {color_formats} end

	if type(color_formats) == "table" then
		for i, format in ipairs(color_formats) do
			if type(format) == "table" then
				local actual_format = format[1]
				table.insert(actual_color_formats, actual_format)
				local max_component = 0
				local component_map = {r = 1, g = 2, b = 3, a = 4, x = 1, y = 2, z = 3, w = 4}

				for j = 2, #format do
					local swizzle = format[j][2]

					for char in swizzle:gmatch(".") do
						max_component = math.max(max_component, component_map[char] or 0)
					end
				end

				max_component = math.max(max_component, 1)
				local output_type = "float"

				if max_component == 2 then
					output_type = "vec2"
				elseif max_component == 3 then
					output_type = "vec3"
				elseif max_component == 4 then
					output_type = "vec4"
				end

				fragment_outputs = fragment_outputs .. string.format("layout(location = %d) out %s out_%d;\n", i - 1, output_type, i - 1)

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

					if output_type == "float" then
						fragment_outputs = fragment_outputs .. string.format("void set_%s(%s val) { out_%d = val; }\n", name, glsl_type, i - 1)
					else
						fragment_outputs = fragment_outputs .. string.format("void set_%s(%s val) { out_%d.%s = val; }\n", name, glsl_type, i - 1, swizzle)
					end

					table.insert(
						debug_views,
						{
							name = name,
							attachment_index = i,
							swizzle = swizzle,
						}
					)
				end
			else
				table.insert(actual_color_formats, format)
				local out_name = "out_" .. (i - 1)
				fragment_outputs = fragment_outputs .. string.format("layout(location = %d) out vec4 %s;\n", i - 1, out_name)

				if i == 1 then
					fragment_outputs = fragment_outputs .. "#define out_color " .. out_name .. "\n"
				end

				table.insert(
					debug_views,
					{
						name = "Target " .. i,
						attachment_index = i,
						swizzle = "rgba",
					}
				)
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
		local is_struct = type(glsl_type) == "table"
		return {
			name = name,
			glsl_type = glsl_type,
			callback = type(callback) == "function" and callback or nil,
			array_size = array_size,
			is_struct = is_struct,
		}
	end

	local function get_layout_info(layout, glsl_type, array_size, struct_fields)
		local base_alignment = 4
		local size = 4

		-- Handle struct types
		if type(glsl_type) == "table" then
			local struct_size = 0
			local max_alignment = 4

			for _, field in ipairs(glsl_type) do
				local field_name = field[1]
				local field_type = field[2]
				local field_array_size = field[3]
				local field_base_alignment, field_size = get_layout_info(layout, field_type, field_array_size)
				max_alignment = math.max(max_alignment, field_base_alignment)
				struct_size = math.ceil(struct_size / field_base_alignment) * field_base_alignment
				struct_size = struct_size + field_size
			end

			-- Round up to alignment
			struct_size = math.ceil(struct_size / max_alignment) * max_alignment
			base_alignment = max_alignment
			size = struct_size
		elseif glsl_type == "float" or glsl_type == "int" then
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
		elseif glsl_type == "uint64_t" then
			base_alignment = 8
			size = 8
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
			local base_alignment, size = get_layout_info(layout, info.glsl_type, info.array_size, info.is_struct and field[2] or nil)
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

	local struct_counter = 0

	local function build_ffi_struct(layout, fields)
		local ffi_code = "struct __attribute__((packed)) {\n"
		local current_offset = 0
		local max_alignment = 16
		local struct_definitions = {}

		for _, field in ipairs(fields) do
			local info = get_field_info(field)
			local ffi_type = glsl_to_ffi[info.glsl_type] or info.glsl_type
			local base_size = glsl_to_array_size[info.glsl_type]

			-- Handle struct types
			if info.is_struct then
				struct_counter = struct_counter + 1
				local struct_name = "Struct_" .. info.name .. "_" .. struct_counter
				local struct_code = "struct __attribute__((packed)) {\n"
				local struct_offset = 0
				local struct_max_align = 4

				for _, struct_field in ipairs(info.glsl_type) do
					local sf_name = struct_field[1]
					local sf_type = struct_field[2]
					local sf_array_size = struct_field[3]
					local sf_ffi_type = glsl_to_ffi[sf_type] or sf_type
					local sf_base_size = glsl_to_array_size[sf_type]
					local sf_base_alignment, sf_size = get_layout_info(layout, sf_type, sf_array_size)
					struct_max_align = math.max(struct_max_align, sf_base_alignment)
					local sf_aligned_offset = math.ceil(struct_offset / sf_base_alignment) * sf_base_alignment

					if sf_aligned_offset > struct_offset then
						struct_code = struct_code .. string.format("    char _pad_%d[%d];\n", struct_offset, sf_aligned_offset - struct_offset)
					end

					if sf_array_size and sf_base_size and sf_base_size > 1 then
						struct_code = struct_code .. string.format("    %s %s[%d][%d];\n", sf_ffi_type, sf_name, sf_array_size, sf_base_size)
					elseif sf_array_size or (sf_base_size and sf_base_size > 1) then
						struct_code = struct_code .. string.format("    %s %s[%d];\n", sf_ffi_type, sf_name, sf_array_size or sf_base_size)
					else
						struct_code = struct_code .. string.format("    %s %s;\n", sf_ffi_type, sf_name)
					end

					struct_offset = sf_aligned_offset + sf_size
				end

				-- Pad struct to alignment
				local struct_final_size = math.ceil(struct_offset / struct_max_align) * struct_max_align

				if struct_final_size > struct_offset then
					struct_code = struct_code .. string.format("    char _pad_end[%d];\n", struct_final_size - struct_offset)
				end

				struct_code = struct_code .. "}"
				-- Store the struct definition without the struct keyword
				table.insert(struct_definitions, struct_code)
				-- Use '$' as a placeholder for the nested ctype
				ffi_type = "$"
				base_size = nil
				-- Calculate struct size and alignment for parent
				local base_alignment = struct_max_align
				local size = struct_final_size

				if info.array_size then size = size * info.array_size end

				max_alignment = math.max(max_alignment, base_alignment)
				local aligned_offset = math.ceil(current_offset / base_alignment) * base_alignment

				if aligned_offset > current_offset then
					ffi_code = ffi_code .. string.format("    char _pad_%d[%d];\n", current_offset, aligned_offset - current_offset)
				end

				if info.array_size then
					ffi_code = ffi_code .. string.format("    %s %s[%d];\n", ffi_type, info.name, info.array_size)
				else
					ffi_code = ffi_code .. string.format("    %s %s;\n", ffi_type, info.name)
				end

				current_offset = aligned_offset + size
			else
				local base_alignment, size = get_layout_info(layout, info.glsl_type, info.array_size)
				max_alignment = math.max(max_alignment, base_alignment)
				local aligned_offset = math.ceil(current_offset / base_alignment) * base_alignment

				if aligned_offset > current_offset then
					ffi_code = ffi_code .. string.format("    char _pad_%d[%d];\n", current_offset, aligned_offset - current_offset)
				end

				if info.array_size and base_size and base_size > 1 then
					ffi_code = ffi_code .. string.format("    %s %s[%d][%d];\n", ffi_type, info.name, info.array_size, base_size)
				elseif info.array_size or (base_size and base_size > 1) then
					ffi_code = ffi_code .. string.format("    %s %s[%d];\n", ffi_type, info.name, info.array_size or base_size)
				else
					ffi_code = ffi_code .. string.format("    %s %s;\n", ffi_type, info.name)
				end

				current_offset = aligned_offset + size
			end
		end

		local final_size = math.ceil(current_offset / max_alignment) * max_alignment

		if final_size > current_offset then
			ffi_code = ffi_code .. string.format("    char _pad_end[%d];\n", final_size - current_offset)
		end

		ffi_code = ffi_code .. "}"

		-- Prepend struct definitions
		if #struct_definitions > 0 then
			ffi_code = table.concat(struct_definitions, "\n") .. "\n" .. ffi_code
		end

		return ffi_code
	end

	local struct_glsl_counter = 0

	local function build_glsl_fields(fields)
		local glsl_fields = ""
		local struct_definitions = {}

		for _, field in ipairs(fields) do
			local info = get_field_info(field)
			local type_name = info.glsl_type

			-- Handle struct types
			if info.is_struct then
				local struct_name = info.name .. "_t"
				local struct_code = "struct " .. struct_name .. " {\n"

				for _, struct_field in ipairs(info.glsl_type) do
					local sf_name = struct_field[1]
					local sf_type = struct_field[2]
					local sf_array_size = struct_field[3]

					if sf_array_size then
						struct_code = struct_code .. string.format("    %s %s[%d];\n", sf_type, sf_name, sf_array_size)
					else
						struct_code = struct_code .. string.format("    %s %s;\n", sf_type, sf_name)
					end
				end

				struct_code = struct_code .. "};\n"
				table.insert(struct_definitions, struct_code)
				type_name = struct_name
			end

			if info.array_size then
				glsl_fields = glsl_fields .. string.format("    %s %s[%d];\n", type_name, info.name, info.array_size)
			else
				glsl_fields = glsl_fields .. string.format("    %s %s;\n", type_name, info.name)
			end
		end

		-- Prepend struct definitions
		return glsl_fields, table.concat(struct_definitions, "")
	end

	-- Process push constants and uniform buffers
	-- First pass: Collect all unique push constant blocks across all stages to assign shared offsets
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = config[stage_name] or
			(
				stage_name == "mesh_ext" and
				config.mesh
			)
			or
			(
				stage_name == "task_ext" and
				config.task
			)

		if type(stage_config) == "table" and stage_config.push_constants then
			for _, block in ipairs(stage_config.push_constants) do
				if not push_constant_blocks[block.name] then
					block.block = flatten_fields(block.block)
					push_constant_blocks[block.name] = block
					table.insert(push_constant_block_order, block.name)
					local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
					local ffi_code = build_ffi_struct("scalar", block.block)
					local ctype = ffi.typeof(ffi_code)
					verify_layout("scalar", struct_name, block.block, ctype)
					push_constant_types[struct_name] = ctype
					push_constant_block_offsets[block.name] = 0 -- placeholder
				end
			end
		end
	end

	-- Assign offsets sequentially based on order of appearance in possible_stages
	local current_push_offset = 0

	for _, name in ipairs(push_constant_block_order) do
		push_constant_block_offsets[name] = current_push_offset
		local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
		current_push_offset = current_push_offset + ffi.sizeof(push_constant_types[struct_name])
	end

	for stage_name, stage_config in pairs(config) do
		if
			type(stage_config) ~= "table" or
			stage_name == "rasterizer" or
			stage_name == "color_blend" or
			stage_name == "multisampling" or
			stage_name == "depth_stencil"
		then
			goto continue
		end

		-- Process uniform buffers
		if stage_config.uniform_buffers then
			for _, block in ipairs(stage_config.uniform_buffers) do
				block.block = flatten_fields(block.block)

				if not block.block[1] then
					error("Uniform buffer " .. block.name .. " has no fields!")
				end

				local ffi_code = build_ffi_struct("scalar", block.block)
				local glsl_fields, glsl_structs = build_glsl_fields(block.block)
				local ubo = UniformBuffer.New(ffi_code)
				verify_layout("scalar", block.name, block.block, ubo.struct)
				local glsl_declaration = string.format(
					"%slayout(scalar, binding = %d) uniform %s {\n%s} %s;",
					glsl_structs,
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
		local stage_config = config[stage] or
			(
				stage == "mesh_ext" and
				config.mesh
			)
			or
			(
				stage == "task_ext" and
				config.task
			)

		if not stage_config or not stage_config.push_constants then return "" end

		local blocks = stage_config.push_constants
		local str = ""

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			local glsl_fields, glsl_structs = build_glsl_fields(block.block)
			str = str .. glsl_structs .. "struct " .. struct_name .. " {\n" .. glsl_fields .. "};\n\n"
		end

		str = str .. "layout(push_constant, scalar) uniform Constants {\n"

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			local offset = push_constant_block_offsets[block.name]
			str = str .. "    layout(offset = " .. offset .. ") " .. struct_name .. " " .. block.name .. ";\n"
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

	local active_stages = {}

	for _, s in ipairs(possible_stages) do
		local stage_config = config[s] or
			(
				s == "mesh_ext" and
				config.mesh
			)
			or
			(
				s == "task_ext" and
				config.task
			)

		if stage_config then
			-- Only consider it an active shader stage if it has a shader or if it's vertex/fragment (which might have default shaders in some systems, but here we check for .shader)
			-- Actually, for vertex we only add it if .shader is present now.
			if stage_config.shader then table.insert(active_stages, s) end
		end
	end

	function self:UploadConstants(cmd)
		for _, name in ipairs(push_constant_block_order) do
			local offset = push_constant_block_offsets[name]
			local block = push_constant_blocks[name]
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			local constants = constant_structs[struct_name]

			for i, field in ipairs(block.block) do
				local info = get_field_info(field)

				if info.callback then
					local result = info.callback(self, constants, info.name)

					-- If callback returns a function, use that for future updates
					if type(result) == "function" then field[3] = result end
				end
			end

			self.pipeline:PushConstants(cmd, active_stages, offset, constants)
		end

		-- Update uniform buffers
		for name, info in pairs(uniform_buffer_types) do
			local ubo_data = info.ubo:GetData()

			for i, field in ipairs(info.block.block) do
				local field_info = get_field_info(field)

				if field_info.callback then
					local result = field_info.callback(self, ubo_data, field_info.name)

					-- If callback returns a function, use that for future updates
					if type(result) == "function" then field[3] = result end
				end
			end

			info.ubo:Upload()
		end
	end

	local glsl_to_lua_type = {
		mat4 = ffi.typeof("float[16]"),
		vec4 = ffi.typeof("float[4]"),
		vec3 = ffi.typeof("float[3]"),
		vec2 = ffi.typeof("float[2]"),
		float = ffi.typeof("float"),
		int = ffi.typeof("int"),
		ivec4 = ffi.typeof("int[4]"),
		ivec3 = ffi.typeof("int[3]"),
		ivec2 = ffi.typeof("int[2]"),
		uint64_t = ffi.typeof("uint64_t"),
	}
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
					lua_name = attribute[1],
					lua_type = glsl_to_lua_type[attribute[2]],
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
	local shader_header = [[#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require

	layout(binding = 0) uniform sampler2D textures[1024];
	layout(binding = 1) uniform samplerCube cubemaps[1024];
	#define TEXTURE(idx) textures[nonuniformEXT(idx)]
	#define CUBEMAP(idx) cubemaps[nonuniformEXT(idx)]
]]

	if config.mesh or config.mesh_ext or config.task or config.task_ext then
		shader_header = shader_header .. "#extension GL_EXT_mesh_shader : require\n"
	end

	local vertex_input = ""
	local vertex_output = ""

	if config.vertex and config.vertex.attributes then
		for i, attr in ipairs(config.vertex.attributes) do
			vertex_input = vertex_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
			vertex_output = vertex_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
		end
	end

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

	-- Add uniform buffers from and descriptors from all stages
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = config[stage_name]

		if type(stage_config) == "table" then
			if stage_config.descriptor_sets then
				for _, desc in ipairs(stage_config.descriptor_sets) do
					if type(desc.args) == "function" then desc.args = desc.args() end

					table.insert(descriptor_sets, desc)
				end
			end

			if stage_config.uniform_buffers then
				for _, block in ipairs(stage_config.uniform_buffers) do
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
		end
	end

	-- Build shader stages
	local shader_stages = {}
	local push_constant_info = nil

	if #push_constant_block_order > 0 then
		push_constant_info = {
			offset = 0,
			size = current_push_offset,
		}
	end

	-- Task stage
	local task_config = config.task_ext or config.task

	if task_config then
		local task_code = shader_header:gsub("#version 450", "#version 450\n#pragma shader_stage(task)") .. (
				task_config.custom_declarations or
				""
			) .. get_glsl_push_constants("task_ext") .. get_glsl_uniform_buffers("task_ext") .. (
				task_config.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "task_ext",
				code = task_code,
				descriptor_sets = descriptor_sets,
				push_constants = task_config.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Mesh stage
	local mesh_config = config.mesh_ext or config.mesh

	if mesh_config then
		local mesh_code = shader_header:gsub("#version 450", "#version 450\n#pragma shader_stage(mesh)") .. (
				mesh_config.custom_declarations or
				""
			) .. get_glsl_push_constants("mesh_ext") .. get_glsl_uniform_buffers("mesh_ext") .. (
				mesh_config.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "mesh_ext",
				code = mesh_code,
				descriptor_sets = descriptor_sets,
				push_constants = mesh_config.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Vertex stage
	if config.vertex and config.vertex.shader then
		local vertex_code = shader_header .. vertex_input .. vertex_output .. get_glsl_push_constants("vertex") .. get_glsl_uniform_buffers("vertex") .. (
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
				descriptor_sets = descriptor_sets,
				bindings = bindings,
				attributes = attributes,
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
				push_constants = config.vertex.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Fragment stage
	if config.fragment then
		local fragment_code = shader_header .. vertex_input .. fragment_outputs .. (
				config.fragment.custom_declarations or
				""
			) .. get_glsl_push_constants("fragment") .. get_glsl_uniform_buffers("fragment") .. (
				config.fragment.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "fragment",
				code = fragment_code,
				descriptor_sets = descriptor_sets,
				push_constants = config.fragment.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Create pipeline
	local pipeline_config = {
		color_format = #actual_color_formats > 0 and actual_color_formats or config.color_format,
		depth_format = config.depth_format,
		samples = config.samples or "1",
		descriptor_set_count = config.descriptor_set_count or (render.target and render.target.image_count) or 1,
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
	self.debug_views = debug_views
	self.config = config
	self.actual_color_formats = actual_color_formats

	-- Create framebuffer(s) if this pipeline has color or depth outputs
	if
		not config.dont_create_framebuffers and
		(
			#self.actual_color_formats > 0 or
			config.depth_format
		)
	then
		self:RecreateFramebuffers()
		self:AddGlobalEvent("WindowFramebufferResized")
	end

	return self
end

function EasyPipeline:RecreateFramebuffers()
	local framebuffer_count = self.config.framebuffer_count or 1
	local size = render.GetRenderImageSize()

	if self.framebuffers then
		for _, fb in ipairs(self.framebuffers) do
			fb:Remove()
		end

		self.framebuffers = nil
	elseif self.framebuffer then
		self.framebuffer:Remove()
		self.framebuffer = nil
	end

	if framebuffer_count == 1 then
		-- Single framebuffer (backward compatible)
		self.framebuffer = Framebuffer.New(
			{
				width = size.x,
				height = size.y,
				formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
				depth = self.config.depth_format ~= nil,
				depth_format = self.config.depth_format,
			}
		)
	else
		-- Multiple framebuffers (ping-pong)
		self.framebuffers = {}

		for i = 1, framebuffer_count do
			self.framebuffers[i] = Framebuffer.New(
				{
					width = size.x,
					height = size.y,
					formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
					depth = self.config.depth_format ~= nil,
					depth_format = self.config.depth_format,
				}
			)
		end

		-- Also set first one as default for backward compatibility
		self.framebuffer = self.framebuffers[1]
	end
end

function EasyPipeline:OnWindowFramebufferResized()
	if render.target and render.target.config.offscreen then return end

	self:RecreateFramebuffers()
	-- Update descriptor sets if they reference framebuffer textures
	local textures = {}
	local fb = self.framebuffer

	if fb then
		for _, tex in ipairs(fb.color_textures or {}) do
			table.insert(textures, tex)
		end

		if fb.depth_texture then table.insert(textures, fb.depth_texture) end

		if #textures > 0 then
			for i = 1, #self.pipeline.descriptor_sets do
				self.pipeline:UpdateDescriptorSetArray(i, 0, textures)
			end
		end
	end
end

function EasyPipeline:Bind(cmd, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	frame_index = frame_index or render.GetCurrentFrame()
	self.pipeline:Bind(cmd, frame_index)
end

function EasyPipeline:GetDebugViews()
	return self.debug_views
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

function EasyPipeline:GetFramebuffer(index)
	if index then
		return self.framebuffers and self.framebuffers[index] or self.framebuffer
	end

	return self.framebuffer
end

-- Begin drawing to this pipeline's framebuffer
-- framebuffer: optional custom framebuffer to use (defaults to pipeline's framebuffer)
-- frame_index: optional frame index for ping-pong buffers (defaults to auto-calculated)
function EasyPipeline:BeginDraw(cmd, framebuffer, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	local fb = framebuffer

	if not fb then
		if frame_index then
			fb = self:GetFramebuffer(frame_index)
		elseif self.framebuffers then
			fb = self:GetFramebuffer(system.GetFrameNumber() % #self.framebuffers + 1)
		else
			fb = self.framebuffer
		end
	end

	if fb then fb:Begin(cmd) end

	-- Set cull mode from config if specified
	if self.config and self.config.rasterizer and self.config.rasterizer.cull_mode then
		cmd:SetCullMode(self.config.rasterizer.cull_mode)
	end

	self:Bind(cmd)
	return fb
end

-- End drawing (must be paired with BeginDraw)
function EasyPipeline:EndDraw(cmd, framebuffer)
	cmd = cmd or render.GetCommandBuffer()

	if framebuffer then framebuffer:End(cmd) end
end

-- Complete draw call with automatic framebuffer handling
-- framebuffer: optional custom framebuffer to use
-- frame_index: optional frame index for ping-pong buffers
-- vertex_count: optional vertex count (defaults to 3 for fullscreen quad)
function EasyPipeline:Draw(cmd, framebuffer, frame_index, vertex_count)
	cmd = cmd or render.GetCommandBuffer()
	vertex_count = vertex_count or 3
	local fb = self:BeginDraw(cmd, framebuffer, frame_index)

	if self.on_draw then
		self.on_draw(self, cmd)
	else
		self:UploadConstants(cmd)
		cmd:Draw(vertex_count, 1, 0, 0)
	end

	self:EndDraw(cmd, fb)
end

function EasyPipeline:DrawMeshTasks(gx, gy, gz, cmd, framebuffer, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	local fb = self:BeginDraw(cmd, framebuffer, frame_index)
	self:UploadConstants(cmd)
	cmd:DrawMeshTasks(gx, gy, gz)
	self:EndDraw(cmd, fb)
end

function EasyPipeline.FragmentOnly(config)
	return EasyPipeline.New(
		{
			color_format = config.color_format,
			samples = "1",
			rasterizer = {
				cull_mode = "none",
			},
			vertex = {
				shader = [[
				vec2 positions[3] = vec2[](vec2(-1.0, -1.0), vec2( 3.0, -1.0), vec2(-1.0,  3.0));
				layout(location = 0) out vec2 out_uv;
				void main() {
					vec2 pos = positions[gl_VertexIndex];
					gl_Position = vec4(pos, 0.0, 1.0);
					out_uv = pos * 0.5 + 0.5;
				}
			]],
			},
			fragment = {
				push_constants = {{
					name = "fragment",
					block = config.block,
				}},
				shader = config.shader,
			},
		}
	)
end

return EasyPipeline:Register()
