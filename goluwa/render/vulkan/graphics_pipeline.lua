local prototype = import("goluwa/prototype.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local InternalGraphicsPipeline = import("goluwa/render/vulkan/internal/graphics_pipeline.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local GraphicsPipeline = prototype.CreateTemplate("render_graphics_pipeline")
local NIL_VALUE = {}
local ID_LEAF = {}
local RASTERIZER_STATE_KEYS = {
	polygon_mode = true,
	cull_mode = true,
	front_face = true,
	depth_bias = true,
	depth_bias_constant_factor = true,
	depth_bias_clamp = true,
	depth_bias_slope_factor = true,
	line_width = true,
	depth_clamp = true,
	discard = true,
}
local STENCIL_FACE_KEYS = {
	fail_op = true,
	pass_op = true,
	depth_fail_op = true,
	compare_op = true,
	reference = true,
	compare_mask = true,
	write_mask = true,
}
local DEPTH_STENCIL_STATE_KEYS = {
	depth_test = true,
	depth_write = true,
	depth_compare_op = true,
	depth_bounds_test = true,
	stencil_test = true,
	front = true,
	back = true,
}
local VIEWPORT_STATE_KEYS = {
	x = true,
	y = true,
	w = true,
	h = true,
	min_depth = true,
	max_depth = true,
}
local SCISSOR_STATE_KEYS = {
	x = true,
	y = true,
	w = true,
	h = true,
}
local MULTISAMPLING_STATE_KEYS = {
	rasterization_samples = true,
	sample_shading = true,
	min_sample_shading = true,
}
local COLOR_BLEND_ATTACHMENT_KEYS = {
	blend = true,
	src_color_blend_factor = true,
	dst_color_blend_factor = true,
	color_blend_op = true,
	src_alpha_blend_factor = true,
	dst_alpha_blend_factor = true,
	alpha_blend_op = true,
	color_write_mask = true,
}
local COLOR_BLEND_STATE_KEYS = {
	blend = true,
	src_color_blend_factor = true,
	dst_color_blend_factor = true,
	color_blend_op = true,
	src_alpha_blend_factor = true,
	dst_alpha_blend_factor = true,
	alpha_blend_op = true,
	color_write_mask = true,
	logic_op_enabled = true,
	logic_op = true,
	constants = true,
	attachments = true,
}
local TOPOLOGIES = {
	"point_list",
	"line_list",
	"line_strip",
	"triangle_list",
	"triangle_strip",
	"triangle_fan",
	"line_list_with_adjacency",
	"line_strip_with_adjacency",
	"triangle_list_with_adjacency",
	"triangle_strip_with_adjacency",
	"patch_list",
}
local INPUT_ASSEMBLY_STATE_KEYS = {
	topology = true,
	primitive_restart = true,
}
local STENCIL_FACE_DEFAULTS = {
	fail_op = "keep",
	pass_op = "keep",
	depth_fail_op = "keep",
	compare_op = "always",
	reference = 0,
	compare_mask = 0xFF,
	write_mask = 0xFF,
}
local POLYGON_MODES = {"fill", "line", "point"}
local CULL_MODES = {"none", "front", "back", "front_and_back"}
local FRONT_FACES = {"clockwise", "counter_clockwise"}
local COMPARE_OPS = {
	"never",
	"less",
	"equal",
	"less_or_equal",
	"greater",
	"not_equal",
	"greater_or_equal",
	"always",
}
local STENCIL_OPS = {
	"keep",
	"zero",
	"replace",
	"increment_and_clamp",
	"decrement_and_clamp",
	"invert",
	"increment_and_wrap",
	"decrement_and_wrap",
}
local BLEND_FACTORS = {
	"zero",
	"one",
	"src_color",
	"one_minus_src_color",
	"dst_color",
	"one_minus_dst_color",
	"src_alpha",
	"one_minus_src_alpha",
	"dst_alpha",
	"one_minus_dst_alpha",
	"constant_color",
	"one_minus_constant_color",
	"constant_alpha",
	"one_minus_constant_alpha",
	"src_alpha_saturate",
	"src1_color",
	"one_minus_src1_color",
	"src1_alpha",
	"one_minus_src1_alpha",
}
local BLEND_OPS = {"add", "subtract", "reverse_subtract", "min", "max"}
local LOGIC_OPS = {
	"clear",
	"and",
	"and_reverse",
	"copy",
	"and_inverted",
	"noop",
	"xor",
	"or",
	"nor",
	"equivalent",
	"invert",
	"or_reverse",
	"copy_inverted",
	"or_inverted",
	"nand",
	"set",
}
local COLOR_MASK_CHANNELS = {"r", "g", "b", "a", "R", "G", "B", "A"}
local PROPERTY_DYNAMIC_STATE_KEYS = {
	input_assembly = {
		primitive_restart = "primitive_restart_enable",
	},
	rasterizer = {
		polygon_mode = "polygon_mode_ext",
		cull_mode = "cull_mode",
		front_face = "front_face",
		depth_bias = "depth_bias_enable",
		depth_bias_constant_factor = "depth_bias",
		depth_bias_clamp = "depth_bias",
		depth_bias_slope_factor = "depth_bias",
		depth_clamp = "depth_clamp_enable_ext",
		discard = "rasterizer_discard_enable",
	},
	depth_stencil = {
		depth_test = "depth_test_enable",
		depth_write = "depth_write_enable",
		depth_compare_op = "depth_compare_op",
		stencil_test = "stencil_test_enable",
	},
	viewport = {
		x = "viewport",
		y = "viewport",
		w = "viewport",
		h = "viewport",
		min_depth = "viewport",
		max_depth = "viewport",
	},
	scissor = {
		x = "scissor",
		y = "scissor",
		w = "scissor",
		h = "scissor",
	},
	color_blend = {
		blend = "color_blend_enable_ext",
		src_color_blend_factor = "color_blend_equation_ext",
		dst_color_blend_factor = "color_blend_equation_ext",
		color_blend_op = "color_blend_equation_ext",
		src_alpha_blend_factor = "color_blend_equation_ext",
		dst_alpha_blend_factor = "color_blend_equation_ext",
		alpha_blend_op = "color_blend_equation_ext",
		color_write_mask = "color_write_mask_ext",
		logic_op_enabled = "logic_op_enable_ext",
		logic_op = "logic_op_ext",
	},
}
local STENCIL_FACE_DYNAMIC_STATE_KEYS = {
	fail_op = "stencil_op",
	pass_op = "stencil_op",
	depth_fail_op = "stencil_op",
	compare_op = "stencil_op",
	reference = "stencil_reference",
	compare_mask = "stencil_compare_mask",
	write_mask = "stencil_write_mask",
}

local function copy_list(values)
	if type(values) ~= "table" then return values end

	local out = {}

	for i = 1, #values do
		out[i] = values[i]
	end

	return out
end

do
	GraphicsPipeline:StartStorable()
	GraphicsPipeline:GetSet(
		"Topology",
		"triangle_list",
		{path = "input_assembly.topology", enums = TOPOLOGIES}
	)
	GraphicsPipeline:GetSet("ViewportX", 0, {path = "viewport.x", validate = "number"})
	GraphicsPipeline:GetSet("ViewportY", 0, {path = "viewport.y", validate = "number"})
	GraphicsPipeline:GetSet("ViewportWidth", 800, {path = "viewport.w", validate = "number"})
	GraphicsPipeline:GetSet("ViewportHeight", 600, {path = "viewport.h", validate = "number"})
	GraphicsPipeline:GetSet("ViewportMinDepth", 0, {path = "viewport.min_depth", validate = "number"})
	GraphicsPipeline:GetSet("ViewportMaxDepth", 1, {path = "viewport.max_depth", validate = "number"})
	GraphicsPipeline:GetSet("ScissorX", 0, {path = "scissor.x", validate = "number"})
	GraphicsPipeline:GetSet("ScissorY", 0, {path = "scissor.y", validate = "number"})
	GraphicsPipeline:GetSet("ScissorWidth", 800, {path = "scissor.w", validate = "number"})
	GraphicsPipeline:GetSet("ScissorHeight", 600, {path = "scissor.h", validate = "number"})
	GraphicsPipeline:GetSet(
		"RasterizationSamples",
		"1",
		{path = "multisampling.rasterization_samples", validate = "string"}
	)
	GraphicsPipeline:GetSet(
		"SampleShading",
		false,
		{path = "multisampling.sample_shading", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"MinSampleShading",
		0,
		{path = "multisampling.min_sample_shading", validate = "number"}
	)
	GraphicsPipeline:GetSet(
		"PrimitiveRestart",
		false,
		{path = "input_assembly.primitive_restart", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"PolygonMode",
		"fill",
		{path = "rasterizer.polygon_mode", enums = POLYGON_MODES}
	)
	GraphicsPipeline:GetSet("CullMode", "back", {path = "rasterizer.cull_mode", enums = CULL_MODES})
	GraphicsPipeline:GetSet(
		"FrontFace",
		"clockwise",
		{path = "rasterizer.front_face", enums = FRONT_FACES}
	)
	GraphicsPipeline:GetSet("DepthBias", false, {path = "rasterizer.depth_bias", validate = "boolean"})
	GraphicsPipeline:GetSet(
		"DepthBiasConstantFactor",
		0,
		{path = "rasterizer.depth_bias_constant_factor", validate = "number"}
	)
	GraphicsPipeline:GetSet(
		"DepthBiasClamp",
		0,
		{path = "rasterizer.depth_bias_clamp", validate = "number"}
	)
	GraphicsPipeline:GetSet(
		"DepthBiasSlopeFactor",
		0,
		{path = "rasterizer.depth_bias_slope_factor", validate = "number"}
	)
	GraphicsPipeline:GetSet("LineWidth", 1, {path = "rasterizer.line_width", validate = "number"})
	GraphicsPipeline:GetSet("DepthClamp", false, {path = "rasterizer.depth_clamp", validate = "boolean"})
	GraphicsPipeline:GetSet("Discard", false, {path = "rasterizer.discard", validate = "boolean"})
	GraphicsPipeline:GetSet("DepthTest", false, {path = "depth_stencil.depth_test", validate = "boolean"})
	GraphicsPipeline:GetSet(
		"DepthWrite",
		false,
		{path = "depth_stencil.depth_write", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"DepthCompareOp",
		"less",
		{path = "depth_stencil.depth_compare_op", enums = COMPARE_OPS}
	)
	GraphicsPipeline:GetSet(
		"DepthBoundsTest",
		false,
		{path = "depth_stencil.depth_bounds_test", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"StencilTest",
		false,
		{path = "depth_stencil.stencil_test", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilFailOp",
		STENCIL_FACE_DEFAULTS.fail_op,
		{
			path = "depth_stencil.front.fail_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilPassOp",
		STENCIL_FACE_DEFAULTS.pass_op,
		{
			path = "depth_stencil.front.pass_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilDepthFailOp",
		STENCIL_FACE_DEFAULTS.depth_fail_op,
		{
			path = "depth_stencil.front.depth_fail_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilCompareOp",
		STENCIL_FACE_DEFAULTS.compare_op,
		{
			path = "depth_stencil.front.compare_op",
			enums = COMPARE_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilReference",
		STENCIL_FACE_DEFAULTS.reference,
		{
			path = "depth_stencil.front.reference",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilCompareMask",
		STENCIL_FACE_DEFAULTS.compare_mask,
		{
			path = "depth_stencil.front.compare_mask",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilWriteMask",
		STENCIL_FACE_DEFAULTS.write_mask,
		{
			path = "depth_stencil.front.write_mask",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilFailOp",
		STENCIL_FACE_DEFAULTS.fail_op,
		{
			path = "depth_stencil.back.fail_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilPassOp",
		STENCIL_FACE_DEFAULTS.pass_op,
		{
			path = "depth_stencil.back.pass_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilDepthFailOp",
		STENCIL_FACE_DEFAULTS.depth_fail_op,
		{
			path = "depth_stencil.back.depth_fail_op",
			enums = STENCIL_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilCompareOp",
		STENCIL_FACE_DEFAULTS.compare_op,
		{
			path = "depth_stencil.back.compare_op",
			enums = COMPARE_OPS,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilReference",
		STENCIL_FACE_DEFAULTS.reference,
		{
			path = "depth_stencil.back.reference",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilCompareMask",
		STENCIL_FACE_DEFAULTS.compare_mask,
		{
			path = "depth_stencil.back.compare_mask",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilWriteMask",
		STENCIL_FACE_DEFAULTS.write_mask,
		{
			path = "depth_stencil.back.write_mask",
			validate = "integer",
		}
	)
	GraphicsPipeline:GetSet("Blend", false, {path = "color_blend.blend", validate = "boolean"})
	GraphicsPipeline:GetSet(
		"SrcColorBlendFactor",
		"one",
		{path = "color_blend.src_color_blend_factor", enums = BLEND_FACTORS}
	)
	GraphicsPipeline:GetSet(
		"DstColorBlendFactor",
		"zero",
		{path = "color_blend.dst_color_blend_factor", enums = BLEND_FACTORS}
	)
	GraphicsPipeline:GetSet(
		"ColorBlendOp",
		"add",
		{path = "color_blend.color_blend_op", enums = BLEND_OPS}
	)
	GraphicsPipeline:GetSet(
		"SrcAlphaBlendFactor",
		"one",
		{path = "color_blend.src_alpha_blend_factor", enums = BLEND_FACTORS}
	)
	GraphicsPipeline:GetSet(
		"DstAlphaBlendFactor",
		"zero",
		{path = "color_blend.dst_alpha_blend_factor", enums = BLEND_FACTORS}
	)
	GraphicsPipeline:GetSet(
		"AlphaBlendOp",
		"add",
		{path = "color_blend.alpha_blend_op", enums = BLEND_OPS}
	)
	GraphicsPipeline:GetSet(
		"ColorWriteMask",
		{"r", "g", "b", "a"},
		{
			path = "color_blend.color_write_mask",
			list_type = "string",
			list_enums = COLOR_MASK_CHANNELS,
			compare = "list",
		}
	)
	GraphicsPipeline:GetSet(
		"LogicOpEnabled",
		false,
		{path = "color_blend.logic_op_enabled", validate = "boolean"}
	)
	GraphicsPipeline:GetSet("LogicOp", "copy", {path = "color_blend.logic_op", enums = LOGIC_OPS})
	GraphicsPipeline:GetSet(
		"BlendConstants",
		{0, 0, 0, 0},
		{
			path = "color_blend.constants",
			list_type = "number",
			list_length = 4,
			compare = "list",
		}
	)
	GraphicsPipeline:EndStorable()
end

local GRAPHICS_PIPELINE_PROPERTY_INFO = {}
local GRAPHICS_PIPELINE_STATE_PROPERTY_INFO = {}
local LEGACY_CONSTRUCTOR_FIELD_NAMES = {
	color_format = "ColorFormat",
	depth_format = "DepthFormat",
	samples = "RasterizationSamples",
	rasterization_samples = "RasterizationSamples",
	descriptor_set_count = "DescriptorSetCount",
	static = "Static",
}

local function assert_no_legacy_constructor_fields(config, level)
	for _, field_name in ipairs{
		"color_format",
		"depth_format",
		"samples",
		"rasterization_samples",
		"descriptor_set_count",
		"static",
	} do
		if config[field_name] ~= nil then
			error(
				string.format(
					"GraphicsPipeline.New: use PascalCase %s instead of snake_case %s",
					LEGACY_CONSTRUCTOR_FIELD_NAMES[field_name],
					field_name
				),
				level or 3
			)
		end
	end

	if config.Samples ~= nil then
		error("GraphicsPipeline.New: use RasterizationSamples instead of Samples", level or 3)
	end

	if
		config.dynamic_state ~= nil or
		config.dynamic_states ~= nil or
		config.DynamicStates ~= nil
	then
		error("GraphicsPipeline.New: dynamic state is handled internally", level or 3)
	end
end

local function get_property_dynamic_state_name(info)
	if info.state_section == "depth_stencil" and info.state_subkey then
		return STENCIL_FACE_DYNAMIC_STATE_KEYS[info.state_subkey]
	end

	local section = PROPERTY_DYNAMIC_STATE_KEYS[info.state_section]
	return section and section[info.state_key] or nil
end

local function get_state_property_entry(section, key)
	local section_info = GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[section]
	return section_info and section_info[key] or nil
end

local function get_state_property_info(section, key, subkey)
	local entry = get_state_property_entry(section, key)

	if subkey ~= nil then
		return type(entry) == "table" and entry[subkey] or nil
	end

	return type(entry) == "table" and entry.var_name and entry or nil
end

local function get_path_value(tbl, path)
	local value = tbl

	for i = 1, #path do
		if type(value) ~= "table" then return nil, false end

		value = value[path[i]]

		if value == nil then return nil, false end
	end

	return value, true
end

local function set_path_value(tbl, path, value)
	local node = tbl

	for i = 1, #path - 1 do
		local key = path[i]
		node[key] = node[key] or {}
		node = node[key]
	end

	node[path[#path]] = value
end

for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
	info.path_string = info.path or
		error("GraphicsPipeline property is missing a path: " .. tostring(info.var_name))
	info.path_keys = info.path_string:split(".")
	info.state_section = info.path_keys[1]
	info.state_key = info.path_keys[2]
	info.state_subkey = info.path_keys[3]
	info.dynamic_state_name = get_property_dynamic_state_name(info)
	info.state_value_path = {info.state_key}

	if info.state_subkey then info.state_value_path[2] = info.state_subkey end

	if
		info.state_section == "color_blend" and
		not info.state_subkey and
		info.state_key ~= "logic_op_enabled" and
		info.state_key ~= "logic_op" and
		info.state_key ~= "constants"
	then
		info.constructor_path_string = info.state_section .. ".attachments[1]." .. info.state_key
		info.constructor_value_path = {"attachments", 1, info.state_key}
		info.is_color_blend_attachment_property = true
	else
		info.constructor_path_string = info.path_string
		info.constructor_value_path = {}

		for i = 2, #info.path_keys do
			info.constructor_value_path[i - 1] = info.path_keys[i]
		end
	end

	GRAPHICS_PIPELINE_PROPERTY_INFO[info.var_name] = info
	GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section] = GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section] or {}

	if info.state_subkey then
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] = GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] or {}
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key][info.state_subkey] = info
	else
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] = info
	end
end

local function get_constructor_property_path(info)
	return info.constructor_path_string
end

local function get_constructor_nested_property_value(config, info)
	local section = config[info.state_section]

	if type(section) ~= "table" then return nil, false end

	return get_path_value(section, info.constructor_value_path)
end

local function set_constructor_property_value(config, info, value)
	value = prototype.ValidatePropertyValue(info, value, 3)
	config[info.var_name] = nil
	local section = config[info.state_section]

	if type(section) ~= "table" then
		section = {}
		config[info.state_section] = section
	end

	set_path_value(
		section,
		info.constructor_value_path,
		info.compare == "list" and copy_list(value) or value
	)
end

local function normalize_constructor_properties(config)
	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		local top_level = config[info.var_name]
		local _, has_nested = get_constructor_nested_property_value(config, info)

		if top_level ~= nil and has_nested then
			error(
				string.format(
					"GraphicsPipeline.New: property %s was provided both as top-level %s and nested %s",
					info.var_name,
					info.var_name,
					get_constructor_property_path(info)
				),
				3
			)
		end

		if has_nested then
			error(
				string.format(
					"GraphicsPipeline.New: use top-level PascalCase property %s instead of nested %s",
					info.var_name,
					get_constructor_property_path(info)
				),
				3
			)
		end

		if top_level ~= nil then
			set_constructor_property_value(config, info, top_level)
		end
	end
end

local function descend_id_node(node, value)
	if value == nil then value = NIL_VALUE end

	local child = node[value]

	if not child then
		child = {}
		node[value] = child
	end

	return child
end

local function finalize_id(self, node, next_id_name)
	local id = node[ID_LEAF]

	if id then return id end

	id = (self[next_id_name] or 0) + 1
	self[next_id_name] = id
	node[ID_LEAF] = id
	return id
end

local function assert_known_keys(section_name, tbl, known)
	if type(tbl) ~= "table" then return end

	for key in pairs(tbl) do
		if not known[key] then
			error(
				"unknown static " .. section_name .. " state key for pipeline cache: " .. tostring(key)
			)
		end
	end
end

local function normalize_color_write_mask(mask)
	if type(mask) ~= "table" then return mask end

	local bits = 0

	for i = 1, #mask do
		local channel = tostring(mask[i]):lower()

		if channel == "r" then
			bits = bit.bor(bits, 1)
		elseif channel == "g" then
			bits = bit.bor(bits, 2)
		elseif channel == "b" then
			bits = bit.bor(bits, 4)
		elseif channel == "a" then
			bits = bit.bor(bits, 8)
		end
	end

	return bits
end

local function normalize_attachment_format(entry)
	return type(entry) == "table" and entry[1] or entry or false
end

local function normalize_enabled(value)
	return value ~= nil and value ~= false and value ~= 0
end

local function descend_number_list(node, values)
	if type(values) ~= "table" then return descend_id_node(node, values) end

	node = descend_id_node(node, #values)

	for i = 1, #values do
		node = descend_id_node(node, values[i])
	end

	return node
end

local function descend_stencil_face(node, face)
	if type(face) ~= "table" then return descend_id_node(node, nil) end

	assert_known_keys("depth_stencil face", face, STENCIL_FACE_KEYS)
	node = descend_id_node(node, face.fail_op)
	node = descend_id_node(node, face.pass_op)
	node = descend_id_node(node, face.depth_fail_op)
	node = descend_id_node(node, face.compare_op)
	node = descend_id_node(node, face.reference)
	node = descend_id_node(node, face.compare_mask)
	node = descend_id_node(node, face.write_mask)
	return node
end

local function get_signature_id(self, signature)
	local node = self.signature_id_root
	local color_format = signature.color_format

	if type(color_format) == "table" then
		node = descend_id_node(node, #color_format)

		for i = 1, #color_format do
			node = descend_id_node(node, normalize_attachment_format(color_format[i]))
		end
	else
		node = descend_id_node(node, 1)
		node = descend_id_node(node, color_format or false)
	end

	node = descend_id_node(node, signature.depth_format or false)
	node = descend_id_node(node, signature.samples or "1")
	return finalize_id(self, node, "next_signature_id")
end

local function get_rasterizer_state_id(self, rasterizer)
	local node = self.rasterizer_state_id_root

	if type(rasterizer) == "table" then
		assert_known_keys("rasterizer", rasterizer, RASTERIZER_STATE_KEYS)
		node = descend_id_node(node, rasterizer.polygon_mode)
		node = descend_id_node(node, rasterizer.cull_mode)
		node = descend_id_node(node, rasterizer.front_face)
		node = descend_id_node(node, rasterizer.depth_bias)
		node = descend_id_node(node, rasterizer.depth_bias_constant_factor)
		node = descend_id_node(node, rasterizer.depth_bias_clamp)
		node = descend_id_node(node, rasterizer.depth_bias_slope_factor)
		node = descend_id_node(node, rasterizer.line_width)
		node = descend_id_node(node, rasterizer.depth_clamp)
		node = descend_id_node(node, rasterizer.discard)
	end

	return finalize_id(self, node, "next_rasterizer_state_id")
end

local function get_depth_stencil_state_id(self, depth_stencil)
	local node = self.depth_stencil_state_id_root

	if type(depth_stencil) == "table" then
		assert_known_keys("depth_stencil", depth_stencil, DEPTH_STENCIL_STATE_KEYS)
		node = descend_id_node(node, depth_stencil.depth_test)
		node = descend_id_node(node, depth_stencil.depth_write)
		node = descend_id_node(node, depth_stencil.depth_compare_op)
		node = descend_id_node(node, depth_stencil.depth_bounds_test)
		node = descend_id_node(node, depth_stencil.stencil_test)
		node = descend_stencil_face(node, depth_stencil.front)
		node = descend_stencil_face(node, depth_stencil.back)
	end

	return finalize_id(self, node, "next_depth_stencil_state_id")
end

local function descend_color_blend_attachment(node, attachment)
	if type(attachment) ~= "table" then return descend_id_node(node, nil) end

	assert_known_keys("color_blend attachment", attachment, COLOR_BLEND_ATTACHMENT_KEYS)
	node = descend_id_node(node, attachment.blend)
	node = descend_id_node(node, attachment.src_color_blend_factor)
	node = descend_id_node(node, attachment.dst_color_blend_factor)
	node = descend_id_node(node, attachment.color_blend_op)
	node = descend_id_node(node, attachment.src_alpha_blend_factor)
	node = descend_id_node(node, attachment.dst_alpha_blend_factor)
	node = descend_id_node(node, attachment.alpha_blend_op)
	node = descend_id_node(node, normalize_color_write_mask(attachment.color_write_mask))
	return node
end

local function get_color_blend_state_id(self, color_blend)
	local node = self.color_blend_state_id_root

	if type(color_blend) == "table" then
		assert_known_keys("color_blend", color_blend, COLOR_BLEND_STATE_KEYS)
		node = descend_id_node(node, color_blend.blend)
		node = descend_id_node(node, color_blend.src_color_blend_factor)
		node = descend_id_node(node, color_blend.dst_color_blend_factor)
		node = descend_id_node(node, color_blend.color_blend_op)
		node = descend_id_node(node, color_blend.src_alpha_blend_factor)
		node = descend_id_node(node, color_blend.dst_alpha_blend_factor)
		node = descend_id_node(node, color_blend.alpha_blend_op)
		node = descend_id_node(node, normalize_color_write_mask(color_blend.color_write_mask))
		node = descend_id_node(node, color_blend.logic_op_enabled)
		node = descend_id_node(node, color_blend.logic_op)
		node = descend_number_list(node, color_blend.constants)
		local attachments = color_blend.attachments
		node = descend_id_node(node, attachments and #attachments or 0)

		if attachments then
			for i = 1, #attachments do
				node = descend_color_blend_attachment(node, attachments[i])
			end
		end
	end

	return finalize_id(self, node, "next_color_blend_state_id")
end

local function get_viewport_state_id(self, viewport)
	local node = self.viewport_state_id_root

	if type(viewport) == "table" then
		assert_known_keys("viewport", viewport, VIEWPORT_STATE_KEYS)
		node = descend_id_node(node, viewport.x)
		node = descend_id_node(node, viewport.y)
		node = descend_id_node(node, viewport.w)
		node = descend_id_node(node, viewport.h)
		node = descend_id_node(node, viewport.min_depth)
		node = descend_id_node(node, viewport.max_depth)
	end

	return finalize_id(self, node, "next_viewport_state_id")
end

local function get_scissor_state_id(self, scissor)
	local node = self.scissor_state_id_root

	if type(scissor) == "table" then
		assert_known_keys("scissor", scissor, SCISSOR_STATE_KEYS)
		node = descend_id_node(node, scissor.x)
		node = descend_id_node(node, scissor.y)
		node = descend_id_node(node, scissor.w)
		node = descend_id_node(node, scissor.h)
	end

	return finalize_id(self, node, "next_scissor_state_id")
end

local function get_multisampling_state_id(self, multisampling)
	local node = self.multisampling_state_id_root

	if type(multisampling) == "table" then
		assert_known_keys("multisampling", multisampling, MULTISAMPLING_STATE_KEYS)
		node = descend_id_node(node, multisampling.rasterization_samples)
		node = descend_id_node(node, multisampling.sample_shading)
		node = descend_id_node(node, multisampling.min_sample_shading)
	end

	return finalize_id(self, node, "next_multisampling_state_id")
end

local function get_pipeline_variant_id(
	self,
	signature_id,
	input_assembly_state_id,
	multisampling_state_id,
	rasterizer_state_id,
	depth_stencil_state_id,
	viewport_state_id,
	scissor_state_id,
	color_blend_state_id
)
	local node = self.pipeline_variant_id_root
	node = descend_id_node(node, signature_id)
	node = descend_id_node(node, input_assembly_state_id)
	node = descend_id_node(node, multisampling_state_id)
	node = descend_id_node(node, rasterizer_state_id)
	node = descend_id_node(node, depth_stencil_state_id)
	node = descend_id_node(node, viewport_state_id)
	node = descend_id_node(node, scissor_state_id)
	node = descend_id_node(node, color_blend_state_id)
	return finalize_id(self, node, "next_pipeline_variant_id")
end

local function get_input_assembly_state_id(self, input_assembly)
	local node = self.input_assembly_state_id_root

	if type(input_assembly) == "table" then
		assert_known_keys("input_assembly", input_assembly, INPUT_ASSEMBLY_STATE_KEYS)
		node = descend_id_node(node, input_assembly.topology)
		node = descend_id_node(node, input_assembly.primitive_restart)
	end

	return finalize_id(self, node, "next_input_assembly_state_id")
end

local function has_static_state_change(self, info)
	return info.dynamic_state_name == nil or
		not self.dynamic_states[info.dynamic_state_name]
end

local function has_static_override_change(self, section, key, value)
	local info = get_state_property_info(section, key)

	if info then return has_static_state_change(self, info) end

	local entry = get_state_property_entry(section, key)

	if type(value) ~= "table" or type(entry) ~= "table" then return true end

	for subkey in pairs(value) do
		info = entry[subkey]

		if info == nil or has_static_state_change(self, info) then return true end
	end

	return false
end

local function get_active_config(self)
	return self.active_config or self.config
end

local function get_color_attachment_count(self)
	local config = get_active_config(self)

	if type(config.ColorFormat) == "table" then
		return math.max(#config.ColorFormat, 1)
	end

	return 1
end

local function get_config_state(config, section, key, subkey)
	if section == "color_blend" then
		local cb = config.color_blend

		if cb and cb.attachments and cb.attachments[1] then
			if key == "blend" then return cb.attachments[1].blend end

			if cb.attachments[1][key] ~= nil then return cb.attachments[1][key] end
		end
	end

	if config[section] and config[section][key] ~= nil then
		local val = config[section][key]

		if subkey and type(val) == "table" then return val[subkey] end

		return val
	end

	return nil
end

local function get_state(self, section, key, subkey)
	local config = get_active_config(self)

	if self.overridden_state[section] and self.overridden_state[section][key] ~= nil then
		local val = self.overridden_state[section][key]

		if subkey and type(val) == "table" and val[subkey] ~= nil then
			return val[subkey]
		end

		return val
	end

	return get_config_state(config, section, key, subkey)
end

local function get_default_state_value(info)
	if info.compare == "list" then return copy_list(info.default) end

	return info.default
end

local function get_property_effective_value(self, info)
	local value = get_state(self, info.state_section, info.state_key, info.state_subkey)

	if value == nil then return get_default_state_value(info) end

	if info.compare == "list" then return copy_list(value) end

	return value
end

local function get_effective_stencil_face(self, face)
	local out = {}

	for key, default in pairs(STENCIL_FACE_DEFAULTS) do
		local value = get_state(self, "depth_stencil", face, key)
		out[key] = value == nil and default or value
	end

	return out
end

local function store_property_override(self, info, value)
	local section_name = info.state_section
	local key = info.state_key
	local subkey = info.state_subkey
	local section_overrides = self.overridden_state[section_name] or {}
	local changed_static = has_static_state_change(self, info)
	local stored_value = info.compare == "list" and copy_list(value) or value

	if subkey then
		section_overrides[key] = get_effective_stencil_face(self, key)
	end

	set_path_value(section_overrides, info.state_value_path, stored_value)
	self.overridden_state[section_name] = section_overrides
	self.bind_state_dirty = true

	if changed_static then self.static_variant_dirty = true end
end

local function get_color_blend_enable(self, index)
	local overridden_color_blend = self.overridden_state.color_blend

	if overridden_color_blend and overridden_color_blend.attachments then
		local attachment = overridden_color_blend.attachments[index]

		if attachment and attachment.blend ~= nil then
			return normalize_enabled(attachment.blend)
		end
	end

	local color_blend = get_active_config(self).color_blend

	if color_blend and color_blend.attachments then
		local attachment = color_blend.attachments[index]

		if attachment and attachment.blend ~= nil then
			return normalize_enabled(attachment.blend)
		end

		local default_attachment = color_blend.attachments[1]

		if default_attachment and default_attachment.blend ~= nil then
			return normalize_enabled(default_attachment.blend)
		end
	end

	if overridden_color_blend and overridden_color_blend.blend ~= nil then
		return normalize_enabled(overridden_color_blend.blend)
	end

	if color_blend and color_blend.attachments and color_blend.attachments[1] then
		return normalize_enabled(color_blend.attachments[1].blend)
	end

	return false
end

local function get_color_blend_state(self, index, key, default)
	local overridden_color_blend = self.overridden_state.color_blend

	if overridden_color_blend and overridden_color_blend.attachments then
		local attachment = overridden_color_blend.attachments[index]

		if attachment and attachment[key] ~= nil then return attachment[key] end
	end

	local val = get_state(self, "color_blend", key)

	if val ~= nil then return val end

	local color_blend = get_active_config(self).color_blend

	if color_blend and color_blend.attachments then
		local attachment = color_blend.attachments[index]

		if attachment and attachment[key] ~= nil then return attachment[key] end

		local default_attachment = color_blend.attachments[1]

		if default_attachment and default_attachment[key] ~= nil then
			return default_attachment[key]
		end
	end

	if overridden_color_blend and overridden_color_blend[key] ~= nil then
		return overridden_color_blend[key]
	end

	return default
end

local function get_color_write_mask(self, index)
	return normalize_color_write_mask(get_color_blend_state(self, index, "color_write_mask", {"r", "g", "b", "a"}))
end

local function build_zero_offsets(count)
	if count <= 0 then return nil end

	local offsets = {}

	for i = 1, count do
		offsets[i] = 0
	end

	return offsets
end

local GRAPHICS_PIPELINE_SWITCH_WARNING_THRESHOLD = 256
local last_bound_graphics_pipeline = nil
local graphics_pipeline_switch_count = 0
local graphics_pipeline_switch_frame = -1
local warned_graphics_pipeline_switch_frame = -1

local function build_bind_state_cache(self)
	local config = get_active_config(self)
	local cache = {
		zero_dynamic_offsets = build_zero_offsets(self.dynamic_descriptor_count or 0),
	}

	if self.dynamic_states.color_blend_enable_ext then
		local attachment_count = get_color_attachment_count(self)

		if attachment_count > 0 then
			local enables = {}

			for i = 1, attachment_count do
				enables[i] = get_color_blend_enable(self, i)
			end

			cache.color_blend_enable = enables
		end
	end

	if self.dynamic_states.color_blend_equation_ext then
		local attachment_count = get_color_attachment_count(self)

		if attachment_count > 0 then
			local equations = {}

			for i = 1, attachment_count do
				equations[i] = {
					src_color_blend_factor = get_color_blend_state(self, i, "src_color_blend_factor", "src_alpha"),
					dst_color_blend_factor = get_color_blend_state(self, i, "dst_color_blend_factor", "one_minus_src_alpha"),
					color_blend_op = get_color_blend_state(self, i, "color_blend_op", "add"),
					src_alpha_blend_factor = get_color_blend_state(self, i, "src_alpha_blend_factor", "one"),
					dst_alpha_blend_factor = get_color_blend_state(self, i, "dst_alpha_blend_factor", "one_minus_src_alpha"),
					alpha_blend_op = get_color_blend_state(self, i, "alpha_blend_op", "add"),
				}
			end

			cache.color_blend_equations = equations
		end
	end

	if self.dynamic_states.color_write_mask_ext then
		local attachment_count = get_color_attachment_count(self)

		if attachment_count > 0 then
			local masks = {}

			for i = 1, attachment_count do
				masks[i] = get_color_write_mask(self, i)
			end

			cache.color_write_mask = masks
		end
	end

	if self.dynamic_states.logic_op_enable_ext then
		local logic_op_enabled = get_state(self, "color_blend", "logic_op_enabled")
		cache.logic_op_enable = logic_op_enabled ~= nil and logic_op_enabled ~= false and logic_op_enabled ~= 0
	end

	if self.dynamic_states.logic_op_ext then
		cache.logic_op = get_state(self, "color_blend", "logic_op") or "copy"
	end

	if self.dynamic_states.polygon_mode_ext then
		cache.polygon_mode = get_state(self, "rasterizer", "polygon_mode") or "fill"
	end

	if self.dynamic_states.cull_mode then
		cache.cull_mode = get_state(self, "rasterizer", "cull_mode") or "none"
	end

	if self.dynamic_states.front_face then
		cache.front_face = get_state(self, "rasterizer", "front_face") or "clockwise"
	end

	if self.dynamic_states.depth_clamp_enable_ext then
		cache.depth_clamp_enable = normalize_enabled(get_state(self, "rasterizer", "depth_clamp"))
	end

	if self.dynamic_states.rasterizer_discard_enable then
		local discard = get_state(self, "rasterizer", "discard")
		cache.rasterizer_discard_enable = discard ~= nil and discard ~= false and discard ~= 0
	end

	if self.dynamic_states.depth_bias_enable then
		local depth_bias = get_state(self, "rasterizer", "depth_bias")
		cache.depth_bias_enable = depth_bias ~= nil and depth_bias ~= false and depth_bias ~= 0
		cache.depth_bias_constant_factor = get_state(self, "rasterizer", "depth_bias_constant_factor") or 0
		cache.depth_bias_clamp = get_state(self, "rasterizer", "depth_bias_clamp") or 0
		cache.depth_bias_slope_factor = get_state(self, "rasterizer", "depth_bias_slope_factor") or 0
	end

	if self.dynamic_states.depth_test_enable then
		cache.depth_test_enable = normalize_enabled(get_state(self, "depth_stencil", "depth_test"))
	end

	if self.dynamic_states.depth_write_enable then
		cache.depth_write_enable = normalize_enabled(get_state(self, "depth_stencil", "depth_write"))
	end

	if self.dynamic_states.depth_compare_op then
		cache.depth_compare_op = get_state(self, "depth_stencil", "depth_compare_op") or "less"
	end

	if self.dynamic_states.primitive_restart_enable then
		local primitive_restart = get_state(self, "input_assembly", "primitive_restart")
		cache.primitive_restart_enable = primitive_restart ~= nil and
			primitive_restart ~= false and
			primitive_restart ~= 0
	end

	if self.dynamic_states.stencil_test_enable then
		cache.stencil_test_enable = normalize_enabled(get_state(self, "depth_stencil", "stencil_test"))
	end

	if self.dynamic_states.stencil_op then
		cache.stencil_fail_op = get_state(self, "depth_stencil", "front", "fail_op") or "keep"
		cache.stencil_pass_op = get_state(self, "depth_stencil", "front", "pass_op") or "keep"
		cache.stencil_depth_fail_op = get_state(self, "depth_stencil", "front", "depth_fail_op") or "keep"
		cache.stencil_compare_op = get_state(self, "depth_stencil", "front", "compare_op") or "always"
	end

	if self.dynamic_states.stencil_reference then
		cache.stencil_reference = get_state(self, "depth_stencil", "front", "reference") or 0
	end

	if self.dynamic_states.stencil_compare_mask then
		cache.stencil_compare_mask = get_state(self, "depth_stencil", "front", "compare_mask") or 0xFF
	end

	if self.dynamic_states.stencil_write_mask then
		cache.stencil_write_mask = get_state(self, "depth_stencil", "front", "write_mask") or 0xFF
	end

	if self.dynamic_states.viewport then
		cache.viewport_x = (
				get_state(self, "viewport", "x")
			) or
			(
				config.viewport and
				config.viewport.x
			)
			or
			0
		cache.viewport_y = (
				get_state(self, "viewport", "y")
			) or
			(
				config.viewport and
				config.viewport.y
			)
			or
			0
		cache.viewport_width = (
				get_state(self, "viewport", "w")
			) or
			(
				config.extent and
				config.extent.width
			)
			or
			(
				config.viewport and
				config.viewport.w
			)
			or
			0
		cache.viewport_height = (
				get_state(self, "viewport", "h")
			) or
			(
				config.extent and
				config.extent.height
			)
			or
			(
				config.viewport and
				config.viewport.h
			)
			or
			0
		cache.viewport_min_depth = (
				get_state(self, "viewport", "min_depth")
			) or
			(
				config.viewport and
				config.viewport.min_depth
			)
			or
			0
		cache.viewport_max_depth = (
				get_state(self, "viewport", "max_depth")
			) or
			(
				config.viewport and
				config.viewport.max_depth
			)
			or
			1
	end

	if self.dynamic_states.scissor then
		cache.scissor_x = (
				get_state(self, "scissor", "x")
			) or
			(
				config.scissor and
				config.scissor.x
			)
			or
			0
		cache.scissor_y = (
				get_state(self, "scissor", "y")
			) or
			(
				config.scissor and
				config.scissor.y
			)
			or
			0
		cache.scissor_width = (
				get_state(self, "scissor", "w")
			) or
			(
				config.extent and
				config.extent.width
			)
			or
			(
				config.scissor and
				config.scissor.w
			)
			or
			0
		cache.scissor_height = (
				get_state(self, "scissor", "h")
			) or
			(
				config.extent and
				config.extent.height
			)
			or
			(
				config.scissor and
				config.scissor.h
			)
			or
			0
	end

	self.bind_state_cache = cache
end

local function get_pipeline_signature(self, cmd)
	local rendering_state = cmd and cmd.rendering_state or nil
	local base = self.base_pipeline_signature or
		{
			color_format = self.config.ColorFormat,
			depth_format = self.config.DepthFormat,
			samples = self.config.RasterizationSamples or "1",
		}
	local color_format = base.color_format

	if rendering_state then
		if rendering_state.color_formats and #rendering_state.color_formats > 0 then
			color_format = rendering_state.color_formats
		else
			color_format = rendering_state.color_format
		end
	end

	return {
		color_format = color_format,
		depth_format = rendering_state and rendering_state.depth_format or base.depth_format,
		samples = rendering_state and rendering_state.samples or base.samples,
	}
end

local function build_internal_pipeline(vulkan_instance, pipeline_layout, config, dynamic_states)
	local shader_modules = {}

	for i, stage in ipairs(config.shader_stages) do
		shader_modules[i] = {
			type = stage.type,
			module = ShaderModule.New(vulkan_instance.device, stage.code, stage.type),
		}
	end

	local vertex_bindings
	local vertex_attributes

	for i, stage in ipairs(config.shader_stages) do
		if stage.type == "vertex" then
			vertex_bindings = stage.bindings
			vertex_attributes = stage.attributes

			break
		end
	end

	local color_blend_config = config.color_blend and table.copy(config.color_blend) or {}
	local color_attachment_count = 0

	if config.ColorFormat ~= nil and config.ColorFormat ~= false then
		if type(config.ColorFormat) == "table" then
			color_attachment_count = #config.ColorFormat
		else
			color_attachment_count = 1
		end
	end

	color_blend_config.attachments = color_blend_config.attachments and
		table.copy(color_blend_config.attachments) or
		{}

	for i = 1, #color_blend_config.attachments do
		if type(color_blend_config.attachments[i]) == "table" then
			color_blend_config.attachments[i] = table.copy(color_blend_config.attachments[i])
		end
	end

	for i = 1, color_attachment_count do
		color_blend_config.attachments[i] = color_blend_config.attachments[i] or {}
	end

	local multisampling_config = config.multisampling or {}
	multisampling_config.rasterization_samples = config.RasterizationSamples or "1"
	local pipeline = InternalGraphicsPipeline.New(
		vulkan_instance.device,
		{
			shaderModules = shader_modules,
			extent = config.extent,
			vertexBindings = vertex_bindings,
			vertexAttributes = vertex_attributes,
			input_assembly = config.input_assembly,
			rasterizer = config.rasterizer,
			viewport = config.viewport,
			scissor = config.scissor,
			multisampling = multisampling_config,
			color_blend = color_blend_config,
			dynamic_states = dynamic_states,
			depth_stencil = config.depth_stencil,
		},
		{{format = config.ColorFormat, depth_format = config.DepthFormat}},
		pipeline_layout
	)
	pipeline._shader_modules = shader_modules
	return pipeline, shader_modules
end

local function build_dynamic_state_list(device, is_static)
	if is_static then return nil end

	local dynamic_states = {"viewport", "scissor"}

	if device.has_extended_dynamic_state then
		table.insert(dynamic_states, "cull_mode")
		table.insert(dynamic_states, "front_face")
		table.insert(dynamic_states, "depth_test_enable")
		table.insert(dynamic_states, "depth_write_enable")
		table.insert(dynamic_states, "depth_compare_op")
		table.insert(dynamic_states, "stencil_test_enable")
		table.insert(dynamic_states, "stencil_op")
		table.insert(dynamic_states, "stencil_compare_mask")
		table.insert(dynamic_states, "stencil_write_mask")
		table.insert(dynamic_states, "stencil_reference")
	end

	if device.has_extended_dynamic_state2 then
		table.insert(dynamic_states, "depth_bias_enable")
		table.insert(dynamic_states, "depth_bias")
		table.insert(dynamic_states, "primitive_restart_enable")
		table.insert(dynamic_states, "rasterizer_discard_enable")

		if device.has_logic_op_dynamic_state then
			table.insert(dynamic_states, "logic_op_ext")
		end
	end

	if device.has_extended_dynamic_state3 then
		local dyn3 = device.physical_device:GetExtendedDynamicStateFeatures()

		if dyn3.extendedDynamicState3ColorBlendEnable then
			table.insert(dynamic_states, "color_blend_enable_ext")
		end

		if dyn3.extendedDynamicState3ColorBlendEquation then
			table.insert(dynamic_states, "color_blend_equation_ext")
		end

		if dyn3.extendedDynamicState3PolygonMode then
			table.insert(dynamic_states, "polygon_mode_ext")
		end

		if dyn3.extendedDynamicState3DepthClampEnable then
			table.insert(dynamic_states, "depth_clamp_enable_ext")
		end

		if dyn3.extendedDynamicState3ColorWriteMask then
			table.insert(dynamic_states, "color_write_mask_ext")
		end

		if device.has_logic_op_enable_dynamic_state then
			table.insert(dynamic_states, "logic_op_enable_ext")
		end
	end

	local unique = {}

	for i = #dynamic_states, 1, -1 do
		local state_name = dynamic_states[i]

		if unique[state_name] then
			table.remove(dynamic_states, i)
		else
			unique[state_name] = true
		end
	end

	return dynamic_states
end

function GraphicsPipeline.New(vulkan_instance, config)
	assert_no_legacy_constructor_fields(config, 3)
	normalize_constructor_properties(config)

	if
		config.multisampling and
		config.multisampling.sample_shading and
		vulkan_instance.device.physical_device:GetFeatures().sampleRateShading == 0
	then
		error(
			"GraphicsPipeline.New: SampleShading requires the Vulkan sampleRateShading feature",
			3
		)
	end

	local self = GraphicsPipeline:CreateObject({})
	local uniform_buffers = {}
	local shader_modules = {}
	local layout_maps = {}
	local pool_size_map = {}
	local push_constant_ranges = {}
	local all_stage_bits = 0
	local max_end = 0
	local has_push_constants = false
	local dynamic_descriptor_count = 0

	for i, stage in ipairs(config.shader_stages) do
		local stage_bits = vulkan.vk.e.VkShaderStageFlagBits(stage.type)
		all_stage_bits = bit.bor(all_stage_bits, tonumber(ffi.cast("uint32_t", stage_bits)))

		if stage.descriptor_sets then
			for _, ds in ipairs(stage.descriptor_sets) do
				local set_index = ds.set_index or 0
				local binding_index = ds.binding_index
				layout_maps[set_index] = layout_maps[set_index] or {}
				local layout_map = layout_maps[set_index]

				if layout_map[binding_index] then
					layout_map[binding_index].stageFlags = bit.bor(layout_map[binding_index].stageFlags, tonumber(ffi.cast("uint32_t", stage_bits)))
				else
					layout_map[binding_index] = {
						binding_index = binding_index,
						type = ds.type,
						stageFlags = stage_bits,
						count = ds.count or 1,
					}
					pool_size_map[ds.type] = (pool_size_map[ds.type] or 0) + (ds.count or 1)

					if ds.type == "uniform_buffer_dynamic" or ds.type == "storage_buffer_dynamic" then
						dynamic_descriptor_count = dynamic_descriptor_count + 1
					end
				end

				if ds.type == "uniform_buffer" or ds.type == "uniform_buffer_dynamic" then
					uniform_buffers[ds.binding_index] = ds.args[1]
				end
			end
		end

		if stage.push_constants then
			local offset = stage.push_constants.offset or 0
			local size = stage.push_constants.size
			max_end = math.max(max_end, offset + size)
			has_push_constants = true
		end
	end

	if has_push_constants then
		table.insert(
			push_constant_ranges,
			{
				stage = all_stage_bits,
				offset = 0,
				size = max_end,
			}
		)
	end

	local descriptorSetLayouts = {}
	local max_set_index = 0

	for set_index, _ in pairs(layout_maps) do
		max_set_index = math.max(max_set_index, set_index)
	end

	for set_index = 0, max_set_index do
		local layout_map = layout_maps[set_index] or {}
		local layout = {}

		for _, l in pairs(layout_map) do
			table.insert(layout, l)
		end

		descriptorSetLayouts[set_index + 1] = DescriptorSetLayout.New(vulkan_instance.device, layout)
	end

	local pool_sizes = {}

	for type, count in pairs(pool_size_map) do
		table.insert(pool_sizes, {type = type, count = count})
	end

	-- Validate push constant ranges don't exceed device limits
	if #push_constant_ranges > 0 then
		local device_properties = vulkan_instance.physical_device:GetProperties()
		local max_push_constants_size = device_properties.limits.maxPushConstantsSize

		for i, range in ipairs(push_constant_ranges) do
			local range_end = range.offset + range.size

			if range_end > max_push_constants_size then
				error(
					string.format(
						"Push constant range [%d] for %s stage exceeds device limit: offset(%d) + size(%d) = %d > maxPushConstantsSize(%d)",
						i,
						range.stage,
						range.offset,
						range.size,
						range_end,
						max_push_constants_size
					)
				)
			end
		end
	end

	local pipelineLayout = PipelineLayout.New(vulkan_instance.device, descriptorSetLayouts, push_constant_ranges)
	self.push_constant_ranges = push_constant_ranges
	self.dynamic_descriptor_count = dynamic_descriptor_count
	-- BINDLESS DESCRIPTOR SET MANAGEMENT:
	-- For bindless rendering, we create one descriptor set per frame containing
	-- an array of all textures. The descriptor sets are updated when new textures
	-- are registered, not per-draw. Each draw just pushes a texture index.
	local descriptor_set_count = config.DescriptorSetCount or 1
	local descriptorPools = {}
	local descriptorSets = {}

	for frame = 1, descriptor_set_count do
		-- Create a pool for this frame - just needs space for all descriptor sets
		local frame_pool_sizes = {}

		for i, pool_size in ipairs(pool_sizes) do
			frame_pool_sizes[i] = {
				type = pool_size.type,
				count = pool_size.count, -- count already accounts for array size from descriptor_sets config
			}
		end

		descriptorPools[frame] = DescriptorPool.New(vulkan_instance.device, frame_pool_sizes, #descriptorSetLayouts)
		local frameSets = {}

		for i, layout in ipairs(descriptorSetLayouts) do
			frameSets[i] = descriptorPools[frame]:AllocateDescriptorSet(layout)
		end

		descriptorSets[frame] = frameSets
	end

	local vertex_bindings
	local vertex_attributes

	-- Update descriptor sets
	for i, stage in ipairs(config.shader_stages) do
		if stage.type == "vertex" then
			vertex_bindings = stage.bindings
			vertex_attributes = stage.attributes
		end
	end

	-- Always use format and samples to ensure they match
	local multisampling_config = config.multisampling or {}
	multisampling_config.rasterization_samples = config.RasterizationSamples or "1"
	local dynamic_state_list = build_dynamic_state_list(vulkan_instance.device, config.Static)
	pipeline, shader_modules = build_internal_pipeline(vulkan_instance, pipelineLayout, config, dynamic_state_list)
	self.pipeline = pipeline
	self.descriptor_sets = descriptorSets
	self.pipeline_layout = pipelineLayout
	self.vulkan_instance = vulkan_instance
	self.config = config
	self.active_config = config
	self.uniform_buffers = uniform_buffers
	self.descriptor_set_layouts = descriptorSetLayouts
	self.descriptorPools = descriptorPools -- Array of pools, one per frame
	self.shader_modules = shader_modules -- Keep shader modules alive to prevent GC
	-- GraphicsPipeline variant caching for compatibility and static state emulation
	self.base_pipeline = pipeline
	self.base_pipeline_signature = {
		color_format = config.ColorFormat,
		depth_format = config.DepthFormat,
		samples = config.RasterizationSamples or "1",
	}
	self.dynamic_state_list = dynamic_state_list and copy_list(dynamic_state_list) or nil
	self.overridden_state = {}
	self.dynamic_states = {}

	if dynamic_state_list then
		for _, s in ipairs(dynamic_state_list) do
			self.dynamic_states[s] = true
		end
	end

	self.pipeline_variants = {}
	self.signature_id_root = {}
	self.input_assembly_state_id_root = {}
	self.multisampling_state_id_root = {}
	self.rasterizer_state_id_root = {}
	self.depth_stencil_state_id_root = {}
	self.viewport_state_id_root = {}
	self.scissor_state_id_root = {}
	self.color_blend_state_id_root = {}
	self.pipeline_variant_id_root = {}
	self.base_signature_id = get_signature_id(self, self.base_pipeline_signature)
	self.base_input_assembly_state_id = get_input_assembly_state_id(self)
	self.base_multisampling_state_id = get_multisampling_state_id(self)
	self.base_rasterizer_state_id = get_rasterizer_state_id(self)
	self.base_depth_stencil_state_id = get_depth_stencil_state_id(self)
	self.base_viewport_state_id = get_viewport_state_id(self)
	self.base_scissor_state_id = get_scissor_state_id(self)
	self.base_color_blend_state_id = get_color_blend_state_id(self)
	self.base_variant_id = get_pipeline_variant_id(
		self,
		self.base_signature_id,
		self.base_input_assembly_state_id,
		self.base_multisampling_state_id,
		self.base_rasterizer_state_id,
		self.base_depth_stencil_state_id,
		self.base_viewport_state_id,
		self.base_scissor_state_id,
		self.base_color_blend_state_id
	)
	self.pipeline_variants[self.base_variant_id] = {
		pipeline = pipeline,
		config = config,
		shader_modules = shader_modules,
	}
	self.current_signature_id = self.base_signature_id
	self.current_variant_id = self.base_variant_id
	self.static_variant_dirty = false
	self.bind_state_dirty = false
	build_bind_state_cache(self)

	do
		self.texture_registry = setmetatable({}, {__mode = "k"}) -- texture_object -> index mapping
		self.texture_array = {} -- array of {view, sampler} for descriptor set
		self.next_texture_index = 0
		self.texture_free_list = {}
		self.cubemap_registry = setmetatable({}, {__mode = "k"})
		self.cubemap_array = {}
		self.next_cubemap_index = 0
		self.cubemap_free_list = {}
		self.max_textures = 1024 * 4
	end

	local event = import("goluwa/event.lua")

	event.AddListener("TextureRemoved", self, function(removed_tex)
		if not render.GetDevice():IsValid() then return end
		if render.shutting_down then return end
		local set_index = #self.descriptor_set_layouts > 1 and 1 or 0
		self:ReleaseTextureIndex(removed_tex, set_index)
	end)

	-- Initialize all descriptor sets with the same initial bindings
	for frame_index = 1, descriptor_set_count do
		for i, stage in ipairs(config.shader_stages) do
			if stage.descriptor_sets then
				for i, ds in ipairs(stage.descriptor_sets) do
					if ds.args then
						self:UpdateDescriptorSet(ds.type, frame_index, ds.binding_index, ds.set_index or 0, unpack(ds.args))
					end
				end
			end
		end
	end

	return self
end

function GraphicsPipeline:GetColorFormat()
	return self.base_pipeline_signature.color_format
end

function GraphicsPipeline:GetDepthFormat()
	return self.base_pipeline_signature.depth_format
end

function GraphicsPipeline:GetRasterizationSamples()
	return self.base_pipeline_signature.samples
end

function GraphicsPipeline:GetSamples()
	return self:GetRasterizationSamples()
end

function GraphicsPipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function GraphicsPipeline:GetFallbackView()
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetView then return fallback:GetView() end

	return fallback and fallback.view
end

function GraphicsPipeline:GetFallbackSampler()
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetSampler then return fallback:GetSampler() end

	return fallback and fallback.sampler
end

function GraphicsPipeline:ReleaseTextureIndex(tex, set_index)
	set_index = set_index or 0

	if not tex or type(tex) ~= "table" then return end

	local is_cube = tex.IsCubemap and tex:IsCubemap()
	local registry = is_cube and self.cubemap_registry or self.texture_registry
	local array = is_cube and self.cubemap_array or self.texture_array
	local free_list = is_cube and self.cubemap_free_list or self.texture_free_list
	local binding_index = is_cube and 1 or 0
	local index = registry[tex]

	if index then
		registry[tex] = nil
		table.insert(free_list, index)
		-- Clear the entry in the array to avoid keeping views alive
		array[index + 1] = {
			view = self:GetFallbackView(),
			sampler = self:GetFallbackSampler(),
		}

		for frame_i = 1, #self.descriptor_sets do
			self:UpdateDescriptorSetArray(frame_i, binding_index, set_index, array)
		end
	end
end

function GraphicsPipeline:GetTextureIndex(tex, set_index)
	set_index = set_index or 0

	if not tex or type(tex) ~= "table" then return -1 end

	local is_cube = tex.IsCubemap and tex:IsCubemap()
	local registry = is_cube and self.cubemap_registry or self.texture_registry
	local array = is_cube and self.cubemap_array or self.texture_array
	local index_key = is_cube and "next_cubemap_index" or "next_texture_index"
	local binding_index = is_cube and 1 or 0
	local index = registry[tex]

	if index then
		local entry = array[index + 1]

		-- Added safety check: only update if resources actually exist
		if
			entry and
			tex.view and
			tex.sampler and
			(
				entry.view ~= tex.view or
				entry.sampler ~= tex.sampler
			)
		then
			array[index + 1] = {view = tex.view, sampler = tex.sampler}

			for frame_i = 1, #self.descriptor_sets do
				self:UpdateDescriptorSetArray(frame_i, binding_index, set_index, array)
			end
		end

		return index
	end

	local free_list = is_cube and self.cubemap_free_list or self.texture_free_list

	if #free_list > 0 then
		index = table.remove(free_list)
	else
		if self[index_key] >= self.max_textures then
			-- This is where leaks will eventually manifest if textures are created/destroyed rapidly
			error(
				(
						is_cube and
						"Cubemap" or
						"Texture"
					) .. " registry full! Max textures: " .. self.max_textures
			)
		end

		index = self[index_key]
		self[index_key] = index + 1
	end

	registry[tex] = index
	-- Ensure we don't put nil into the array which might confuse the C-side UpdateDescriptorSetArray
	array[index + 1] = {
		view = (
				_G.type(tex) == "table" and
				tex.GetView and
				tex:GetView()
			) or
			tex.view or
			self:GetFallbackView(),
		sampler = (
				_G.type(tex) == "table" and
				tex.GetSampler and
				tex:GetSampler()
			) or
			tex.sampler or
			self:GetFallbackSampler(),
	}

	for frame_i = 1, #self.descriptor_sets do
		self:UpdateDescriptorSetArray(frame_i, binding_index, set_index, array)
	end

	return index
end

function GraphicsPipeline:UpdateDescriptorSet(type, index, binding_index, set_index, ...)
	if _G.type(set_index) ~= "number" then
		-- Backwards compatibility
		return self:UpdateDescriptorSet(type, index, binding_index, 0, set_index, ...)
	end

	local count = select("#", ...)

	if type == "combined_image_sampler" then
		if count > 2 then
			-- Multiple textures passed, convert to array and use UpdateDescriptorSetArray
			local textures = {...}
			local array = {}

			for i, tex in ipairs(textures) do
				if _G.type(tex) == "table" and tex.view and tex.sampler then
					array[i] = {
						view = (tex.GetView and tex:GetView()) or tex.view,
						sampler = (tex.GetSampler and tex:GetSampler()) or tex.sampler,
					}
				else
					array[i] = tex
				end
			end

			self:UpdateDescriptorSetArray(index, binding_index, set_index, array)
			return
		elseif count == 1 then
			local tex = ...

			if _G.type(tex) == "table" and (tex.view or (tex.GetView and tex:GetView())) then
				-- Single texture object passed, extract view and sampler
				self.vulkan_instance.device:UpdateDescriptorSet(
					type,
					self.descriptor_sets[index][set_index + 1],
					binding_index,
					(tex.GetView and tex:GetView()) or tex.view,
					(tex.GetSampler and tex:GetSampler()) or tex.sampler,
					self:GetFallbackView(),
					self:GetFallbackSampler()
				)
				return
			end
		end
	end

	local args = {...}
	table.insert(args, self:GetFallbackView())
	table.insert(args, self:GetFallbackSampler())
	self.vulkan_instance.device:UpdateDescriptorSet(
		type,
		self.descriptor_sets[index][set_index + 1],
		binding_index,
		unpack(args)
	)
end

function GraphicsPipeline:UpdateDescriptorSetArray(frame_index, binding_index, set_index, texture_array)
	if _G.type(set_index) ~= "number" then
		-- Backwards compatibility
		return self:UpdateDescriptorSetArray(frame_index, binding_index, 0, set_index)
	end

	-- Update a descriptor set with an array of textures for bindless rendering
	self.vulkan_instance.device:UpdateDescriptorSetArray(
		self.descriptor_sets[frame_index][set_index + 1],
		binding_index,
		texture_array,
		self:GetFallbackView(),
		self:GetFallbackSampler()
	)
end

function GraphicsPipeline:PushConstants(cmd, stage, offset, data, data_size)
	local stage_bits

	if type(stage) == "number" then
		stage_bits = stage
	elseif type(stage) == "table" then
		stage_bits = 0

		for _, s in ipairs(stage) do
			stage_bits = bit.bor(stage_bits, tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(s))))
		end
	else
		stage_bits = tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(stage)))
	end

	-- Vulkan requires that the stageFlags passed to vkCmdPushConstants must include 
	-- ALL stages that are defined for the overlapping range in the pipeline layout.
	for _, range in ipairs(self.push_constant_ranges) do
		if offset >= range.offset and offset < (range.offset + range.size) then
			stage_bits = bit.bor(stage_bits, tonumber(ffi.cast("uint32_t", range.stage)))
		end
	end

	cmd:PushConstants(self.pipeline_layout, stage_bits, offset, data_size or ffi.sizeof(data), data)
end

function GraphicsPipeline:GetUniformBuffer(binding_index)
	local ub = self.uniform_buffers[binding_index]

	if not ub then
		error("Invalid uniform buffer binding index: " .. binding_index)
	end

	return ub
end

function GraphicsPipeline:Bind(cmd, frame_index, dynamic_offsets)
	frame_index = frame_index or 1
	local frame_number = system.GetFrameNumber and system.GetFrameNumber() or 0

	if graphics_pipeline_switch_frame ~= frame_number then
		graphics_pipeline_switch_frame = frame_number
		graphics_pipeline_switch_count = 0
		last_bound_graphics_pipeline = nil
	end

	local signature = get_pipeline_signature(self, cmd)
	local signature_id = get_signature_id(self, signature)

	if self.static_variant_dirty or self.current_signature_id ~= signature_id then
		self:RebuildPipeline(self.overridden_state, signature)
	elseif self.bind_state_dirty then
		build_bind_state_cache(self)
		self.bind_state_dirty = false
	end

	local cache = self.bind_state_cache

	if last_bound_graphics_pipeline ~= self.pipeline then
		last_bound_graphics_pipeline = self.pipeline
		graphics_pipeline_switch_count = graphics_pipeline_switch_count + 1

		if
			graphics_pipeline_switch_count >= GRAPHICS_PIPELINE_SWITCH_WARNING_THRESHOLD and
			warned_graphics_pipeline_switch_frame ~= frame_number and
			logn
		then
			warned_graphics_pipeline_switch_frame = frame_number
			logn(
				"[warning] high graphics pipeline switch count: ",
				graphics_pipeline_switch_count,
				" in frame ",
				frame_number,
				". Consider sorting draws by pipeline/material, reducing static graphics pipeline property changes, or moving more state to dynamic state."
			)
		end
	end

	cmd:BindPipeline(self.pipeline, "graphics")

	-- Always apply dynamic states if they are enabled in this pipeline
	if self.dynamic_states.color_blend_enable_ext then
		if cache.color_blend_enable then
			cmd:SetColorBlendEnable(0, cache.color_blend_enable)
		end
	end

	if self.dynamic_states.color_write_mask_ext then
		if cache.color_write_mask then
			cmd:SetColorWriteMask(0, cache.color_write_mask)
		end
	end

	if self.dynamic_states.logic_op_enable_ext then
		cmd:SetLogicOpEnable(cache.logic_op_enable)
	end

	if self.dynamic_states.logic_op_ext then cmd:SetLogicOp(cache.logic_op) end

	if self.dynamic_states.color_blend_equation_ext then
		if cache.color_blend_equations then
			for i, equation in ipairs(cache.color_blend_equations) do
				cmd:SetColorBlendEquation(i - 1, equation)
			end
		end
	end

	if self.dynamic_states.polygon_mode_ext then
		cmd:SetPolygonMode(cache.polygon_mode)
	end

	if self.dynamic_states.cull_mode then cmd:SetCullMode(cache.cull_mode) end

	if self.dynamic_states.front_face then cmd:SetFrontFace(cache.front_face) end

	if self.dynamic_states.depth_clamp_enable_ext then
		cmd:SetDepthClampEnable(cache.depth_clamp_enable)
	end

	if self.dynamic_states.rasterizer_discard_enable then
		cmd:SetRasterizerDiscardEnable(cache.rasterizer_discard_enable)
	end

	if self.dynamic_states.depth_bias_enable then
		cmd:SetDepthBiasEnable(cache.depth_bias_enable)
		cmd:SetDepthBias(
			cache.depth_bias_constant_factor,
			cache.depth_bias_clamp,
			cache.depth_bias_slope_factor
		)
	end

	if self.dynamic_states.depth_test_enable then
		cmd:SetDepthTestEnable(cache.depth_test_enable)
	end

	if self.dynamic_states.depth_write_enable then
		cmd:SetDepthWriteEnable(cache.depth_write_enable)
	end

	if self.dynamic_states.depth_compare_op then
		cmd:SetDepthCompareOp(cache.depth_compare_op)
	end

	if self.dynamic_states.primitive_restart_enable then
		cmd:SetPrimitiveRestartEnable(cache.primitive_restart_enable)
	end

	if self.dynamic_states.stencil_test_enable then
		cmd:SetStencilTestEnable(cache.stencil_test_enable)
	end

	if self.dynamic_states.stencil_op then
		cmd:SetStencilOp(
			"front_and_back",
			cache.stencil_fail_op,
			cache.stencil_pass_op,
			cache.stencil_depth_fail_op,
			cache.stencil_compare_op
		)
	end

	if self.dynamic_states.stencil_reference then
		cmd:SetStencilReference("front_and_back", cache.stencil_reference)
	end

	if self.dynamic_states.stencil_compare_mask then
		cmd:SetStencilCompareMask("front_and_back", cache.stencil_compare_mask)
	end

	if self.dynamic_states.stencil_write_mask then
		cmd:SetStencilWriteMask("front_and_back", cache.stencil_write_mask)
	end

	if self.dynamic_states.viewport then
		if cache.viewport_width > 0 and cache.viewport_height > 0 then
			cmd:SetViewport(
				cache.viewport_x,
				cache.viewport_y,
				cache.viewport_width,
				cache.viewport_height,
				cache.viewport_min_depth,
				cache.viewport_max_depth
			)
		end
	end

	if self.dynamic_states.scissor then
		if cache.scissor_width > 0 and cache.scissor_height > 0 then
			cmd:SetScissor(cache.scissor_x, cache.scissor_y, cache.scissor_width, cache.scissor_height)
		end
	end

	-- Bind descriptor sets
	if self.descriptor_sets then
		local sets = self.descriptor_sets[frame_index] or self.descriptor_sets[1]

		if sets then
			local offsets = dynamic_offsets

			if not offsets then offsets = cache.zero_dynamic_offsets or 0 end

			cmd:BindDescriptorSets("graphics", self.pipeline_layout, sets, offsets or 0)
		end
	end
end

function GraphicsPipeline:GetVertexAttributes()
	-- Find the vertex shader stage in config
	for _, stage in ipairs(get_active_config(self).shader_stages) do
		if stage.type == "vertex" then return stage.attributes end
	end

	return nil
end

-- Helper function to deep copy a table (for pipeline config variants)
local function deep_copy(obj, seen)
	if type(obj) ~= "table" then return obj end

	if seen and seen[obj] then return seen[obj] end

	local s = seen or {}
	local res = {}
	s[obj] = res

	for k, v in pairs(obj) do
		res[deep_copy(k, s)] = deep_copy(v, s)
	end

	return setmetatable(res, getmetatable(obj))
end

for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
	GraphicsPipeline[info.set_name] = function(self, value)
		if value == nil then
			value = get_default_state_value(info)
		else
			value = prototype.ValidatePropertyValue(info, value, 2)

			if info.compare == "list" then value = copy_list(value) end
		end

		local current = get_property_effective_value(self, info)

		if prototype.ComparePropertyValues(info, current, value) then return end

		store_property_override(self, info, value)
	end
	GraphicsPipeline[info.get_name] = function(self)
		return get_property_effective_value(self, info)
	end
end

function GraphicsPipeline:ApplyProperties(properties)
	local property_info = {}

	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		property_info[info.var_name] = info
	end

	for key, value in pairs(properties) do
		if property_info[key] then self["Set" .. key](self, value) end
	end
end

function GraphicsPipeline:OnRemove()
	local event = import("goluwa/event.lua")
	event.RemoveListener("TextureRemoved", self)

	if self.descriptorPools then
		for _, pool in pairs(self.descriptorPools) do
			pool:Remove()
		end
	end

	if self.pipeline_variants then
		local removed = {}

		for _, entry in pairs(self.pipeline_variants) do
			local pipeline = entry.pipeline

			if pipeline and not removed[pipeline] then
				pipeline:Remove()
				removed[pipeline] = true
			end

			if entry.shader_modules then
				for _, shader_module in ipairs(entry.shader_modules) do
					if shader_module.module and shader_module.module:IsValid() then
						shader_module.module:Remove()
					end
				end
			end
		end
	elseif self.pipeline then
		self.pipeline:Remove()
	end

	if self.descriptor_set_layouts then
		for _, layout in pairs(self.descriptor_set_layouts) do
			layout:Remove()
		end
	end

	if self.pipeline_layout then self.pipeline_layout:Remove() end
end

-- Rebuild pipeline with modified state
-- overrides: table where keys are sections (e.g., "color_blend") and values are change tables
function GraphicsPipeline:RebuildPipeline(overrides, signature)
	signature = signature or self.base_pipeline_signature
	local signature_id = get_signature_id(self, signature)
	-- Generate a cache key for this variant using only STATIC overrides
	local static_overrides = {}

	for section, changes in pairs(overrides) do
		if
			section ~= "input_assembly" and
			section ~= "multisampling" and
			section ~= "rasterizer" and
			section ~= "depth_stencil" and
			section ~= "viewport" and
			section ~= "scissor" and
			section ~= "color_blend"
		then
			error("unknown static pipeline state section for variant cache: " .. tostring(section))
		end

		local static_changes = {}
		local has_static = false

		for k, v in pairs(changes or {}) do
			if has_static_override_change(self, section, k, v) then
				static_changes[k] = v
				has_static = true
			end
		end

		if has_static then static_overrides[section] = static_changes end
	end

	local input_assembly_state_id = get_input_assembly_state_id(self, static_overrides.input_assembly)
	local multisampling_state_id = get_multisampling_state_id(self, static_overrides.multisampling)
	local rasterizer_state_id = get_rasterizer_state_id(self, static_overrides.rasterizer)
	local depth_stencil_state_id = get_depth_stencil_state_id(self, static_overrides.depth_stencil)
	local viewport_state_id = get_viewport_state_id(self, static_overrides.viewport)
	local scissor_state_id = get_scissor_state_id(self, static_overrides.scissor)
	local color_blend_state_id = get_color_blend_state_id(self, static_overrides.color_blend)
	local variant_id = get_pipeline_variant_id(
		self,
		signature_id,
		input_assembly_state_id,
		multisampling_state_id,
		rasterizer_state_id,
		depth_stencil_state_id,
		viewport_state_id,
		scissor_state_id,
		color_blend_state_id
	)

	if self.current_variant_id == variant_id and self.pipeline then
		self.current_signature_id = signature_id

		if self.bind_state_dirty then
			build_bind_state_cache(self)
			self.bind_state_dirty = false
		end

		self.static_variant_dirty = false
		return
	end

	-- Return cached variant if it exists
	local cached = self.pipeline_variants[variant_id]

	if cached then
		self.current_signature_id = signature_id
		self.current_variant_id = variant_id
		self.pipeline = cached.pipeline
		self.active_config = cached.config
		build_bind_state_cache(self)
		self.static_variant_dirty = false
		self.bind_state_dirty = false
		return
	end

	-- Create a modified config
	local modified_config = deep_copy(self.config)
	modified_config.ColorFormat = signature.color_format
	modified_config.DepthFormat = signature.depth_format
	modified_config.RasterizationSamples = signature.samples

	-- Apply ALL overrides (both static and dynamic ones, though dynamic ones don't STRICTLY need to be in the baked pipeline, it's safer)
	for section, changes in pairs(overrides) do
		if section == "color_blend" then
			modified_config.color_blend = modified_config.color_blend or {}
			modified_config.color_blend.attachments = modified_config.color_blend.attachments or {{}}

			for k, v in pairs(changes) do
				if k == "logic_op_enabled" or k == "logic_op" or k == "constants" then
					modified_config.color_blend[k] = v
				elseif k == "attachments" then
					modified_config.color_blend.attachments = v
				else
					modified_config.color_blend.attachments[1][k] = v
				end
			end
		else
			modified_config[section] = modified_config[section] or {}

			for k, v in pairs(changes) do
				if type(v) == "table" and type(modified_config[section][k]) == "table" then
					modified_config[section][k] = deep_copy(modified_config[section][k])

					for subkey, subvalue in pairs(v) do
						modified_config[section][k][subkey] = subvalue
					end
				else
					modified_config[section][k] = v
				end
			end
		end
	end

	local new_pipeline, shader_modules = build_internal_pipeline(
		self.vulkan_instance,
		self.pipeline_layout,
		modified_config,
		self.dynamic_state_list
	)
	self.pipeline_variants[variant_id] = {
		pipeline = new_pipeline,
		config = modified_config,
		shader_modules = shader_modules,
	}
	self.current_signature_id = signature_id
	self.current_variant_id = variant_id
	self.pipeline = new_pipeline
	self.active_config = modified_config
	build_bind_state_cache(self)
	self.static_variant_dirty = false
	self.bind_state_dirty = false
end

-- Reset to base pipeline
function GraphicsPipeline:ResetToBase()
	self.pipeline = self.base_pipeline
	self.active_config = self.config
	self.current_signature_id = self.base_signature_id
	self.current_variant_id = self.base_variant_id
	self.overridden_state = {}
	self.static_variant_dirty = false
	build_bind_state_cache(self)
	self.bind_state_dirty = false
end

-- Get information about cached variants (for debugging)
function GraphicsPipeline:GetVariantInfo()
	local count = 0
	local keys = {}

	for key, _ in pairs(self.pipeline_variants) do
		count = count + 1
		table.insert(keys, key)
	end

	return {
		count = count,
		keys = keys,
		current = self.current_variant_id,
	}
end

return GraphicsPipeline:Register()
