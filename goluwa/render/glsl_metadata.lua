local ffi = require("ffi")

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

local GLSL_TO_FFI = {
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

local GLSL_TO_ARRAY_SIZE = {
	mat4 = 16,
	vec4 = 4,
	vec3 = 3,
	vec2 = 2,
	ivec4 = 4,
	ivec3 = 3,
	ivec2 = 2,
	uint64_t = 1,
}

local GLSL_TO_LUA_TYPE = {
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
	local glsl_type = field[2]
	local array_size = type(field[3]) == "number" and field[3] or nil
	return {
		name = field[1],
		glsl_type = glsl_type,
		array_size = array_size,
		is_struct = type(glsl_type) == "table",
	}
end

local function get_layout_info(layout, glsl_type, array_size)
	layout = layout or "scalar"
	local base_alignment = 4
	local size = 4

	if type(glsl_type) == "table" then
		local struct_size = 0
		local max_alignment = 4

		for _, field in ipairs(glsl_type) do
			local field_alignment, field_size = get_layout_info(layout, field[2], field[3])
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

	if layout == "scalar" then
		if
			glsl_type == "vec2" or
			glsl_type == "vec3" or
			glsl_type == "vec4" or
			glsl_type == "mat4"
		then
			base_alignment = 4
		end
	end

	if layout == "std140" then
		if array_size then
			base_alignment = math.max(base_alignment, 16)
			size = math.max(size, 16) * array_size
		end
	elseif array_size then
		size = size * array_size
	end

	return base_alignment, size
end

local function build_ffi_struct(layout, fields)
	layout = layout or "scalar"
	local local_struct_counter = 0
	local ffi_code = "struct __attribute__((packed)) {\n"
	local current_offset = 0
	local max_alignment = 16
	local struct_definitions = {}

	for _, field in ipairs(fields) do
		local info = get_field_info(field)
		local ffi_type = GLSL_TO_FFI[info.glsl_type] or info.glsl_type
		local base_size = GLSL_TO_ARRAY_SIZE[info.glsl_type]

		if info.is_struct then
			local_struct_counter = local_struct_counter + 1
			local struct_code = "struct __attribute__((packed)) {\n"
			local struct_offset = 0
			local struct_max_align = 4

			for _, struct_field in ipairs(info.glsl_type) do
				local sf_name = struct_field[1]
				local sf_type = struct_field[2]
				local sf_array_size = struct_field[3]
				local sf_ffi_type = GLSL_TO_FFI[sf_type] or sf_type
				local sf_base_size = GLSL_TO_ARRAY_SIZE[sf_type]
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

			local struct_final_size = math.ceil(struct_offset / struct_max_align) * struct_max_align

			if struct_final_size > struct_offset then
				struct_code = struct_code .. string.format("    char _pad_end[%d];\n", struct_final_size - struct_offset)
			end

			struct_code = struct_code .. "}"
			table.insert(struct_definitions, struct_code)
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

			current_offset = current_offset + size
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

local function verify_layout(layout, struct_name, fields, ctype)
	layout = layout or "scalar"
	local current_offset = 0
	local max_alignment = (layout == "std140" or layout == "std430") and 16 or 4

	for _, field in ipairs(fields) do
		local info = get_field_info(field)
		local base_alignment, size = get_layout_info(layout, info.glsl_type, info.array_size)
		max_alignment = math.max(max_alignment, base_alignment)
		current_offset = math.ceil(current_offset / base_alignment) * base_alignment
		local ffi_offset = tonumber(ffi.offsetof(ctype, info.name))

		if ffi_offset ~= current_offset then
			error(
				string.format(
					"Uniform buffer/Push constant '%s' field '%s' has incorrect alignment for layout '%s'!\nGLSL expected offset: %d\nFFI (C) actual offset: %d\nType: %s%s",
					struct_name,
					info.name,
					layout,
					current_offset,
					ffi_offset,
					info.glsl_type,
					info.array_size and ("[" .. info.array_size .. "]") or ""
				),
				3
			)
		end

		current_offset = current_offset + size
	end

	local expected_total_size = math.ceil(current_offset / max_alignment) * max_alignment

	if layout == "std140" then
		expected_total_size = math.ceil(expected_total_size / 16) * 16
	end

	if ffi.sizeof(ctype) < expected_total_size then
		error(
			string.format(
				"Uniform buffer/Push constant '%s' has incorrect total size for layout '%s'!\nGLSL expected size: %d\nFFI (C) actual size: %d\nFFI (C) actual alignment: %d",
				struct_name,
				layout,
				expected_total_size,
				ffi.sizeof(ctype),
				ffi.alignof(ctype)
			),
			3
		)
	end
end

local function build_ffi_type(layout, struct_name, fields)
	layout = layout or "scalar"
	struct_name = struct_name or "AnonymousLayout"
	fields = fields or {}
	local flat_fields = flatten_fields(fields)
	local ctype = ffi.typeof(build_ffi_struct(layout, flat_fields))
	verify_layout(layout, struct_name, flat_fields, ctype)
	return ctype
end

local function normalize_block_type_name(name)
	local type_name = name:sub(1, 1):upper() .. name:sub(2)

	if type_name == name then type_name = type_name .. "_t" end

	return type_name
end

local function build_glsl_fields(fields)
	local glsl_fields = ""
	local struct_definitions = {}

	for _, field in ipairs(fields) do
		local info = get_field_info(field)
		local type_name = info.glsl_type

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

	return glsl_fields, table.concat(struct_definitions, "")
end

local function get_scalar_field_size(field)
	local field_type = field[2]
	local field_size

	if type(field_type) == "table" then
		field_size = ffi.sizeof(ffi.typeof(build_ffi_type("scalar", "ProbeField", field_type)))
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
			string.format("%s '%s' source must be a table", kind, tostring(block.name)),
			3
		)
	end

	if type(source.get) ~= "function" then
		error(
			string.format(
				"%s '%s' source.get must be a function",
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
				"%s '%s' source must provide ctype or struct",
				kind,
				tostring(block.name)
			),
			3
		)
	end

	if source.field ~= nil and source.offset ~= nil then
		error(
			string.format(
				"%s '%s' source must specify either field or offset, not both",
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
					"%s '%s' source field '%s' is invalid",
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
				"%s '%s' source offset must be >= 0",
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
				"%s '%s' source slice [%d, %d) exceeds source size %d",
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
				"%s '%s' source offset %d is not aligned to %d bytes",
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

local function sanitize_color_blend_attachments(attachments)
	if not attachments or not attachments[1] then return nil end

	local result = {attachments = {}}

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

		result.attachments[i] = attachment_info
	end

	return result
end

local function build_shader_header(bindless_texture_capacity, bindless_cubemap_capacity, extra_extensions)
	local header = [=[#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require

	layout(set = 1, binding = 0) uniform sampler2D textures[%d];
	layout(set = 1, binding = 1) uniform samplerCube cubemaps[%d];
	#define TEXTURE(idx) textures[nonuniformEXT(idx)]
	#define CUBEMAP(idx) cubemaps[nonuniformEXT(idx)]]=]
	header = header:format(bindless_texture_capacity, bindless_cubemap_capacity)

	if extra_extensions then
		for _, ext in ipairs(extra_extensions) do
			header = header .. "\n" .. ext
		end
	end

	return header .. "\n"
end

local function build_base_descriptor_sets(bindless_texture_capacity, bindless_cubemap_capacity)
	return {
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

local function get_color_formats(config)
	local formats = {}
	local debug_views = {}
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
				table.insert(debug_views, {
					name = format[2][1],
					attachment_index = i,
					swizzle = format[2][2],
				})
			else
				-- Resolve function to get actual format
				if type(format) == "function" then format = format() end

				table.insert(formats, format)
				table.insert(debug_views, {
					name = format[2][1],
					attachment_index = i,
					swizzle = format[2][2],
				})
			end
		end
	end

	return formats, debug_views
end

return {
	-- FFI / struct layout
	build_ffi_type = build_ffi_type,
	build_glsl_fields = build_glsl_fields,
	build_field_descriptors = build_field_descriptors,
	verify_layout = verify_layout,
	build_ffi_struct = build_ffi_struct,
	flatten_fields = flatten_fields,
	get_field_info = get_field_info,
	get_layout_info = get_layout_info,
	get_scalar_field_size = get_scalar_field_size,
	get_scalar_layout_alignment = get_scalar_layout_alignment,
	-- Block normalization
	normalize_block_source = normalize_block_source,
	get_scalar_block_alignment = get_scalar_block_alignment,
	align_offset = align_offset,
	hoist_inline_block_metadata = hoist_inline_block_metadata,
	clone_constant_block = clone_constant_block,
	normalize_block_type_name = normalize_block_type_name,
	GLSL_TO_LUA_TYPE = GLSL_TO_LUA_TYPE,
	-- Config normalization
	sanitize_color_blend_attachments = sanitize_color_blend_attachments,
	get_nested_property_path = get_nested_property_path,
	has_nested_value = has_nested_value,
	get_constant_stage_config = get_constant_stage_config,
	normalize_fragment_adapter = normalize_fragment_adapter,
	get_color_formats = get_color_formats,
	-- GLSL code generation
	build_shader_header = build_shader_header,
	build_base_descriptor_sets = build_base_descriptor_sets,
	escape_lua_pattern = escape_lua_pattern,
	build_passthrough_vertex_shader = build_passthrough_vertex_shader,
	build_fragment_adapter_declaration = build_fragment_adapter_declaration,
	get_vertex_attribute_location_count = get_vertex_attribute_location_count,
	append_vertex_shader_input = append_vertex_shader_input,
	build_fragment_shader = build_fragment_shader,
}
