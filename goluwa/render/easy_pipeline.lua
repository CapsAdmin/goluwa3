local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local upload_probe = import("goluwa/render/upload_probe.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
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
local struct_counter = 0
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

local function resolve_framebuffer_size(config)
	local size = config.FramebufferSize or render.GetRenderImageSize()
	local scale = config.scale or config.Scale

	if type(size) == "function" then size = size() end

	if type(scale) == "function" then scale = scale() end

	local width = tonumber(size.x or size.width or size.w or 0) or 0
	local height = tonumber(size.y or size.height or size.h or 0) or 0

	if scale ~= nil then
		width = math.max(1, math.floor(width * scale + 0.5))
		height = math.max(1, math.floor(height * scale + 0.5))
	end

	return {x = width, y = height}
end

local function create_owned_framebuffers(self, extra_config)
	local framebuffer_count = self.config.framebuffer_count or 1
	local size = resolve_framebuffer_size(self.config)

	if self.framebuffers then
		for _, fb in ipairs(self.framebuffers) do
			fb:Remove()
		end

		self.framebuffers = nil
	end

	local function build_framebuffer_config()
		local config = {
			width = size.x,
			height = size.y,
			formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
			depth = self.config.DepthFormat ~= nil,
			depth_format = self.config.DepthFormat,
			mip_map_levels = self.config.mip_map_levels,
			color_image_usage = self.config.color_image_usage,
		}

		if extra_config then
			for key, value in pairs(extra_config) do
				config[key] = value
			end
		end

		return config
	end

	self.framebuffers = {}

	for i = 1, framebuffer_count do
		self.framebuffers[i] = Framebuffer.New(build_framebuffer_config())
	end
end

local function transition_compute_image(texture, cmd, src_stage, dst_stage, src_access, dst_access, new_layout)
	local image = texture:GetImage()
	local old_layout = image.layout or "undefined"

	if old_layout == new_layout then return end

	cmd:PipelineBarrier{
		srcStage = src_stage,
		dstStage = dst_stage,
		imageBarriers = {
			{
				image = image,
				srcAccessMask = src_access,
				dstAccessMask = dst_access,
				oldLayout = old_layout,
				newLayout = new_layout,
			},
		},
	}
	image.layout = new_layout
end

local function transition_texture_to_compute_storage(texture, cmd)
	local old_layout = texture:GetImage().layout or "undefined"
	local src_stage = "top_of_pipe"
	local src_access = "none"

	if old_layout == "shader_read_only_optimal" then
		src_stage = "fragment"
		src_access = "shader_read"
	elseif old_layout == "general" then
		src_stage = "compute"
		src_access = "shader_read"
	elseif old_layout == "color_attachment_optimal" then
		src_stage = "color_attachment_output"
		src_access = "color_attachment_write"
	end

	transition_compute_image(texture, cmd, src_stage, "compute", src_access, "shader_write", "general")
end

local function transition_texture_from_compute_storage(texture, cmd, dst_stage)
	transition_compute_image(
		texture,
		cmd,
		"compute",
		dst_stage or "fragment",
		"shader_write",
		"shader_read",
		"shader_read_only_optimal"
	)
end

local function get_compute_sampled_descriptor(texture)
	texture = texture or render.GetErrorTexture()
	assert(texture, "missing texture for compute sampled descriptor")
	return texture:GetView(),
	texture.sampler or render.CreateSampler(texture:GetSamplerConfig())
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
				table.insert(
					debug_views,
					{
						name = format[2][1],
						attachment_index = i,
						swizzle = format[2][2],
					}
				)
			else
				-- Resolve function to get actual format
				if type(format) == "function" then format = format() end

				table.insert(formats, format)
				table.insert(
					debug_views,
					{
						name = format[2][1],
						attachment_index = i,
						swizzle = format[2][2],
					}
				)
			end
		end
	end

	return formats, debug_views
end

local function resolve_draw_frame_index(self, frame_index)
	if frame_index then return frame_index end

	if self.framebuffers and self.framebuffers[2] then
		return system.GetFrameNumber() % #self.framebuffers + 1
	end

	return render.GetCurrentFrame()
end

local function resolve_draw_framebuffer(self, framebuffer, frame_index)
	local fb = framebuffer

	if not fb then
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)

		if resolved_frame_index then
			fb = self:GetFramebuffer(resolved_frame_index)
		elseif self.framebuffers then
			fb = self:GetFramebuffer(system.GetFrameNumber() % #self.framebuffers + 1)
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

local EasyPipeline = prototype.CreateTemplate("render_easy_pipeline")

do
	-- Static methods (shared across all variants)
	EasyPipeline.BuildFFIType = build_ffi_type

	-- Delegate storable variable methods from GraphicsPipeline
	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		EasyPipeline[info.set_name] = function(self, ...)
			return self.pipeline[info.set_name](self.pipeline, ...)
		end
		EasyPipeline[info.get_name] = function(self, ...)
			return self.pipeline[info.get_name](self.pipeline, ...)
		end
	end

	-- Shared instance methods (available on all pipeline variants)
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
		if self.pipeline.SetSamplerConfig then
			return self.pipeline:SetSamplerConfig(config)
		end

		self.sampler_config = config
		return config
	end

	function EasyPipeline:GetSamplerConfig()
		if self.pipeline.GetSamplerConfig then
			return self.pipeline:GetSamplerConfig()
		end

		return self.sampler_config
	end

	function EasyPipeline:SetSamplerConfigValue(key, value)
		if self.pipeline.SetSamplerConfigValue then
			return self.pipeline:SetSamplerConfigValue(key, value)
		end

		self.sampler_config = self.sampler_config or {}
		self.sampler_config[key] = value
		return value
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

	function EasyPipeline:GetFramebuffer(index)
		return self.framebuffers and (self.framebuffers[index] or self.framebuffers[1])
	end

	function EasyPipeline:RecreateFramebuffers()
		create_owned_framebuffers(self)
	end

	function EasyPipeline:OnWindowFramebufferResized()
		if render.target:IsValid() and render.target.config.offscreen then return end

		timer.Delay(
			0.01,
			function()
				self:RecreateFramebuffers()
				-- Update descriptor sets if they reference framebuffer textures
				local textures = {}
				local fb = self.framebuffers[1]

				if fb then
					for _, tex in ipairs(fb.color_textures or {}) do
						table.insert(textures, tex)
					end

					if fb.depth_texture then table.insert(textures, fb.depth_texture) end

					if #textures > 0 and self.pipeline.UpdateDescriptorSetArray then
						for i = 1, #self.pipeline.descriptor_sets do
							self.pipeline:UpdateDescriptorSetArray(i, 0, 1, textures)
						end
					end
				end
			end,
			self
		)
	end
end

local EasyPipelineGraphics = prototype.CreateTemplate("render_easy_pipeline_graphics")

do
	EasyPipelineGraphics.Base = EasyPipeline

	-- Graphics-specific instance methods
	function EasyPipelineGraphics:OnRemove()
		if self.framebuffers then
			for i = 1, #self.framebuffers do
				local fb = self.framebuffers[i]

				if fb then fb:Remove() end
			end

			self.framebuffers = nil
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

	function EasyPipelineGraphics:UploadConstants()
		local cmd = render.GetCommandBuffer()
		local pipeline_key = self.pipeline
		local probe_enabled = upload_probe.IsEnabled()

		for _, name in ipairs(self.push_constant_block_order) do
			local block = self.push_constant_blocks[name]
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			local constants = self.constant_structs[struct_name]
			local offset = self.push_constant_block_offsets[name]
			local constants_size = ffi.sizeof(constants)

			if block.source then
				local source_data = block.source.get(self, block)

				if source_data == nil then
					error("push constant block source returned nil for " .. tostring(block.name))
				end

				ffi.copy(
					constants,
					ffi.cast("uint8_t *", source_data) + block.source.offset,
					constants_size
				)
			end

			if block.write then block.write(self, constants, block) end

			if
				self:ShouldPushConstants(cmd, pipeline_key, self.active_stage_key, offset, constants, constants_size)
			then
				if probe_enabled then
					upload_probe.RecordUpload(block.debug_name, block.field_descriptors, constants, constants_size, true)
				end

				self.pipeline:PushConstants(cmd, self.active_stages, offset, constants)
				self:NotePushConstants(cmd, pipeline_key, self.active_stage_key, offset, constants, constants_size)
			end
		end

		local offsets = {}
		local frame_index = render.GetCurrentFrame()
		local frame_number = system.GetFrameNumber and system.GetFrameNumber() or 0

		for i, name in ipairs(self.uniform_buffer_order) do
			local info = self.uniform_buffer_types[name]
			local offset = nil
			local cache_key = nil
			local cache_hit = false
			local persistent_entry = nil
			local persistent_entries = nil
			local upload_scope = info.block.upload_scope

			if upload_scope == "frame" then
				cache_key = true
			elseif
				(
					upload_scope == "frame_keyed" or
					upload_scope == "persistent_keyed"
				)
				and
				info.block.upload_key
			then
				cache_key = info.block.upload_key(self, info.block)
			end

			if cache_key ~= nil then
				local cache = info.offsets

				if upload_scope == "frame" then
					if cache.frame_number == frame_number and cache.key == cache_key then
						offset = cache.offset
					end

					cache_hit = offset ~= nil
				elseif upload_scope == "frame_keyed" then
					if cache.frame_number ~= frame_number then
						cache.frame_number = frame_number
						cache.strong_entries = {}
						cache.weak_entries = setmetatable({}, {__mode = "k"})
					end

					local key_type = type(cache_key)
					local entries = (
							key_type == "table" or
							key_type == "userdata"
						)
						and
						cache.weak_entries or
						cache.strong_entries
					offset = entries[cache_key]
					cache_hit = offset ~= nil
				elseif upload_scope == "persistent_keyed" then
					cache.strong_entries = cache.strong_entries or {}
					cache.weak_entries = cache.weak_entries or setmetatable({}, {__mode = "k"})
					local key_type = type(cache_key)
					persistent_entries = (
							key_type == "table" or
							key_type == "userdata"
						)
						and
						cache.weak_entries or
						cache.strong_entries
					persistent_entry = persistent_entries[cache_key]

					if persistent_entry then
						offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
					end
				end
			end

			if upload_scope == "persistent_keyed" and cache_key ~= nil then
				local ubo_data = info.ubo:GetData()

				if info.block.source then
					local source_data = info.block.source.get(self, info.block)

					if source_data == nil then
						error("uniform buffer block source returned nil for " .. tostring(info.block.name))
					end

					ffi.copy(
						ubo_data,
						ffi.cast("uint8_t *", source_data) + info.block.source.offset,
						ffi.sizeof(ubo_data)
					)
				end

				if info.block.write then info.block.write(self, ubo_data, info.block) end

				local src = ffi.cast("uint8_t *", ubo_data)

				if
					persistent_entry and
					persistent_entry.snapshot and
					self.BytesEqual(persistent_entry.snapshot, src, info.ubo.size)
				then
					cache_hit = true
					offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
				else
					cache_hit = false

					if probe_enabled then
						upload_probe.RecordUpload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)
					end

					if persistent_entry == nil then
						persistent_entry = {
							slot = info.ubo:AllocatePersistentSlot(),
							snapshot = ffi.new("uint8_t[?]", info.ubo.size),
						}
						persistent_entries[cache_key] = persistent_entry
					end

					info.ubo:UploadPersistent(persistent_entry.slot)
					ffi.copy(persistent_entry.snapshot, src, info.ubo.size)
					offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
				end
			elseif offset == nil then
				local ubo_data = info.ubo:GetData()

				if info.block.source then
					local source_data = info.block.source.get(self, info.block)

					if source_data == nil then
						error("uniform buffer block source returned nil for " .. tostring(info.block.name))
					end

					ffi.copy(
						ubo_data,
						ffi.cast("uint8_t *", source_data) + info.block.source.offset,
						ffi.sizeof(ubo_data)
					)
				end

				if info.block.write then info.block.write(self, ubo_data, info.block) end

				if probe_enabled then
					upload_probe.RecordUpload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)
				end

				offset = info.ubo:Upload(frame_index)

				if upload_scope == "frame" then
					local cache = info.offsets
					cache.frame_number = frame_number
					cache.key = true
					cache.offset = offset
				elseif upload_scope == "frame_keyed" and cache_key ~= nil then
					local cache = info.offsets

					if cache.frame_number ~= frame_number then
						cache.frame_number = frame_number
						cache.strong_entries = {}
						cache.weak_entries = setmetatable({}, {__mode = "k"})
					end

					local key_type = type(cache_key)
					local entries = (
							key_type == "table" or
							key_type == "userdata"
						)
						and
						cache.weak_entries or
						cache.strong_entries
					entries[cache_key] = offset
				end
			end

			if probe_enabled then
				upload_probe.RecordCacheAccess(info.debug_name, cache_key, cache_hit)
			end

			offsets[i] = offset
		end

		self.dynamic_offsets = #offsets > 0 and offsets or nil

		if self.dynamic_offsets then
			self.pipeline:Bind(cmd, frame_index, self.dynamic_offsets)
		end
	end

	-- Begin drawing to this pipeline's framebuffer
	-- framebuffer: optional custom framebuffer to use (defaults to pipeline's framebuffer)
	-- frame_index: optional frame index for ping-pong buffers (defaults to auto-calculated)
	function EasyPipelineGraphics:BeginDraw(cmd, framebuffer, frame_index)
		cmd = cmd or render.GetCommandBuffer()
		local fb = resolve_draw_framebuffer(self, framebuffer, frame_index)
		begin_draw(self, cmd, fb, frame_index)
		return fb
	end

	-- End drawing (must be paired with BeginDraw)
	function EasyPipelineGraphics:EndDraw(cmd, framebuffer)
		cmd = cmd or render.GetCommandBuffer()

		if framebuffer then framebuffer:End(cmd) end
	end

	-- Complete draw call with automatic framebuffer handling
	-- framebuffer: optional custom framebuffer to use
	-- frame_index: optional frame index for ping-pong buffers
	-- vertex_count: optional vertex count (defaults to 3 for fullscreen quad)
	function EasyPipelineGraphics:Draw(cmd, framebuffer, frame_index, vertex_count)
		cmd = cmd or render.GetCommandBuffer()
		vertex_count = vertex_count or 3
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
		local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)
		render.PushCommandBuffer(cmd)
		local began_framebuffer = fb ~= nil

		if self.on_pre_draw then self.on_pre_draw(self, cmd, resolved_frame_index) end

		begin_draw(self, cmd, fb, resolved_frame_index)

		if self.on_draw then
			self.on_draw(self, cmd)
		else
			self:UploadConstants()
			cmd:Draw(vertex_count, 1, 0, 0)
		end

		if began_framebuffer then self:EndDraw(cmd, fb) end

		render.PopCommandBuffer()
	end

	function EasyPipelineGraphics:DrawMeshTasks(gx, gy, gz, cmd, framebuffer, frame_index)
		cmd = cmd or render.GetCommandBuffer()
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
		local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)
		render.PushCommandBuffer(cmd)
		local began_framebuffer = fb ~= nil
		local ok, err = xpcall(
			function()
				begin_draw(self, cmd, fb, resolved_frame_index)
				self:UploadConstants()
				cmd:DrawMeshTasks(gx, gy, gz)
			end,
			debug.traceback
		)

		if began_framebuffer then self:EndDraw(cmd, fb) end

		render.PopCommandBuffer()

		if not ok then error(err, 0) end
	end

	function EasyPipelineGraphics:PushConstants(...)
		return self.pipeline:PushConstants(...)
	end

	-- Graphics constructor
	function EasyPipelineGraphics.New(config)
		if config.ComputePass or config.compute_pass then
			return EasyPipelineCompute.ComputePass(config)
		end

		local self = EasyPipelineGraphics:CreateObject()
		self.on_pre_draw = config.on_pre_draw or nil
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

		if color_formats then
			if type(color_formats) == "string" then color_formats = {color_formats} end

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
			local stage_config = config[stage_name]

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
					local block_type_name = normalize_block_type_name(block.name)
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
			local stage_config = get_constant_stage_config(config, stage)

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
		self.constant_structs = constant_structs
		self.active_stages = active_stages
		self.active_stage_key = active_stage_key
		self.push_constant_blocks = push_constant_blocks
		self.push_constant_block_offsets = push_constant_block_offsets
		self.push_constant_block_order = push_constant_block_order
		self.push_constant_types = push_constant_types
		self.constant_blocks = constant_resolution.blocks
		self.constant_push_budget = constant_resolution.push_budget
		self.uniform_buffer_order = uniform_buffer_order
		self.uniform_buffer_types = uniform_buffer_types
		self.uniform_buffers = uniform_buffers
		-- Push constant caching (graphics-specific optimization)
		local push_constant_cache_by_cmd = setmetatable({}, {__mode = "k"})

		local function bytes_equal(lhs, rhs, size)
			for i = 0, size - 1 do
				if lhs[i] ~= rhs[i] then return false end
			end

			return true
		end

		local function ranges_overlap(lhs_offset, lhs_size, rhs_offset, rhs_size)
			return lhs_offset < rhs_offset + rhs_size and rhs_offset < lhs_offset + rhs_size
		end

		local function get_push_constant_entries(cmd)
			local serial = cmd and cmd.recording_serial or 0
			local cache = push_constant_cache_by_cmd[cmd]

			if cache and cache.serial == serial then return cache.entries end

			cache = {
				serial = serial,
				entries = {},
			}
			push_constant_cache_by_cmd[cmd] = cache
			return cache.entries
		end

		function self:ShouldPushConstants(cmd, pipeline_key, stage_key, offset, data, size)
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

		function self:NotePushConstants(cmd, pipeline_key, stage_key, offset, data, size)
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

		self.BytesEqual = bytes_equal
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
						local attribute_lua_type = GLSL_TO_LUA_TYPE[attribute_type]
						local location_count = get_vertex_attribute_location_count(attribute_type)
						local attribute_size = location_count * render.GetVulkanFormatSize(attribute_type == "mat4" and "r32g32b32a32_sfloat" or attribute_format)
						local attribute_offset = attribute[4]

						if attribute_offset == nil then attribute_offset = stride end

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
						stride = math.max(stride, attribute_offset + attribute_size)
						location = location + location_count
					end

					if #binding_attributes > 0 then
						table.insert(
							bindings,
							{
								binding = resolved_binding,
								stride = binding.stride or stride,
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
		local mesh_ext = config.mesh or config.mesh_ext or config.task or config.task_ext
		local shader_header = build_shader_header(
			bindless_texture_capacity,
			bindless_cubemap_capacity,
			mesh_ext and {"#extension GL_EXT_mesh_shader : require"} or nil
		)
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
		local descriptor_sets = build_base_descriptor_sets(bindless_texture_capacity, bindless_cubemap_capacity)
		-- Add uniform buffers from and descriptors from all stages
		local uniform_buffer_order_desc = {}

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
						table.insert(uniform_buffer_order_desc, block.name)
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
		local sanitized_color_blend = sanitize_color_blend_attachments(color_blend.attachments)
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

	EasyPipelineGraphics:Register()
end

local EasyPipelineCompute = prototype.CreateTemplate("render_easy_pipeline_compute")

do
	EasyPipelineCompute.Base = EasyPipeline

	-- Compute-specific instance methods
	function EasyPipelineCompute:OnRemove()
		if self.framebuffers then
			for i = 1, #self.framebuffers do
				local fb = self.framebuffers[i]

				if fb then fb:Remove() end
			end

			self.framebuffers = nil
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

	function EasyPipelineCompute:UploadConstants()
		self.dynamic_offsets = nil

		if self.uniform_buffer_order[1] then
			local offsets = {}
			local frame_index = render.GetCurrentFrame() or 1

			for i, name in ipairs(self.uniform_buffer_order) do
				local info = self.uniform_buffer_types[name]
				local data = info.ubo:GetData()

				if info.block.source then
					local source_data = info.block.source.get(self, info.block)

					if source_data == nil then
						error("compute uniform buffer source returned nil for " .. tostring(info.block.name), 2)
					end

					ffi.copy(
						data,
						ffi.cast("uint8_t *", source_data) + info.block.source.offset,
						ffi.sizeof(data)
					)
				end

				if info.block.write then info.block.write(self, data, info.block) end

				offsets[i] = info.ubo:Upload(frame_index)
			end

			self.dynamic_offsets = offsets
		end

		if not self.push_constant_data then return end

		if self.push_constant_source then
			local source_data = self.push_constant_source.get(self, self.push_constant_source)

			if source_data == nil then
				error("compute push constant source returned nil", 2)
			end

			ffi.copy(
				self.push_constant_data,
				ffi.cast("uint8_t *", source_data) + (self.push_constant_source.offset or 0),
				self.push_constant_size
			)
		end

		if self.push_constant_write then
			self.push_constant_write(self, self.push_constant_data)
		end

		self.pipeline:PushConstants(
			render.GetCommandBuffer(),
			{"compute"},
			0,
			self.push_constant_data,
			self.push_constant_size
		)
	end

	function EasyPipelineCompute:Dispatch(cmd, group_count_x, group_count_y, group_count_z, frame_index, dynamic_offsets)
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
				dynamic_offsets or self.dynamic_offsets
			)
		end

		render.PopCommandBuffer()
	end

	function EasyPipelineCompute:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
		if not self.pipeline or not self.pipeline.DispatchForSize then
			error("EasyPipeline:DispatchForSize is only available for compute pipelines", 2)
		end

		cmd = cmd or render.GetCommandBuffer()
		render.PushCommandBuffer(cmd)

		if self.on_draw then
			self.on_draw(self, cmd)
		else
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				width,
				height,
				depth,
				frame_index,
				dynamic_offsets or self.dynamic_offsets
			)
		end

		render.PopCommandBuffer()
	end

	-- Compute constructor
	function EasyPipelineCompute.Compute(config)
		local write = config.write
		local source = config.source

		if type(config.block) == "table" then
			write = write or config.block.write
			source = source or config.block.source
		end

		local self = EasyPipelineCompute:CreateObject()
		self.on_draw = config.on_draw or nil
		self.config = config
		local block = config.block or {}
		local flat_push_constant_block = #block > 0 and flatten_fields(block) or block
		local push_constant_type
		local push_constant_size = 0
		local push_constant_field_descriptors
		local uniform_buffers = {}
		local uniform_buffer_types = {}
		local uniform_buffer_order = {}

		if #block > 0 then
			push_constant_type = EasyPipeline.BuildFFIType("scalar", "ComputeConstants", flat_push_constant_block)
			push_constant_size = ffi.sizeof(push_constant_type)
			push_constant_field_descriptors = build_field_descriptors(push_constant_type, flat_push_constant_block)
		end

		self.push_constant_data = push_constant_type and push_constant_type() or nil
		self.push_constant_size = push_constant_size
		self.push_constant_source = source
		self.push_constant_write = write
		self.uniform_buffer_order = uniform_buffer_order
		self.uniform_buffer_types = uniform_buffer_types
		self.uniform_buffers = uniform_buffers
		local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
		local bindless_texture_capacity = bindless_descriptor_capacities.textures
		local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
		local shader_header = build_shader_header(bindless_texture_capacity, bindless_cubemap_capacity)
		local push_constant_glsl = ""

		if #block > 0 then
			push_constant_glsl = "layout(push_constant, scalar) uniform ComputeConstants {\n" .. build_glsl_fields(flat_push_constant_block) .. "} compute;\n\n"
		end

		local descriptor_sets = build_base_descriptor_sets(bindless_texture_capacity, bindless_cubemap_capacity)

		for _, ds in ipairs(config.descriptor_sets or {}) do
			descriptor_sets[#descriptor_sets + 1] = ds
		end

		for _, block_info in ipairs(config.uniform_buffers or {}) do
			if block_info.name == nil then
				error("EasyPipeline.Compute: uniform buffer is missing a name", 2)
			end

			local info = {}

			for key, value in pairs(block_info) do
				info[key] = value
			end

			if info.binding_index == nil then
				error(
					"EasyPipeline.Compute: uniform buffer " .. tostring(info.name) .. " is missing binding_index",
					2
				)
			end

			hoist_inline_block_metadata(info)
			info.block = flatten_fields(info.block)

			if not info.block[1] then
				error(
					"EasyPipeline.Compute: uniform buffer " .. tostring(info.name) .. " has no fields",
					2
				)
			end

			local ffi_code = build_ffi_struct("scalar", info.block)
			local glsl_fields, glsl_structs = build_glsl_fields(info.block)
			local ubo = UniformBuffer.New(ffi_code)
			info.source = normalize_block_source(
				info,
				ffi.sizeof(ubo.struct),
				get_scalar_block_alignment(info.block),
				"uniform buffer block"
			)
			local block_type_name = normalize_block_type_name(info.name)
			uniform_buffer_order[#uniform_buffer_order + 1] = info.name
			uniform_buffer_types[info.name] = {
				ubo = ubo,
				block = info,
				debug_name = (config.name or "pipeline") .. ".ubo." .. info.name,
				field_descriptors = build_field_descriptors(ubo.struct, info.block),
				glsl = string.format(
					"%slayout(scalar, set = %d, binding = %d) uniform %s {\n%s} %s;",
					glsl_structs,
					info.set_index or 0,
					info.binding_index,
					block_type_name,
					glsl_fields,
					info.name
				),
			}
			uniform_buffers[info.name] = ubo
			descriptor_sets[#descriptor_sets + 1] = {
				type = "uniform_buffer_dynamic",
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				args = {ubo.buffer, ubo.aligned_size},
			}
		end

		local local_size = config.LocalSize or config.local_size or config.workgroup_size
		local local_size_glsl = ""
		local uniform_buffer_glsl = ""

		if local_size then
			if type(local_size) == "number" then
				local_size = {x = local_size, y = local_size, z = 1}
			else
				local_size = {
					x = local_size.x or local_size[1] or 8,
					y = local_size.y or local_size[2] or 8,
					z = local_size.z or local_size[3] or 1,
				}
			end

			local_size_glsl = string.format(
				"layout(local_size_x = %d, local_size_y = %d, local_size_z = %d) in;\n\n",
				local_size.x,
				local_size.y,
				local_size.z
			)
		end

		for _, name in ipairs(uniform_buffer_order) do
			uniform_buffer_glsl = uniform_buffer_glsl .. uniform_buffer_types[name].glsl .. "\n\n"
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
			LocalSize = local_size,
			shader_stages = {
				{
					type = "compute",
					code = shader_header .. (
							config.custom_declarations or
							""
						) .. local_size_glsl .. push_constant_glsl .. uniform_buffer_glsl .. (
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
		return self
	end

	-- ComputePass: special compute pipeline with framebuffer + image transition handling
	function EasyPipelineCompute.ComputePass(config)
		local compute_config = table.copy(config)
		local storage_images = {}
		local sampled_images = {}
		local output_bindings = config.storage_images or config.StorageImages or {}
		local sampled_bindings = config.sampled_images or config.SampledImages or {}
		local declared_descriptor_sets = {}
		local user_on_draw = config.on_draw or nil

		for _, descriptor in ipairs(config.descriptor_sets or {}) do
			declared_descriptor_sets[#declared_descriptor_sets + 1] = descriptor
		end

		for _, info in ipairs(output_bindings) do
			storage_images[#storage_images + 1] = {
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				attachment = info.attachment,
				get_texture = info.get_texture,
				dst_stage = info.dst_stage,
			}
			declared_descriptor_sets[#declared_descriptor_sets + 1] = {
				type = "storage_image",
				binding_index = info.binding_index,
				stageFlags = info.stageFlags or "compute",
				set_index = info.set_index or 0,
			}
		end

		for _, info in ipairs(sampled_bindings) do
			sampled_images[#sampled_images + 1] = {
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				get_texture = info.get_texture,
				get_descriptor = info.get_descriptor,
			}
			declared_descriptor_sets[#declared_descriptor_sets + 1] = {
				type = "combined_image_sampler",
				binding_index = info.binding_index,
				stageFlags = info.stageFlags or "compute",
				set_index = info.set_index or 0,
			}
		end

		compute_config.descriptor_sets = declared_descriptor_sets
		compute_config.on_draw = nil
		local compute_pass_frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
		local compute_pass_slots_per_frame = config.DescriptorSetsPerFrame or config.descriptor_sets_per_frame or 16

		if
			compute_config.DescriptorSetCount == nil and
			compute_config.descriptor_set_count == nil
		then
			compute_config.DescriptorSetCount = math.max(
				compute_pass_frame_span * compute_pass_slots_per_frame,
				config.framebuffer_count or 1,
				compute_pass_frame_span
			)
		end

		local self = EasyPipelineCompute.Compute(compute_config)
		self.config = config
		self.actual_color_formats, self.debug_views = get_color_formats(config)
		self.on_pre_draw = config.on_pre_draw or nil
		self.on_draw = user_on_draw
		self.storage_images = storage_images
		self.sampled_images = sampled_images
		self.compute_pass_frame_span = compute_pass_frame_span
		self.compute_pass_slots_per_frame = compute_pass_slots_per_frame

		if
			not config.dont_create_framebuffers and
			(
				#self.actual_color_formats > 0 or
				config.DepthFormat
			)
		then
			create_owned_framebuffers(self, {color_image_usage = {"storage"}})

			if not self.config.FramebufferSize then
				self:AddGlobalEvent("WindowFramebufferResized")
			end
		end

		function self:RecreateFramebuffers()
			create_owned_framebuffers(self, {color_image_usage = {"storage"}})
		end

		function self:Draw(cmd, framebuffer, frame_index)
			cmd = cmd or render.GetCommandBuffer()
			local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
			local descriptor_count = self:GetDescriptorSetCount()
			local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)

			if not fb then
				error(
					"EasyPipeline.ComputePass: Draw requires an owned framebuffer or explicit framebuffer",
					2
				)
			end

			render.PushCommandBuffer(cmd)
			local current_frame_index = render.GetCurrentFrame() or frame_index or 1

			if current_frame_index < 1 then current_frame_index = 1 end

			if current_frame_index > self.compute_pass_frame_span then
				current_frame_index = ((current_frame_index - 1) % self.compute_pass_frame_span) + 1
			end

			if self._compute_pass_descriptor_cmd ~= cmd then
				self._compute_pass_descriptor_cmd = cmd
				self._compute_pass_descriptor_slot = 0
			end

			local descriptor_slot = (self._compute_pass_descriptor_slot or 0) + 1
			local descriptor_frame_index = ((current_frame_index - 1) * self.compute_pass_slots_per_frame) + descriptor_slot

			if
				descriptor_count and
				descriptor_count > 0 and
				descriptor_frame_index > descriptor_count
			then
				error(
					string.format(
						"EasyPipeline.ComputePass: descriptor set ring exhausted for frame %d (%d > %d)",
						current_frame_index,
						descriptor_frame_index,
						descriptor_count
					),
					2
				)
			end

			self._compute_pass_descriptor_slot = descriptor_slot
			local transitioned = {}

			if self.on_pre_draw then
				self.on_pre_draw(self, cmd, resolved_frame_index, descriptor_frame_index)
			end

			for _, info in ipairs(self.storage_images) do
				local texture = info.get_texture and
					info.get_texture(self, fb, resolved_frame_index) or
					fb:GetAttachment(info.attachment or 1)
				assert(
					texture,
					self.name .. " is missing compute output texture for binding " .. tostring(info.binding_index)
				)
				transition_texture_to_compute_storage(texture, cmd)
				self:UpdateDescriptorSet(
					"storage_image",
					descriptor_frame_index,
					info.binding_index,
					info.set_index,
					texture:GetView()
				)
				transitioned[#transitioned + 1] = {
					texture = texture,
					dst_stage = info.dst_stage,
				}
			end

			for _, info in ipairs(self.sampled_images) do
				local view
				local sampler

				if info.get_descriptor then
					local descriptor = info.get_descriptor(self, fb, resolved_frame_index)

					if type(descriptor) == "table" then
						view = descriptor[1]
						sampler = descriptor[2]
					end
				elseif info.get_texture then
					view, sampler = get_compute_sampled_descriptor(info.get_texture(self, fb, resolved_frame_index))
				else
					view, sampler = get_compute_sampled_descriptor(nil)
				end

				if not view or not sampler then
					view, sampler = get_compute_sampled_descriptor(nil)
				end

				self:UpdateDescriptorSet(
					"combined_image_sampler",
					descriptor_frame_index,
					info.binding_index,
					info.set_index,
					view,
					sampler
				)
			end

			if self.on_draw then
				self.on_draw(self, cmd, fb, resolved_frame_index, descriptor_frame_index)
			else
				self:UploadConstants()
				self.pipeline:DispatchForSize(
					cmd,
					fb.width,
					fb.height,
					1,
					descriptor_frame_index,
					self.dynamic_offsets
				)
			end

			for _, info in ipairs(transitioned) do
				transition_texture_from_compute_storage(info.texture, cmd, info.dst_stage)
			end

			render.PopCommandBuffer()
		end

		return self
	end

	EasyPipelineCompute:Register()
end

function EasyPipeline.New(config)
	if config.ComputePass or config.compute_pass then
		return EasyPipelineCompute.ComputePass(config)
	end

	return EasyPipelineGraphics.New(config)
end

EasyPipeline.Compute = EasyPipelineCompute.Compute
EasyPipeline.ComputePass = EasyPipelineCompute.ComputePass
return EasyPipeline:Register()
