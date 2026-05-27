local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local upload_probe = import("goluwa/render/upload_probe.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local EasyPipeline = prototype.CreateTemplate("render_easy_pipeline")
local LEGACY_TOP_LEVEL_FIELD_NAMES = {
	color_format = "ColorFormat",
	depth_format = "DepthFormat",
	samples = "RasterizationSamples",
	rasterization_samples = "RasterizationSamples",
	descriptor_set_count = "DescriptorSetCount",
}
local FIELD_TYPE_BYTE_SIZE = {
	float = 4,
	int = 4,
	bool = 4,
	boolean = 4,
	vec2 = 8,
	vec3 = 12,
	vec4 = 16,
	ivec2 = 8,
	ivec3 = 12,
	ivec4 = 16,
	mat4 = 64,
	uint64_t = 8,
}

local function assert_no_legacy_top_level_fields(config, level)
	for field_name, public_name in pairs(LEGACY_TOP_LEVEL_FIELD_NAMES) do
		if config[field_name] ~= nil then
			error(
				string.format(
					"EasyPipeline.New: use PascalCase %s instead of snake_case %s",
					public_name,
					field_name
				),
				level or 3
			)
		end
	end

	if config.Samples ~= nil then
		error("EasyPipeline.New: use RasterizationSamples instead of Samples", level or 3)
	end
end

local function assert_no_dynamic_state_config(config)
	if
		config.dynamic_state ~= nil or
		config.dynamic_states ~= nil or
		config.DynamicStates ~= nil
	then
		error("EasyPipeline.New: dynamic state is handled internally", 3)
	end
end

local function get_nested_property_path(info)
	local path = info.path:split(".")

	if
		path[1] == "color_blend" and
		path[3] == nil and
		path[2] ~= "logic_op_enabled" and
		path[2] ~= "logic_op" and
		path[2] ~= "constants"
	then
		return {"color_blend", "attachments", 1, path[2]},
		"color_blend.attachments[1]." .. path[2]
	end

	return path, info.path
end

local function has_nested_value(tbl, path)
	local value = tbl

	for i = 1, #path do
		if type(value) ~= "table" then return false end

		value = value[path[i]]

		if value == nil then return false end
	end

	return true
end

local function assert_no_nested_property_config(config)
	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		local path, path_string = get_nested_property_path(info)

		if has_nested_value(config, path) then
			error(
				string.format(
					"EasyPipeline.New: use top-level PascalCase property %s instead of nested %s",
					info.var_name,
					path_string
				),
				3
			)
		end
	end

	if
		type(config.multisampling) == "table" and
		config.multisampling.rasterization_samples ~= nil
	then
		error(
			"EasyPipeline.New: use top-level PascalCase property Samples instead of nested multisampling.rasterization_samples",
			3
		)
	end
end

local function get_scalar_field_size(field)
	local field_type = field[2]
	local field_size

	if type(field_type) == "table" then
		field_size = ffi.sizeof(ffi.typeof(EasyPipeline.BuildFFIType("scalar", "ProbeField", field_type)))
	else
		field_size = FIELD_TYPE_BYTE_SIZE[field_type]
	end

	assert(field_size, "unknown scalar field size for type " .. tostring(field_type))

	if type(field[3]) == "number" then field_size = field_size * field[3] end

	return field_size
end

local function build_field_descriptors(struct_ctype, fields)
	local descriptors = {}

	for i = 1, #fields do
		local field = fields[i]
		descriptors[i] = {
			name = field[1],
			offset = ffi.offsetof(struct_ctype, field[1]),
			size = get_scalar_field_size(field),
		}
	end

	return descriptors
end

for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
	EasyPipeline[info.set_name] = function(self, ...)
		return self.pipeline[info.set_name](self.pipeline, ...)
	end
	EasyPipeline[info.get_name] = function(self, ...)
		return self.pipeline[info.get_name](self.pipeline, ...)
	end
end

function EasyPipeline.GetColorFormats(config)
	local formats = {}
	local color_format = config.ColorFormat

	if type(color_format) == "function" then color_format = color_format() end

	if type(color_format) == "table" then
		for i, format in ipairs(color_format) do
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

function EasyPipeline.BuildFFIType(layout, struct_name, fields)
	layout = layout or "scalar"
	struct_name = struct_name or "AnonymousLayout"
	fields = fields or {}
	local glsl_to_ffi = {
		mat4 = "float",
		vec4 = "float",
		vec3 = "float",
		vec2 = "float",
		float = "float",
		bool = "int",
		boolean = "int",
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
	local struct_counter = 0

	local function flatten_fields(input_fields, out)
		out = out or {}

		for _, field in ipairs(input_fields) do
			if type(field[1]) == "table" then
				flatten_fields(field, out)
			else
				out[#out + 1] = field
			end
		end

		return out
	end

	local function get_field_info(field)
		local glsl_type = field[2]
		local array_size = type(field[3]) == "number" and field[3] or nil
		return {
			name = field[1],
			glsl_type = glsl_type,
			array_size = array_size,
			is_struct = type(glsl_type) == "table",
		}
	end

	local function get_layout_info(inner_layout, glsl_type, array_size)
		local base_alignment = 4
		local size = 4

		if type(glsl_type) == "table" then
			local struct_size = 0
			local max_alignment = 4

			for _, field in ipairs(glsl_type) do
				local field_alignment, field_size = get_layout_info(inner_layout, field[2], field[3])
				max_alignment = math.max(max_alignment, field_alignment)
				struct_size = math.ceil(struct_size / field_alignment) * field_alignment
				struct_size = struct_size + field_size
			end

			struct_size = math.ceil(struct_size / max_alignment) * max_alignment
			base_alignment = max_alignment
			size = struct_size
		elseif
			glsl_type == "float" or
			glsl_type == "int" or
			glsl_type == "bool" or
			glsl_type == "boolean"
		then
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

		if inner_layout == "scalar" then
			if
				glsl_type == "vec2" or
				glsl_type == "vec3" or
				glsl_type == "vec4" or
				glsl_type == "mat4"
			then
				base_alignment = 4
			end
		end

		if inner_layout == "std140" then
			if array_size then
				base_alignment = math.max(base_alignment, 16)
				size = math.max(size, 16) * array_size
			end
		elseif array_size then
			size = size * array_size
		end

		return base_alignment, size
	end

	local function build_ffi_struct(inner_layout, input_fields)
		local ffi_code = "struct __attribute__((packed)) {\n"
		local current_offset = 0
		local max_alignment = 16
		local struct_definitions = {}

		for _, field in ipairs(input_fields) do
			local info = get_field_info(field)
			local ffi_type = glsl_to_ffi[info.glsl_type] or info.glsl_type
			local base_size = glsl_to_array_size[info.glsl_type]

			if info.is_struct then
				struct_counter = struct_counter + 1
				local struct_code = "struct __attribute__((packed)) {\n"
				local struct_offset = 0
				local struct_max_align = 4

				for _, struct_field in ipairs(info.glsl_type) do
					local sf_name = struct_field[1]
					local sf_type = struct_field[2]
					local sf_array_size = struct_field[3]
					local sf_ffi_type = glsl_to_ffi[sf_type] or sf_type
					local sf_base_size = glsl_to_array_size[sf_type]
					local sf_base_alignment, sf_size = get_layout_info(inner_layout, sf_type, sf_array_size)
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

				local struct_final_size = math.ceil(struct_offset / struct_max_align) * struct_max_align

				if struct_final_size > struct_offset then
					struct_code = struct_code .. string.format("    char _pad_end[%d];\n", struct_final_size - struct_offset)
				end

				struct_code = struct_code .. "}"
				struct_definitions[#struct_definitions + 1] = struct_code
				ffi_type = "$"
				base_size = nil
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
				local base_alignment, size = get_layout_info(inner_layout, info.glsl_type, info.array_size)
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

		if #struct_definitions > 0 then
			ffi_code = table.concat(struct_definitions, "\n") .. "\n" .. ffi_code
		end

		return ffi_code
	end

	local function verify_layout(inner_layout, name, input_fields, ctype)
		local current_offset = 0
		local max_alignment = (inner_layout == "std140" or inner_layout == "std430") and 16 or 4

		for _, field in ipairs(input_fields) do
			local info = get_field_info(field)
			local base_alignment, size = get_layout_info(inner_layout, info.glsl_type, info.array_size)
			max_alignment = math.max(max_alignment, base_alignment)
			current_offset = math.ceil(current_offset / base_alignment) * base_alignment
			local ffi_offset = tonumber(ffi.offsetof(ctype, info.name))

			if ffi_offset ~= current_offset then
				error(
					string.format(
						"Uniform buffer/Push constant '%s' field '%s' has incorrect alignment for layout '%s'!\nGLSL expected offset: %d\nFFI (C) actual offset: %d\nType: %s%s",
						name,
						info.name,
						inner_layout,
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

		if inner_layout == "std140" then
			expected_total_size = math.ceil(expected_total_size / 16) * 16
		end

		if ffi.sizeof(ctype) < expected_total_size then
			error(
				string.format(
					"Uniform buffer/Push constant '%s' has incorrect total size for layout '%s'!\nGLSL expected size: %d\nFFI (C) actual size: %d\nFFI (C) actual alignment: %d",
					name,
					inner_layout,
					expected_total_size,
					ffi.sizeof(ctype),
					ffi.alignof(ctype)
				)
			)
		end
	end

	local flat_fields = flatten_fields(fields)
	local ctype = ffi.typeof(build_ffi_struct(layout, flat_fields))
	verify_layout(layout, struct_name, flat_fields, ctype)
	return ctype
end

local function get_scalar_layout_alignment(glsl_type)
	if type(glsl_type) == "table" then
		local max_alignment = 4

		for _, field in ipairs(glsl_type) do
			max_alignment = math.max(max_alignment, get_scalar_layout_alignment(field[2]))
		end

		return max_alignment
	end

	if glsl_type == "uint64_t" then return 8 end

	return 4
end

local function get_scalar_block_alignment(fields)
	local max_alignment = 4

	for _, field in ipairs(fields) do
		max_alignment = math.max(max_alignment, get_scalar_layout_alignment(field[2]))
	end

	return max_alignment
end

local function align_offset(offset, alignment)
	return math.ceil(offset / alignment) * alignment
end

local function get_constant_stage_config(config, stage_name)
	return config[stage_name] or
		(
			stage_name == "mesh_ext" and
			config.mesh
		)
		or
		(
			stage_name == "task_ext" and
			config.task
		)
end

local function clone_constant_block(block)
	local copy = {}

	for key, value in pairs(block) do
		copy[key] = value
	end

	return copy
end

local function hoist_inline_block_metadata(block)
	local inline_block = block.block

	if type(inline_block) ~= "table" then return end

	if block.write == nil and inline_block.write ~= nil then
		block.write = inline_block.write
	end

	if block.source == nil and inline_block.source ~= nil then
		block.source = inline_block.source
	end
end

local function normalize_block_source(block, size, alignment, kind)
	local source = block.source

	if source == nil then return nil end

	if source._normalized then return source end

	if type(source) ~= "table" then
		error(
			string.format("EasyPipeline.New: %s '%s' source must be a table", kind, tostring(block.name)),
			3
		)
	end

	if type(source.get) ~= "function" then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source.get must be a function",
				kind,
				tostring(block.name)
			),
			3
		)
	end

	local source_ctype = source.ctype or source.struct

	if not source_ctype then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source must provide ctype or struct",
				kind,
				tostring(block.name)
			),
			3
		)
	end

	if source.field ~= nil and source.offset ~= nil then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source must specify either field or offset, not both",
				kind,
				tostring(block.name)
			),
			3
		)
	end

	local offset = 0

	if source.field ~= nil then
		local ok, resolved_offset = pcall(ffi.offsetof, source_ctype, source.field)

		if not ok then
			error(
				string.format(
					"EasyPipeline.New: %s '%s' source field '%s' is invalid",
					kind,
					tostring(block.name),
					tostring(source.field)
				),
				3
			)
		end

		offset = tonumber(resolved_offset)
	else
		offset = tonumber(source.offset) or 0
	end

	if offset < 0 then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source offset must be >= 0",
				kind,
				tostring(block.name)
			),
			3
		)
	end

	local source_size = ffi.sizeof(source_ctype)

	if offset + size > source_size then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source slice [%d, %d) exceeds source size %d",
				kind,
				tostring(block.name),
				offset,
				offset + size,
				source_size
			),
			3
		)
	end

	if offset % math.max(alignment or 1, 1) ~= 0 then
		error(
			string.format(
				"EasyPipeline.New: %s '%s' source offset %d is not aligned to %d bytes",
				kind,
				tostring(block.name),
				offset,
				alignment or 1
			),
			3
		)
	end

	local normalized = clone_constant_block(source)
	normalized.ctype = source_ctype
	normalized.offset = offset
	normalized.size = source_size
	normalized._normalized = true
	return normalized
end

local function escape_lua_pattern(str)
	return (str:gsub("([^%w])", "%%%1"))
end

local function build_passthrough_vertex_shader(vertex_config, shader_outputs, shader_inputs)
	local passthrough = vertex_config.passthrough

	if not passthrough then return nil end

	local logical_inputs = vertex_config.attributes

	if not logical_inputs and vertex_config.bindings then
		logical_inputs = {}

		for _, binding in ipairs(vertex_config.bindings) do
			for _, attribute in ipairs(binding.attributes or {}) do
				logical_inputs[#logical_inputs + 1] = attribute
			end
		end
	end

	local position = assert(
		passthrough.position,
		"EasyPipeline.New: vertex.passthrough.position is required when vertex.shader is omitted"
	)

	for _, attribute in ipairs(logical_inputs or {}) do
		if attribute[2] == "mat4" then
			position = position:gsub(
				"%f[%a_]" .. escape_lua_pattern("in_" .. attribute[1]) .. "%f[^%w_]",
				string.format(
					"mat4(in_%s_row_0, in_%s_row_1, in_%s_row_2, in_%s_row_3)",
					attribute[1],
					attribute[1],
					attribute[1],
					attribute[1]
				)
			)
		end
	end

	local input_names = {}
	local lines = {
		"void main() {",
		"\tgl_Position = " .. position .. ";",
	}
	local fields = passthrough.fields or shader_outputs

	for _, attribute in ipairs(shader_inputs) do
		input_names[attribute[1]] = true
	end

	for _, field in ipairs(fields) do
		local name = type(field) == "table" and field[1] or field

		if not input_names[name] then
			error(
				"EasyPipeline.New: vertex.passthrough field '" .. tostring(name) .. "' has no matching input",
				3
			)
		end

		lines[#lines + 1] = "\tout_" .. name .. " = in_" .. name .. ";"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function build_fragment_adapter_declaration(adapter)
	if adapter.kind == "function" then
		return string.format(
			"%s %s() {\n\treturn %s;\n}",
			adapter.return_type,
			adapter.symbol,
			adapter.expr
		)
	end

	return string.format("#define %s %s", adapter.symbol, adapter.expr)
end

local function normalize_fragment_adapter(adapter)
	if adapter.kind then return adapter end

	local source = assert(adapter[1], "EasyPipeline.New: fragment adapter source is required")
	local target = assert(adapter[2], "EasyPipeline.New: fragment adapter target is required")
	local expr = assert(adapter[3], "EasyPipeline.New: fragment adapter expression is required")
	local normalized = {
		expr = expr,
		pattern = escape_lua_pattern(source),
	}

	if type(target) == "table" then
		normalized.kind = "function"
		normalized.return_type = assert(target[1], "EasyPipeline.New: fragment adapter function return type is required")
		normalized.symbol = assert(target[2], "EasyPipeline.New: fragment adapter function symbol is required")
		normalized.replacement = normalized.symbol .. "()"
	else
		normalized.kind = "define"
		normalized.symbol = target
		normalized.replacement = target
	end

	return normalized
end

local function build_fragment_shader(fragment_config)
	local adapters = fragment_config.adapters
	local shader = fragment_config.shader or ""

	if not adapters or #adapters == 0 then return shader end

	local declarations = {}

	for _, adapter in ipairs(adapters) do
		adapter = normalize_fragment_adapter(adapter)
		declarations[#declarations + 1] = build_fragment_adapter_declaration(adapter)
		shader = shader:gsub(adapter.pattern, adapter.replacement)
	end

	return table.concat(declarations, "\n") .. "\n" .. shader
end

function EasyPipeline.New(config)
	assert_no_legacy_top_level_fields(config)
	assert_no_dynamic_state_config(config)
	assert_no_nested_property_config(config)
	local self = EasyPipeline:CreateObject()
	self.on_draw = config.on_draw or nil
	local color_format = config.ColorFormat
	local depth_format = config.DepthFormat
	local rasterization_samples = config.RasterizationSamples
	local descriptor_set_count = config.DescriptorSetCount

	-- Resolve format functions if they exist
	if type(color_format) == "function" then color_format = color_format() end

	if type(depth_format) == "function" then depth_format = depth_format() end

	if type(rasterization_samples) == "function" then
		rasterization_samples = rasterization_samples()
	end

	config.ColorFormat = color_format
	config.DepthFormat = depth_format
	config.RasterizationSamples = rasterization_samples
	config.DescriptorSetCount = descriptor_set_count

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
	if type(color_format) == "table" then
		for i, format in ipairs(color_format) do
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
		bool = "int",
		boolean = "int",
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
	local possible_stages = {
		"task_ext",
		"mesh_ext",
		"vertex",
		"tessellation_control",
		"tessellation_evaluation",
		"fragment",
		"compute",
	}
	local push_constant_blocks = {}
	local push_constant_block_order = {}
	local push_constant_block_offsets = {}
	local uniform_buffer_types = {}
	local uniform_buffers = {}
	local actual_color_formats = {}
	local fragment_outputs = ""
	local debug_views = {}
	local color_formats = color_format

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
		local array_size = type(field[3]) == "number" and field[3] or nil
		local is_struct = type(glsl_type) == "table"
		return {
			name = name,
			glsl_type = glsl_type,
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
		elseif
			glsl_type == "float" or
			glsl_type == "int" or
			glsl_type == "bool" or
			glsl_type == "boolean"
		then
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

	local function resolve_stage_constants()
		local placement = config.ConstantPlacement or {}
		local push_budget = placement.push_budget

		if push_budget == nil or push_budget == "device" then
			push_budget = render.GetDevice().physical_device:GetProperties().limits.maxPushConstantsSize
		end

		push_budget = assert(
			tonumber(push_budget),
			"EasyPipeline.New: ConstantPlacement.push_budget must be a number or 'device'"
		)
		push_budget = push_budget - math.max(0, tonumber(placement.reserve_push_bytes) or 0)

		if push_budget < 0 then push_budget = 0 end

		local fallback_storage = placement.fallback or "uniform_buffer"
		local default_mode = placement.mode or "auto"
		local constant_blocks = {}
		local auto_blocks = {}
		local explicit_push_span = 0
		local hard_push_size = 0
		local constant_order = 0
		local seen_explicit_push_blocks = {}

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, stage_name)

			if type(stage_config) == "table" and stage_config.push_constants then
				for _, block in ipairs(stage_config.push_constants) do
					if block.name == nil then
						block.name = "_u_" .. stage_name
						block._is_unnamed = true
					end

					if not seen_explicit_push_blocks[block.name] then
						seen_explicit_push_blocks[block.name] = true
						local flat_block = flatten_fields(block.block)
						local alignment = get_scalar_block_alignment(flat_block)
						local ctype = ffi.typeof(build_ffi_struct("scalar", flat_block))
						explicit_push_span = align_offset(explicit_push_span, alignment) + ffi.sizeof(ctype)
					end
				end
			end
		end

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, stage_name)

			if type(stage_config) == "table" and stage_config.constants then
				for _, block in ipairs(stage_config.constants) do
					if block.name == nil then
						block.name = "_c_" .. stage_name
						block._is_unnamed = true
					end

					local resolved = constant_blocks[block.name]

					if not resolved then
						constant_order = constant_order + 1
						resolved = clone_constant_block(block)
						resolved.block = flatten_fields(resolved.block)
						resolved._constant_order = constant_order
						resolved._requested_storage = resolved.storage or default_mode
						resolved._preferred_storage = resolved.prefer or "push"
						resolved._priority = tonumber(resolved.priority) or 0
						local struct_name = resolved.name:sub(1, 1):upper() .. resolved.name:sub(2) .. "Constants"
						local ctype = ffi.typeof(build_ffi_struct("scalar", resolved.block))
						verify_layout("scalar", struct_name, resolved.block, ctype)
						resolved._size = ffi.sizeof(ctype)
						resolved._alignment = get_scalar_block_alignment(resolved.block)
						resolved.source = normalize_block_source(resolved, resolved._size, resolved._alignment, "constant block")
						constant_blocks[resolved.name] = resolved

						if resolved._requested_storage == "push" then
							resolved._resolved_storage = "push"
							hard_push_size = hard_push_size + resolved._size
						elseif resolved._requested_storage == "uniform_buffer" then
							resolved._resolved_storage = "uniform_buffer"
						elseif resolved._requested_storage == "auto" then
							table.insert(auto_blocks, resolved)
						else
							error(
								"EasyPipeline.New: invalid constants storage '" .. tostring(resolved._requested_storage) .. "'",
								3
							)
						end
					end
				end
			end
		end

		if explicit_push_span + hard_push_size > push_budget then
			error(
				string.format(
					"EasyPipeline.New: explicit and forced push constant blocks require %d bytes but the configured budget is %d",
					explicit_push_span + hard_push_size,
					push_budget
				),
				3
			)
		end

		table.sort(auto_blocks, function(a, b)
			local a_push = a._preferred_storage == "push" and 1 or 0
			local b_push = b._preferred_storage == "push" and 1 or 0

			if a_push ~= b_push then return a_push > b_push end

			if a._priority ~= b._priority then return a._priority > b._priority end

			if a._size ~= b._size then return a._size < b._size end

			return a._constant_order < b._constant_order
		end)

		local remaining_push_budget = push_budget - explicit_push_span - hard_push_size

		for _, block in ipairs(auto_blocks) do
			if block._size <= remaining_push_budget then
				block._resolved_storage = "push"
				remaining_push_budget = remaining_push_budget - block._size
			elseif fallback_storage == "uniform_buffer" then
				block._resolved_storage = "uniform_buffer"
			else
				error(
					string.format(
						"EasyPipeline.New: constant block '%s' (%d bytes) does not fit in the remaining push constant budget (%d bytes)",
						block.name,
						block._size,
						remaining_push_budget
					),
					3
				)
			end
		end

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, stage_name)

			if type(stage_config) == "table" and stage_config.constants then
				for _, block in ipairs(stage_config.constants) do
					local resolved = assert(constant_blocks[block.name], "missing resolved constant block")
					local target_key = resolved._resolved_storage == "push" and "push_constants" or "uniform_buffers"
					stage_config[target_key] = stage_config[target_key] or {}
					table.insert(stage_config[target_key], resolved)
				end
			end
		end

		return {
			push_budget = push_budget,
			fallback = fallback_storage,
			blocks = constant_blocks,
		}
	end

	local constant_resolution = resolve_stage_constants()

	-- Process push constants and uniform buffers
	-- First pass: Collect all unique push constant blocks across all stages to assign shared offsets
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = get_constant_stage_config(config, stage_name)

		if type(stage_config) == "table" and stage_config.push_constants then
			for _, block in ipairs(stage_config.push_constants) do
				-- Auto-assign a stable internal name for unnamed blocks (stage-specific to avoid collision)
				if block.name == nil then
					block.name = "_u_" .. stage_name
					block._is_unnamed = true
				end

				if not push_constant_blocks[block.name] then
					hoist_inline_block_metadata(block)
					block.block = flatten_fields(block.block)
					push_constant_blocks[block.name] = block
					table.insert(push_constant_block_order, block.name)
					local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
					local ffi_code = build_ffi_struct("scalar", block.block)
					local ctype = ffi.typeof(ffi_code)
					verify_layout("scalar", struct_name, block.block, ctype)
					block.debug_name = (config.name or "pipeline") .. ".pc." .. block.name
					block.field_descriptors = build_field_descriptors(ctype, block.block)
					block.source = normalize_block_source(
						block,
						ffi.sizeof(ctype),
						get_scalar_block_alignment(block.block),
						"push constant block"
					)
					push_constant_types[struct_name] = ctype
					push_constant_block_offsets[block.name] = 0 -- placeholder
				end
			end
		end
	end

	-- Assign offsets sequentially based on order of appearance in possible_stages
	local current_push_offset = 0

	for _, name in ipairs(push_constant_block_order) do
		current_push_offset = align_offset(current_push_offset, get_scalar_block_alignment(push_constant_blocks[name].block))
		push_constant_block_offsets[name] = current_push_offset
		local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
		current_push_offset = current_push_offset + ffi.sizeof(push_constant_types[struct_name])
	end

	if current_push_offset > constant_resolution.push_budget then
		error(
			string.format(
				"EasyPipeline.New: resolved push constant layout requires %d bytes but the configured budget is %d",
				current_push_offset,
				constant_resolution.push_budget
			),
			2
		)
	end

	-- Auto binding index counter starts at 2 (0=textures, 1=cubemaps are reserved)
	local next_auto_binding = 2

	-- Pre-scan all explicit binding indices so auto-assignment skips them
	for _, sc in pairs(config) do
		if type(sc) == "table" and sc.uniform_buffers then
			for _, b in ipairs(sc.uniform_buffers) do
				if b.binding_index and b.binding_index >= next_auto_binding then
					next_auto_binding = b.binding_index + 1
				end
			end
		end
	end

	local uniform_buffer_order = {}

	for _, stage_name in ipairs(possible_stages) do
		local stage_config = get_constant_stage_config(config, stage_name)

		if type(stage_config) ~= "table" then goto continue end

		-- Process uniform buffers
		if stage_config.uniform_buffers then
			for _, block in ipairs(stage_config.uniform_buffers) do
				-- Auto-assign a stable internal name for unnamed blocks (stage-specific to avoid collision)
				if block.name == nil then
					block.name = "_u_" .. stage_name
					block._is_unnamed = true
				end

				-- Auto-assign binding index if not specified
				if block.binding_index == nil then
					local existing = uniform_buffer_types[block.name]

					if existing then
						block.binding_index = existing.block.binding_index
					else
						block.binding_index = next_auto_binding
						next_auto_binding = next_auto_binding + 1
					end
				end

				hoist_inline_block_metadata(block)
				block.block = flatten_fields(block.block)

				if not block.block[1] then
					error("Uniform buffer " .. block.name .. " has no fields!")
				end

				local existing = uniform_buffer_types[block.name]

				if existing then
					if existing.block.binding_index ~= block.binding_index then
						error(
							"Uniform buffer " .. block.name .. " is declared with conflicting binding indices: " .. tostring(existing.block.binding_index) .. " and " .. tostring(block.binding_index)
						)
					end

					goto continue_uniform_buffer
				end

				local ffi_code = build_ffi_struct("scalar", block.block)
				local glsl_fields, glsl_structs = build_glsl_fields(block.block)
				local ubo = UniformBuffer.New(ffi_code)
				verify_layout("scalar", block.name, block.block, ubo.struct)
				block.source = normalize_block_source(
					block,
					ffi.sizeof(ubo.struct),
					get_scalar_block_alignment(block.block),
					"uniform buffer block"
				)
				local block_type_name = block.name:sub(1, 1):upper() .. block.name:sub(2)

				-- Ensure the block type name differs from the instance name (GLSL forbids identical names)
				if block_type_name == block.name then
					block_type_name = block_type_name .. "_t"
				end

				local glsl_declaration = string.format(
					"%slayout(scalar, binding = %d) uniform %s {\n%s} %s;",
					glsl_structs,
					block.binding_index,
					block_type_name,
					glsl_fields,
					block.name
				)
				table.insert(uniform_buffer_order, block.name)
				uniform_buffer_types[block.name] = {
					ubo = ubo,
					block = block,
					glsl = glsl_declaration,
					debug_name = (config.name or "pipeline") .. ".ubo." .. block.name,
					field_descriptors = build_field_descriptors(ubo.struct, block.block),
					offsets = {}, -- Tracks offsets used in the current frame
				}
				uniform_buffers[block.name] = ubo

				::continue_uniform_buffer::
			end
		end

		::continue::
	end

	table.sort(uniform_buffer_order, function(a, b)
		local a_block = uniform_buffer_types[a].block
		local b_block = uniform_buffer_types[b].block
		local a_set = a_block.set_index or 0
		local b_set = b_block.set_index or 0

		if a_set ~= b_set then return a_set < b_set end

		if a_block.binding_index ~= b_block.binding_index then
			return a_block.binding_index < b_block.binding_index
		end

		return a < b
	end)

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

		-- Emit shortcut #defines: named block -> #define name pc.name
		-- unnamed block -> #define U pc._u
		for _, block in ipairs(blocks) do
			if block._is_unnamed then
				str = str .. "#define U pc." .. block.name .. "\n"
			else
				str = str .. "#define " .. block.name .. " pc." .. block.name .. "\n"
			end
		end

		str = str .. "\n"
		return str
	end

	local function get_glsl_uniform_buffers(stage)
		local stage_config = config[stage]

		if not stage_config or not stage_config.uniform_buffers then return "" end

		local glsl = ""

		for _, block in ipairs(stage_config.uniform_buffers) do
			glsl = glsl .. uniform_buffer_types[block.name].glsl .. "\n\n"

			-- Emit #define U for unnamed UBOs
			if block._is_unnamed then
				glsl = glsl .. "#define U " .. block.name .. "\n\n"
			end
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
		local stage_config = get_constant_stage_config(config, s)

		if stage_config then
			-- Only consider it an active shader stage if it has a shader or if it's vertex/fragment (which might have default shaders in some systems, but here we check for .shader)
			-- Actually, for vertex we only add it if .shader is present now.
			if stage_config.shader then table.insert(active_stages, s) end
		end
	end

	local active_stage_key = table.concat(active_stages, "|")
	local push_constant_cache_by_cmd = setmetatable({}, {__mode = "k"})

	local function bytes_equal(lhs, rhs, size)
		for i = 0, size - 1 do
			if lhs[i] ~= rhs[i] then return false end
		end

		return true
	end

	local function ranges_overlap(lhs_offset, lhs_size, rhs_offset, rhs_size)
		return lhs_offset < rhs_offset + rhs_size and rhs_offset < lhs_offset + lhs_size
	end

	local function get_push_constant_entries(cmd)
		local entries = push_constant_cache_by_cmd[cmd]

		if entries then return entries end

		entries = {}
		push_constant_cache_by_cmd[cmd] = entries
		return entries
	end

	local function should_push_constants(cmd, pipeline_key, stage_key, offset, data, size)
		local entries = get_push_constant_entries(cmd)
		local src = ffi.cast("uint8_t *", data)

		for i = 1, #entries do
			local entry = entries[i]

			if
				entry.pipeline_key == pipeline_key and
				entry.stage_key == stage_key and
				entry.offset == offset and
				entry.size == size
			then
				return not bytes_equal(entry.snapshot, src, size)
			end
		end

		return true
	end

	local function note_push_constants(cmd, pipeline_key, stage_key, offset, data, size)
		local entries = get_push_constant_entries(cmd)
		local src = ffi.cast("uint8_t *", data)

		for i = #entries, 1, -1 do
			local entry = entries[i]

			if
				entry.pipeline_key == pipeline_key and
				entry.stage_key == stage_key and
				ranges_overlap(entry.offset, entry.size, offset, size)
			then
				table.remove(entries, i)
			end
		end

		entries[#entries + 1] = {
			pipeline_key = pipeline_key,
			stage_key = stage_key,
			offset = offset,
			size = size,
			snapshot = ffi.new("uint8_t[?]", size),
		}
		ffi.copy(entries[#entries].snapshot, src, size)
	end

	do
		local upload_lines = {
			"local function bytes_equal(lhs, rhs, size)",
			"    for i = 0, size - 1 do",
			"        if lhs[i] ~= rhs[i] then return false end",
			"    end",
			"",
			"    return true",
			"end",
			"",
			"return function(self, cmd, render, ffi, system, upload_probe, active_stages, push_constant_stage_key, should_push_constants, note_push_constants, push_constant_blocks, push_constant_block_offsets, constant_structs, uniform_buffer_order, uniform_buffer_types)",
		}

		for _, name in ipairs(push_constant_block_order) do
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			local offset_expr = string.format("push_constant_block_offsets[%q]", name)
			upload_lines[#upload_lines + 1] = "do"
			upload_lines[#upload_lines + 1] = string.format("    local block = push_constant_blocks[%q]", name)
			upload_lines[#upload_lines + 1] = string.format("    local constants = constant_structs[%q]", struct_name)
			upload_lines[#upload_lines + 1] = string.format("    local offset = %s", offset_expr)
			upload_lines[#upload_lines + 1] = "    local pipeline_key = self.pipeline"
			upload_lines[#upload_lines + 1] = "    if block.source then"
			upload_lines[#upload_lines + 1] = "        local source_data = block.source.get(self, block)"
			upload_lines[#upload_lines + 1] = "        if source_data == nil then error(\"push constant block source returned nil for \" .. tostring(block.name)) end"
			upload_lines[#upload_lines + 1] = "        ffi.copy(constants, ffi.cast(\"uint8_t *\", source_data) + block.source.offset, ffi.sizeof(constants))"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "    if block.write then"
			upload_lines[#upload_lines + 1] = "        block.write(self, constants, block)"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "    if should_push_constants(cmd, pipeline_key, push_constant_stage_key, offset, constants, ffi.sizeof(constants)) then"
			upload_lines[#upload_lines + 1] = "        if upload_probe.IsEnabled() then"
			upload_lines[#upload_lines + 1] = "            upload_probe.RecordUpload(block.debug_name, block.field_descriptors, constants, ffi.sizeof(constants), true)"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = string.format(
				"        self.pipeline:PushConstants(cmd, active_stages, %s, constants)",
				offset_expr
			)
			upload_lines[#upload_lines + 1] = "        note_push_constants(cmd, pipeline_key, push_constant_stage_key, offset, constants, ffi.sizeof(constants))"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "end"
		end

		upload_lines[#upload_lines + 1] = "local offsets = {}"
		upload_lines[#upload_lines + 1] = "local frame_index = render.GetCurrentFrame()"
		upload_lines[#upload_lines + 1] = "local frame_number = system.GetFrameNumber and system.GetFrameNumber() or 0"

		for i, name in ipairs(uniform_buffer_order) do
			upload_lines[#upload_lines + 1] = "do"
			upload_lines[#upload_lines + 1] = string.format("    local info = uniform_buffer_types[%q]", name)
			upload_lines[#upload_lines + 1] = "    local offset = nil"
			upload_lines[#upload_lines + 1] = "    local cache_key = nil"
			upload_lines[#upload_lines + 1] = "    local cache_hit = false"
			upload_lines[#upload_lines + 1] = "    local persistent_entry = nil"
			upload_lines[#upload_lines + 1] = "    local persistent_entries = nil"
			upload_lines[#upload_lines + 1] = "    if info.block.upload_scope == \"frame\" then"
			upload_lines[#upload_lines + 1] = "        cache_key = true"
			upload_lines[#upload_lines + 1] = "    elseif (info.block.upload_scope == \"frame_keyed\" or info.block.upload_scope == \"persistent_keyed\") and info.block.upload_key then"
			upload_lines[#upload_lines + 1] = "        cache_key = info.block.upload_key(self, info.block)"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "    if cache_key ~= nil then"
			upload_lines[#upload_lines + 1] = "        local cache = info.offsets"
			upload_lines[#upload_lines + 1] = "        if info.block.upload_scope == \"frame\" then"
			upload_lines[#upload_lines + 1] = "            if cache.frame_number == frame_number and cache.key == cache_key then offset = cache.offset end"
			upload_lines[#upload_lines + 1] = "            cache_hit = offset ~= nil"
			upload_lines[#upload_lines + 1] = "        elseif info.block.upload_scope == \"frame_keyed\" then"
			upload_lines[#upload_lines + 1] = "            if cache.frame_number ~= frame_number then"
			upload_lines[#upload_lines + 1] = "                cache.frame_number = frame_number"
			upload_lines[#upload_lines + 1] = "                cache.strong_entries = {}"
			upload_lines[#upload_lines + 1] = "                cache.weak_entries = setmetatable({}, {__mode = \"k\"})"
			upload_lines[#upload_lines + 1] = "            end"
			upload_lines[#upload_lines + 1] = "            local key_type = type(cache_key)"
			upload_lines[#upload_lines + 1] = "            local entries = (key_type == \"table\" or key_type == \"userdata\") and cache.weak_entries or cache.strong_entries"
			upload_lines[#upload_lines + 1] = "            offset = entries[cache_key]"
			upload_lines[#upload_lines + 1] = "            cache_hit = offset ~= nil"
			upload_lines[#upload_lines + 1] = "        elseif info.block.upload_scope == \"persistent_keyed\" then"
			upload_lines[#upload_lines + 1] = "            cache.strong_entries = cache.strong_entries or {}"
			upload_lines[#upload_lines + 1] = "            cache.weak_entries = cache.weak_entries or setmetatable({}, {__mode = \"k\"})"
			upload_lines[#upload_lines + 1] = "            local key_type = type(cache_key)"
			upload_lines[#upload_lines + 1] = "            persistent_entries = (key_type == \"table\" or key_type == \"userdata\") and cache.weak_entries or cache.strong_entries"
			upload_lines[#upload_lines + 1] = "            persistent_entry = persistent_entries[cache_key]"
			upload_lines[#upload_lines + 1] = "            if persistent_entry then offset = info.ubo:GetOffset(frame_index, persistent_entry.slot) end"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "    if info.block.upload_scope == \"persistent_keyed\" and cache_key ~= nil then"
			upload_lines[#upload_lines + 1] = "        local ubo_data = info.ubo:GetData()"
			upload_lines[#upload_lines + 1] = "        if info.block.source then"
			upload_lines[#upload_lines + 1] = "            local source_data = info.block.source.get(self, info.block)"
			upload_lines[#upload_lines + 1] = "            if source_data == nil then error(\"uniform buffer block source returned nil for \" .. tostring(info.block.name)) end"
			upload_lines[#upload_lines + 1] = "            ffi.copy(ubo_data, ffi.cast(\"uint8_t *\", source_data) + info.block.source.offset, ffi.sizeof(ubo_data))"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "        if info.block.write then"
			upload_lines[#upload_lines + 1] = "            info.block.write(self, ubo_data, info.block)"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "        local src = ffi.cast(\"uint8_t *\", ubo_data)"
			upload_lines[#upload_lines + 1] = "        if persistent_entry and persistent_entry.snapshot and bytes_equal(persistent_entry.snapshot, src, info.ubo.size) then"
			upload_lines[#upload_lines + 1] = "            cache_hit = true"
			upload_lines[#upload_lines + 1] = "            offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)"
			upload_lines[#upload_lines + 1] = "        else"
			upload_lines[#upload_lines + 1] = "            cache_hit = false"
			upload_lines[#upload_lines + 1] = "            if upload_probe.IsEnabled() then"
			upload_lines[#upload_lines + 1] = "                upload_probe.RecordUpload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)"
			upload_lines[#upload_lines + 1] = "            end"
			upload_lines[#upload_lines + 1] = "            if persistent_entry == nil then"
			upload_lines[#upload_lines + 1] = "                persistent_entry = {slot = info.ubo:AllocatePersistentSlot(), snapshot = ffi.new(\"uint8_t[?]\", info.ubo.size)}"
			upload_lines[#upload_lines + 1] = "                persistent_entries[cache_key] = persistent_entry"
			upload_lines[#upload_lines + 1] = "            end"
			upload_lines[#upload_lines + 1] = "            info.ubo:UploadPersistent(persistent_entry.slot)"
			upload_lines[#upload_lines + 1] = "            ffi.copy(persistent_entry.snapshot, src, info.ubo.size)"
			upload_lines[#upload_lines + 1] = "            offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "    elseif offset == nil then"
			upload_lines[#upload_lines + 1] = "        local ubo_data = info.ubo:GetData()"
			upload_lines[#upload_lines + 1] = "        if info.block.source then"
			upload_lines[#upload_lines + 1] = "            local source_data = info.block.source.get(self, info.block)"
			upload_lines[#upload_lines + 1] = "            if source_data == nil then error(\"uniform buffer block source returned nil for \" .. tostring(info.block.name)) end"
			upload_lines[#upload_lines + 1] = "            ffi.copy(ubo_data, ffi.cast(\"uint8_t *\", source_data) + info.block.source.offset, ffi.sizeof(ubo_data))"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "        if info.block.write then"
			upload_lines[#upload_lines + 1] = "            info.block.write(self, ubo_data, info.block)"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "        if upload_probe.IsEnabled() then"
			upload_lines[#upload_lines + 1] = "            upload_probe.RecordUpload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "        offset = info.ubo:Upload(frame_index)"
			upload_lines[#upload_lines + 1] = "        if info.block.upload_scope == \"frame\" then"
			upload_lines[#upload_lines + 1] = "            local cache = info.offsets"
			upload_lines[#upload_lines + 1] = "            cache.frame_number = frame_number"
			upload_lines[#upload_lines + 1] = "            cache.key = true"
			upload_lines[#upload_lines + 1] = "            cache.offset = offset"
			upload_lines[#upload_lines + 1] = "        elseif info.block.upload_scope == \"frame_keyed\" and cache_key ~= nil then"
			upload_lines[#upload_lines + 1] = "            local cache = info.offsets"
			upload_lines[#upload_lines + 1] = "            if cache.frame_number ~= frame_number then"
			upload_lines[#upload_lines + 1] = "                cache.frame_number = frame_number"
			upload_lines[#upload_lines + 1] = "                cache.strong_entries = {}"
			upload_lines[#upload_lines + 1] = "                cache.weak_entries = setmetatable({}, {__mode = \"k\"})"
			upload_lines[#upload_lines + 1] = "            end"
			upload_lines[#upload_lines + 1] = "            local key_type = type(cache_key)"
			upload_lines[#upload_lines + 1] = "            local entries = (key_type == \"table\" or key_type == \"userdata\") and cache.weak_entries or cache.strong_entries"
			upload_lines[#upload_lines + 1] = "            entries[cache_key] = offset"
			upload_lines[#upload_lines + 1] = "        end"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = "    if upload_probe.IsEnabled() then"
			upload_lines[#upload_lines + 1] = "        upload_probe.RecordCacheAccess(info.debug_name, cache_key, cache_hit)"
			upload_lines[#upload_lines + 1] = "    end"
			upload_lines[#upload_lines + 1] = string.format("    offsets[%d] = offset", i)
			upload_lines[#upload_lines + 1] = "end"
		end

		upload_lines[#upload_lines + 1] = "if #offsets > 0 then self.pipeline:Bind(cmd, frame_index, offsets) end"
		upload_lines[#upload_lines + 1] = "end"
		local upload_constants_source = table.concat(upload_lines, "\n")
		local upload_constants_chunk = assert(loadstring(upload_constants_source, "UploadConstants_unrolled"))
		local upload_constants_impl = upload_constants_chunk()

		function self:UploadConstants()
			return upload_constants_impl(
				self,
				render.GetCommandBuffer(),
				render,
				ffi,
				system,
				upload_probe,
				active_stages,
				active_stage_key,
				should_push_constants,
				note_push_constants,
				push_constant_blocks,
				push_constant_block_offsets,
				constant_structs,
				uniform_buffer_order,
				uniform_buffer_types
			)
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
	self.push_constant_blocks = push_constant_blocks
	self.push_constant_block_offsets = push_constant_block_offsets
	self.push_constant_block_order = push_constant_block_order
	self.push_constant_types = push_constant_types
	self.constant_blocks = constant_resolution.blocks
	self.constant_push_budget = constant_resolution.push_budget

	local function get_vertex_attribute_location_count(glsl_type)
		if glsl_type == "mat4" then return 4 end

		return 1
	end

	local function append_vertex_shader_input(shader_input_list, attribute)
		if attribute[2] == "mat4" then
			for row = 0, 3 do
				shader_input_list[#shader_input_list + 1] = {
					string.format("%s_row_%d", attribute[1], row),
					"vec4",
					"r32g32b32a32_sfloat",
				}
			end

			return
		end

		shader_input_list[#shader_input_list + 1] = attribute
	end

	-- Build vertex attributes
	local attributes = {}
	local logical_attributes = {}
	local bindings = {}
	local shader_inputs = {}
	local shader_outputs = {}
	local resolved_vertex_shader = config.vertex and config.vertex.shader or nil
	local resolved_fragment_shader = config.fragment and config.fragment.shader or nil

	if config.vertex then
		shader_outputs = config.vertex.outputs or config.vertex.attributes or {}
		local vertex_bindings = config.vertex.bindings

		if not vertex_bindings and config.vertex.attributes then
			vertex_bindings = {
				{
					binding = config.vertex.binding_index or 0,
					input_rate = config.vertex.input_rate or "vertex",
					attributes = config.vertex.attributes,
				},
			}
		end

		if vertex_bindings then
			local location = 0

			for binding_index, binding in ipairs(vertex_bindings) do
				local binding_attributes = binding.attributes or {}
				local stride = 0
				local resolved_binding = binding.binding

				if resolved_binding == nil then resolved_binding = binding.binding_index end

				if resolved_binding == nil then resolved_binding = binding_index - 1 end

				for _, attribute in ipairs(binding_attributes) do
					local attribute_name = attribute[1]
					local attribute_type = attribute[2]
					local attribute_format = attribute[3]
					local attribute_offset = stride
					local attribute_lua_type = glsl_to_lua_type[attribute_type]
					local location_count = get_vertex_attribute_location_count(attribute_type)
					logical_attributes[#logical_attributes + 1] = {
						binding = resolved_binding,
						offset = attribute_offset,
						lua_name = attribute_name,
						lua_type = attribute_lua_type,
						format = attribute_format,
					}

					for location_offset = 0, location_count - 1 do
						local physical_name = attribute_name
						local physical_type = attribute_type
						local physical_format = attribute_format
						local physical_offset = attribute_offset

						if attribute_type == "mat4" then
							physical_name = string.format("%s_row_%d", attribute_name, location_offset)
							physical_type = "vec4"
							physical_format = "r32g32b32a32_sfloat"
							physical_offset = attribute_offset + location_offset * render.GetVulkanFormatSize(physical_format)
						end

						table.insert(
							attributes,
							{
								binding = resolved_binding,
								location = location + location_offset,
								format = physical_format,
								offset = physical_offset,
								lua_name = attribute_name,
								lua_type = attribute_lua_type,
							}
						)
					end

					append_vertex_shader_input(shader_inputs, attribute)
					stride = stride + location_count * render.GetVulkanFormatSize(attribute_type == "mat4" and "r32g32b32a32_sfloat" or attribute_format)
					location = location + location_count
				end

				if #binding_attributes > 0 then
					table.insert(
						bindings,
						{
							binding = resolved_binding,
							stride = stride,
							input_rate = binding.input_rate or "vertex",
						}
					)
				end
			end
		end
	end

	local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
	local bindless_texture_capacity = bindless_descriptor_capacities.textures
	local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
	local tess_control_outputs = (config.tessellation_control and config.tessellation_control.outputs) or shader_outputs
	local tess_eval_outputs = (
			config.tessellation_evaluation and
			config.tessellation_evaluation.outputs
		)
		or
		tess_control_outputs
	local final_fragment_inputs = config.tessellation_evaluation and tess_eval_outputs or shader_outputs
	-- Build shader header and I/O
	local shader_header = (
		[[#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require

	layout(set = 1, binding = 0) uniform sampler2D textures[%d];
	layout(set = 1, binding = 1) uniform samplerCube cubemaps[%d];
	#define TEXTURE(idx) textures[nonuniformEXT(idx)]
	#define CUBEMAP(idx) cubemaps[nonuniformEXT(idx)]
]]
	):format(bindless_texture_capacity, bindless_cubemap_capacity)

	if config.mesh or config.mesh_ext or config.task or config.task_ext then
		shader_header = shader_header .. "#extension GL_EXT_mesh_shader : require\n"
	end

	local vertex_input = ""
	local vertex_output = ""
	local tess_control_input = ""
	local tess_control_output = ""
	local tess_eval_input = ""
	local tess_eval_output = ""
	local fragment_input = ""

	for i, attr in ipairs(shader_inputs) do
		vertex_input = vertex_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
	end

	for i, attr in ipairs(shader_outputs) do
		vertex_output = vertex_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
		tess_control_input = tess_control_input .. string.format("layout(location = %d) in %s in_%s[];\n", i - 1, attr[2], attr[1])
	end

	for i, attr in ipairs(tess_control_outputs) do
		tess_control_output = tess_control_output .. string.format("layout(location = %d) out %s out_%s[];\n", i - 1, attr[2], attr[1])
		tess_eval_input = tess_eval_input .. string.format("layout(location = %d) in %s in_%s[];\n", i - 1, attr[2], attr[1])
	end

	for i, attr in ipairs(tess_eval_outputs) do
		tess_eval_output = tess_eval_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
	end

	for i, attr in ipairs(final_fragment_inputs) do
		fragment_input = fragment_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
	end

	if config.vertex and not resolved_vertex_shader and config.vertex.passthrough then
		resolved_vertex_shader = build_passthrough_vertex_shader(config.vertex, shader_outputs, shader_inputs)
	end

	if config.fragment then
		resolved_fragment_shader = build_fragment_shader(config.fragment)
	end

	-- Build descriptor sets
	local descriptor_sets = {
		-- Texture array sampler (binding 0)
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
			set_index = 1,
		},
		-- Cubemap array sampler (binding 1)
		{
			type = "combined_image_sampler",
			binding_index = 1,
			count = bindless_cubemap_capacity,
			set_index = 1,
		},
	}
	-- Add uniform buffers from and descriptors from all stages
	local uniform_buffer_order = {}

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
					local ubo = uniform_buffers[block.name]
					table.insert(uniform_buffer_order, block.name)
					table.insert(
						descriptor_sets,
						{
							type = "uniform_buffer_dynamic",
							binding_index = block.binding_index,
							args = {ubo.buffer, ubo.aligned_size},
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
	if config.vertex and resolved_vertex_shader then
		local vertex_code = shader_header .. vertex_input .. vertex_output .. get_glsl_push_constants("vertex") .. get_glsl_uniform_buffers("vertex") .. (
				config.vertex.custom_declarations or
				""
			) .. (
				resolved_vertex_shader or
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
				push_constants = config.vertex.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Tessellation control stage
	if config.tessellation_control then
		local tess_control_code = shader_header .. tess_control_input .. tess_control_output .. (
				config.tessellation_control.custom_declarations or
				""
			) .. get_glsl_push_constants("tessellation_control") .. get_glsl_uniform_buffers("tessellation_control") .. (
				config.tessellation_control.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "tessellation_control",
				code = tess_control_code,
				descriptor_sets = descriptor_sets,
				push_constants = config.tessellation_control.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Tessellation evaluation stage
	if config.tessellation_evaluation then
		local tess_eval_code = shader_header .. tess_eval_input .. tess_eval_output .. (
				config.tessellation_evaluation.custom_declarations or
				""
			) .. get_glsl_push_constants("tessellation_evaluation") .. get_glsl_uniform_buffers("tessellation_evaluation") .. (
				config.tessellation_evaluation.shader or
				""
			)
		table.insert(
			shader_stages,
			{
				type = "tessellation_evaluation",
				code = tess_eval_code,
				descriptor_sets = descriptor_sets,
				push_constants = config.tessellation_evaluation.push_constants and push_constant_info or nil,
			}
		)
	end

	-- Fragment stage
	if config.fragment then
		local fragment_code = shader_header .. fragment_input .. fragment_outputs .. (
				config.fragment.custom_declarations or
				""
			) .. get_glsl_push_constants("fragment") .. get_glsl_uniform_buffers("fragment") .. (
				resolved_fragment_shader or
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
	local color_blend = config.color_blend or {}
	local attachments = color_blend.attachments
	local sanitized_color_blend

	if attachments and attachments[2] then
		sanitized_color_blend = {attachments = {}}

		for i, info in ipairs(attachments) do
			local attachment_info = type(info) == "table" and table.copy(info) or info

			if i == 1 and type(attachment_info) == "table" then
				attachment_info.blend = nil
				attachment_info.src_color_blend_factor = nil
				attachment_info.dst_color_blend_factor = nil
				attachment_info.color_blend_op = nil
				attachment_info.src_alpha_blend_factor = nil
				attachment_info.dst_alpha_blend_factor = nil
				attachment_info.alpha_blend_op = nil
				attachment_info.color_write_mask = nil
			end

			sanitized_color_blend.attachments[i] = attachment_info
		end
	elseif
		color_blend.attachments and
		color_blend.attachments[1] and
		color_blend.attachments[2] == nil
	then
		sanitized_color_blend = {attachments = {table.copy(color_blend.attachments[1])}}
		sanitized_color_blend.attachments[1].blend = nil
		sanitized_color_blend.attachments[1].src_color_blend_factor = nil
		sanitized_color_blend.attachments[1].dst_color_blend_factor = nil
		sanitized_color_blend.attachments[1].color_blend_op = nil
		sanitized_color_blend.attachments[1].src_alpha_blend_factor = nil
		sanitized_color_blend.attachments[1].dst_alpha_blend_factor = nil
		sanitized_color_blend.attachments[1].alpha_blend_op = nil
		sanitized_color_blend.attachments[1].color_write_mask = nil
	end

	local pipeline_config = {
		ColorFormat = #actual_color_formats > 0 and actual_color_formats or color_format,
		DepthFormat = depth_format,
		RasterizationSamples = rasterization_samples or "1",
		DescriptorSetCount = descriptor_set_count or
			(
				render.target:IsValid() and
				render.target.image_count
			)
			or
			1,
		shader_stages = shader_stages,
		Topology = config.Topology or "triangle_list",
		PatchControlPoints = config.PatchControlPoints or 3,
		PolygonMode = config.PolygonMode or "fill",
		CullMode = config.CullMode or "back",
		FrontFace = config.FrontFace or "counter_clockwise",
		DepthBias = config.DepthBias or false,
		DepthBiasConstantFactor = config.DepthBiasConstantFactor or 0,
		DepthBiasClamp = config.DepthBiasClamp or 0,
		DepthBiasSlopeFactor = config.DepthBiasSlopeFactor or 0,
		LineWidth = config.LineWidth or 1.0,
		DepthClamp = config.DepthClamp or false,
		Discard = config.Discard or false,
		PrimitiveRestart = config.PrimitiveRestart or false,
		Blend = config.Blend or false,
		SrcColorBlendFactor = config.SrcColorBlendFactor or "src_alpha",
		DstColorBlendFactor = config.DstColorBlendFactor or "one_minus_src_alpha",
		ColorBlendOp = config.ColorBlendOp or "add",
		SrcAlphaBlendFactor = config.SrcAlphaBlendFactor or "one",
		DstAlphaBlendFactor = config.DstAlphaBlendFactor or "zero",
		AlphaBlendOp = config.AlphaBlendOp or "add",
		ColorWriteMask = config.ColorWriteMask or {"r", "g", "b", "a"},
		LogicOpEnabled = config.LogicOpEnabled or false,
		LogicOp = config.LogicOp or "copy",
		BlendConstants = config.BlendConstants or {0.0, 0.0, 0.0, 0.0},
		SampleShading = config.SampleShading or false,
		MinSampleShading = config.MinSampleShading or 0,
		Sampler = config.Sampler or config.sampler,
		color_blend = sanitized_color_blend,
		DepthTest = config.DepthTest,
		DepthWrite = config.DepthWrite,
		DepthCompareOp = config.DepthCompareOp,
		DepthBoundsTest = config.DepthBoundsTest,
		StencilTest = config.StencilTest,
		FrontStencilFailOp = config.FrontStencilFailOp,
		FrontStencilPassOp = config.FrontStencilPassOp,
		FrontStencilDepthFailOp = config.FrontStencilDepthFailOp,
		FrontStencilCompareOp = config.FrontStencilCompareOp,
		FrontStencilReference = config.FrontStencilReference,
		FrontStencilCompareMask = config.FrontStencilCompareMask,
		FrontStencilWriteMask = config.FrontStencilWriteMask,
		BackStencilFailOp = config.BackStencilFailOp,
		BackStencilPassOp = config.BackStencilPassOp,
		BackStencilDepthFailOp = config.BackStencilDepthFailOp,
		BackStencilCompareOp = config.BackStencilCompareOp,
		BackStencilReference = config.BackStencilReference,
		BackStencilCompareMask = config.BackStencilCompareMask,
		BackStencilWriteMask = config.BackStencilWriteMask,
	}

	if pipeline_config.DepthCompareOp == nil then
		pipeline_config.DepthCompareOp = "less"
	end

	if pipeline_config.DepthBoundsTest == nil then
		pipeline_config.DepthBoundsTest = false
	end

	if pipeline_config.StencilTest == nil then
		pipeline_config.StencilTest = false
	end

	if pipeline_config.DepthTest == nil then pipeline_config.DepthTest = true end

	if pipeline_config.DepthWrite == nil then pipeline_config.DepthWrite = true end

	self.pipeline = render.CreateGraphicsPipeline(pipeline_config)
	self.vertex_attributes = logical_attributes
	self.physical_vertex_attributes = attributes
	self.debug_views = debug_views
	self.config = config
	self.actual_color_formats = actual_color_formats

	-- Create framebuffer(s) if this pipeline has color or depth outputs
	if
		not config.dont_create_framebuffers and
		(
			#self.actual_color_formats > 0 or
			config.DepthFormat
		)
	then
		self:RecreateFramebuffers()

		if not self.config.FramebufferSize then
			self:AddGlobalEvent("WindowFramebufferResized")
		end
	end

	return self
end

function EasyPipeline:RecreateFramebuffers()
	local framebuffer_count = self.config.framebuffer_count or 1
	local size = self.config.FramebufferSize or render.GetRenderImageSize()

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
		self.framebuffer = Framebuffer.New{
			width = size.x,
			height = size.y,
			formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
			depth = self.config.DepthFormat ~= nil,
			depth_format = self.config.DepthFormat,
		}
	else
		-- Multiple framebuffers (ping-pong)
		self.framebuffers = {}

		for i = 1, framebuffer_count do
			self.framebuffers[i] = Framebuffer.New{
				width = size.x,
				height = size.y,
				formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
				depth = self.config.DepthFormat ~= nil,
				depth_format = self.config.DepthFormat,
			}
		end

		-- Also set first one as default for backward compatibility
		self.framebuffer = self.framebuffers[1]
	end
end

function EasyPipeline:OnRemove()
	if self.framebuffers then
		for i = 1, #self.framebuffers do
			local fb = self.framebuffers[i]

			if fb then fb:Remove() end
		end

		self.framebuffers = nil
		self.framebuffer = nil
	elseif self.framebuffer then
		self.framebuffer:Remove()
		self.framebuffer = nil
	end

	if self.pipeline then
		self.pipeline:Remove()
		self.pipeline = nil
	end

	if self.uniform_buffers then
		for _, ubo in pairs(self.uniform_buffers) do
			if ubo then ubo:Remove() end
		end

		self.uniform_buffers = nil
	end
end

function EasyPipeline:OnWindowFramebufferResized()
	if render.target:IsValid() and render.target.config.offscreen then return end

	timer.Delay(
		0.01,
		function()
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
						self.pipeline:UpdateDescriptorSetArray(i, 0, 1, textures)
					end
				end
			end
		end,
		self
	)
end

function EasyPipeline:Bind(cmd, frame_index, dynamic_offsets)
	cmd = cmd or render.GetCommandBuffer()
	frame_index = frame_index or render.GetCurrentFrame()
	self.pipeline:Bind(cmd, frame_index, dynamic_offsets or self.dynamic_offsets)
end

function EasyPipeline:ApplyProperties(...)
	return self.pipeline:ApplyProperties(...)
end

function EasyPipeline:UpdateDescriptorSetArray(...)
	return self.pipeline:UpdateDescriptorSetArray(...)
end

function EasyPipeline:UpdateDescriptorSet(...)
	return self.pipeline:UpdateDescriptorSet(...)
end

function EasyPipeline:ResetToBase(...)
	return self.pipeline:ResetToBase(...)
end

function EasyPipeline:GetUniformBuffer(...)
	return self.pipeline:GetUniformBuffer(...)
end

function EasyPipeline:GetColorFormat(...)
	return self.pipeline:GetColorFormat(...)
end

function EasyPipeline:GetDepthFormat(...)
	return self.pipeline:GetDepthFormat(...)
end

function EasyPipeline:GetRasterizationSamples(...)
	return self.pipeline:GetRasterizationSamples(...)
end

function EasyPipeline:GetSamples(...)
	return self.pipeline:GetRasterizationSamples(...)
end

function EasyPipeline:GetDescriptorSetCount(...)
	return self.pipeline:GetDescriptorSetCount(...)
end

function EasyPipeline:GetFallbackView(...)
	return self.pipeline:GetFallbackView(...)
end

function EasyPipeline:GetFallbackSampler(...)
	return self.pipeline:GetFallbackSampler(...)
end

function EasyPipeline:GetDebugViews()
	return self.debug_views
end

function EasyPipeline:GetVertexAttributes()
	return self.vertex_attributes
end

function EasyPipeline:SetTextureSamplerConfigResolver(resolver)
	self.texture_sampler_config_resolver = resolver
end

function EasyPipeline:GetTextureSamplerConfig(texture)
	if self.texture_sampler_config_resolver then
		return self.texture_sampler_config_resolver(texture)
	end

	return nil
end

function EasyPipeline:GetTextureIndex(texture)
	return self.pipeline:GetTextureIndex(texture, 1, self:GetTextureSamplerConfig(texture))
end

function EasyPipeline:SetSamplerConfig(config)
	return self.pipeline:SetSamplerConfig(config)
end

function EasyPipeline:GetSamplerConfig()
	return self.pipeline:GetSamplerConfig()
end

function EasyPipeline:SetSamplerConfigValue(key, value)
	return self.pipeline:SetSamplerConfigValue(key, value)
end

function EasyPipeline:GetPushConstantBlockOffset(name)
	local offset = self.push_constant_block_offsets and self.push_constant_block_offsets[name]

	if offset == nil then
		error("Invalid push constant block: " .. tostring(name), 2)
	end

	return offset
end

function EasyPipeline:GetPushConstantBlockType(name)
	if not (self.push_constant_blocks and self.push_constant_blocks[name]) then
		error("Invalid push constant block: " .. tostring(name), 2)
	end

	local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
	local ctype = self.push_constant_types and self.push_constant_types[struct_name]

	if not ctype then error("Missing push constant type: " .. tostring(name), 2) end

	return ctype
end

function EasyPipeline:GetPushConstantBlockSize(name)
	return ffi.sizeof(self:GetPushConstantBlockType(name))
end

function EasyPipeline:GetConstantBlockInfo(name)
	local block = self.constant_blocks and self.constant_blocks[name]

	if not block then error("Invalid constant block: " .. tostring(name), 2) end

	return {
		name = block.name,
		storage = block._resolved_storage,
		size = block._size,
		binding_index = block.binding_index,
		offset = block._resolved_storage == "push" and
			self:GetPushConstantBlockOffset(name) or
			nil,
	}
end

function EasyPipeline:GetConstantBlockStorage(name)
	return self:GetConstantBlockInfo(name).storage
end

function EasyPipeline:BuildConstantBlockData(name)
	local info = self:GetConstantBlockInfo(name)
	local block = assert(
		self.constant_blocks and self.constant_blocks[name],
		"Invalid constant block: " .. tostring(name)
	)
	local data

	if info.storage == "push" then
		data = self:GetPushConstantBlockType(name)()
	else
		local ubo_data = assert(
			self.uniform_buffers and self.uniform_buffers[name],
			"Missing uniform buffer for constant block: " .. tostring(name)
		):GetData()
		data = ffi.typeof(ubo_data)()
	end

	if block.source then
		local source_data = block.source.get(self, block)

		if source_data == nil then
			error("constant block source returned nil for " .. tostring(block.name), 2)
		end

		ffi.copy(data, ffi.cast("uint8_t *", source_data) + block.source.offset, ffi.sizeof(data))
	end

	if block.write then block.write(self, data, block) end

	return data
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

local function resolve_draw_framebuffer(self, framebuffer, frame_index)
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

	return fb
end

local function begin_draw(self, cmd, fb, frame_index)
	if fb then fb:Begin(cmd) end

	-- If this pass draws directly to the main target (no explicit framebuffer),
	-- make sure viewport/scissor are reset to full render size. Otherwise the
	-- command buffer may still have a tiny viewport from a previous downsample pass.
	if not fb then
		local size = render.GetRenderImageSize()

		if size and size.x and size.y and size.x > 0 and size.y > 0 then
			cmd:SetViewport(0, 0, size.x, size.y, 0, 1)
			cmd:SetScissor(0, 0, size.x, size.y)
		end
	end

	self:Bind(cmd, frame_index)
end

-- Begin drawing to this pipeline's framebuffer
-- framebuffer: optional custom framebuffer to use (defaults to pipeline's framebuffer)
-- frame_index: optional frame index for ping-pong buffers (defaults to auto-calculated)
function EasyPipeline:BeginDraw(cmd, framebuffer, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	local fb = resolve_draw_framebuffer(self, framebuffer, frame_index)
	begin_draw(self, cmd, fb, frame_index)
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
	local fb = resolve_draw_framebuffer(self, framebuffer, frame_index)
	render.PushCommandBuffer(cmd)
	local began_framebuffer = fb ~= nil
	begin_draw(self, cmd, fb, frame_index)

	if self.on_draw then
		self.on_draw(self, cmd)
	else
		self:UploadConstants()
		cmd:Draw(vertex_count, 1, 0, 0)
	end

	if began_framebuffer then self:EndDraw(cmd, fb) end

	render.PopCommandBuffer()
end

function EasyPipeline:DrawMeshTasks(gx, gy, gz, cmd, framebuffer, frame_index)
	cmd = cmd or render.GetCommandBuffer()
	local fb = resolve_draw_framebuffer(self, framebuffer, frame_index)
	render.PushCommandBuffer(cmd)
	local began_framebuffer = fb ~= nil
	local ok, err = xpcall(
		function()
			begin_draw(self, cmd, fb, frame_index)
			self:UploadConstants()
			cmd:DrawMeshTasks(gx, gy, gz)
		end,
		debug.traceback
	)

	if began_framebuffer then self:EndDraw(cmd, fb) end

	render.PopCommandBuffer()

	if not ok then error(err, 0) end
end

function EasyPipeline:Dispatch(cmd, group_count_x, group_count_y, group_count_z, frame_index, dynamic_offsets)
	if not self.pipeline or not self.pipeline.Dispatch then
		error("EasyPipeline:Dispatch is only available for compute pipelines", 2)
	end

	cmd = cmd or render.GetCommandBuffer()
	render.PushCommandBuffer(cmd)

	if self.on_draw then
		self.on_draw(self, cmd)
	else
		self:UploadConstants()
		self.pipeline:Dispatch(
			cmd,
			group_count_x or 1,
			group_count_y or 1,
			group_count_z or 1,
			frame_index,
			dynamic_offsets
		)
	end

	render.PopCommandBuffer()
end

function EasyPipeline:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
	if not self.pipeline or not self.pipeline.DispatchForSize then
		error("EasyPipeline:DispatchForSize is only available for compute pipelines", 2)
	end

	cmd = cmd or render.GetCommandBuffer()
	render.PushCommandBuffer(cmd)

	if self.on_draw then
		self.on_draw(self, cmd)
	else
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
	end

	render.PopCommandBuffer()
end

function EasyPipeline.FragmentOnly(config)
	assert_no_legacy_top_level_fields(config, 2)
	local write = config.write
	local source = config.source

	if type(config.block) == "table" then
		write = write or config.block.write
		source = source or config.block.source
	end

	return EasyPipeline.New{
		ColorFormat = config.ColorFormat,
		RasterizationSamples = "1",
		CullMode = "none",
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
			push_constants = {
				{
					name = "fragment",
					block = config.block,
					write = write,
					source = source,
				},
			},
			shader = config.shader,
		},
	}
end

function EasyPipeline.Compute(config)
	assert_no_legacy_top_level_fields(config, 2)
	local write = config.write
	local source = config.source

	if type(config.block) == "table" then
		write = write or config.block.write
		source = source or config.block.source
	end

	local self = EasyPipeline:CreateObject()
	self.on_draw = config.on_draw or nil
	local block = config.block or {}
	local push_constant_type
	local push_constant_size = 0

	if #block > 0 then
		push_constant_type = EasyPipeline.BuildFFIType("scalar", "ComputeConstants", block)
		push_constant_size = ffi.sizeof(push_constant_type)
	end

	local push_constant_data = push_constant_type and push_constant_type() or nil
	local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
	local bindless_texture_capacity = bindless_descriptor_capacities.textures
	local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
	local shader_header = (
		[[#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require

layout(set = 1, binding = 0) uniform sampler2D textures[%d];
layout(set = 1, binding = 1) uniform samplerCube cubemaps[%d];
#define TEXTURE(idx) textures[nonuniformEXT(idx)]
#define CUBEMAP(idx) cubemaps[nonuniformEXT(idx)]
]]
	):format(bindless_texture_capacity, bindless_cubemap_capacity)
	local push_constant_glsl = ""

	if #block > 0 then
		local function flatten_fields(fields, out)
			out = out or {}

			for _, field in ipairs(fields) do
				if type(field[1]) == "table" then
					flatten_fields(field, out)
				else
					out[#out + 1] = field
				end
			end

			return out
		end

		local function build_glsl_fields(fields)
			local glsl_fields = ""

			for _, field in ipairs(fields) do
				local name = field[1]
				local glsl_type = field[2]
				local array_size = type(field[3]) == "number" and field[3] or nil

				if array_size then
					glsl_fields = glsl_fields .. string.format("    %s %s[%d];\n", glsl_type, name, array_size)
				else
					glsl_fields = glsl_fields .. string.format("    %s %s;\n", glsl_type, name)
				end
			end

			return glsl_fields
		end

		push_constant_glsl = "layout(push_constant, scalar) uniform ComputeConstants {\n" .. build_glsl_fields(flatten_fields(block)) .. "} compute;\n\n"
	end

	local descriptor_sets = {
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
			set_index = 1,
		},
		{
			type = "combined_image_sampler",
			binding_index = 1,
			count = bindless_cubemap_capacity,
			set_index = 1,
		},
	}

	for _, ds in ipairs(config.descriptor_sets or {}) do
		descriptor_sets[#descriptor_sets + 1] = ds
	end

	self.pipeline = render.CreateComputePipeline{
		DescriptorSetCount = config.DescriptorSetCount or
			(
				config.descriptor_set_count
			)
			or
			(
				render.target:IsValid() and
				render.target.image_count
			)
			or
			1,
		LocalSize = config.LocalSize or config.local_size or config.workgroup_size,
		shader_stages = {
			{
				type = "compute",
				code = shader_header .. (
						config.custom_declarations or
						""
					) .. push_constant_glsl .. (
						config.shader or
						""
					),
				descriptor_sets = descriptor_sets,
				push_constants = push_constant_size > 0 and
					{
						offset = 0,
						size = push_constant_size,
					} or
					nil,
			},
		},
	}

	function self:UploadConstants()
		if not push_constant_data then return end

		if source then
			local source_data = source.get(self, source)

			if source_data == nil then
				error("compute push constant source returned nil", 2)
			end

			ffi.copy(
				push_constant_data,
				ffi.cast("uint8_t *", source_data) + (source.offset or 0),
				push_constant_size
			)
		end

		if write then write(self, push_constant_data) end

		self.pipeline:PushConstants(
			render.GetCommandBuffer(),
			{"compute"},
			0,
			push_constant_data,
			push_constant_size
		)
	end

	return self
end

return EasyPipeline:Register()
