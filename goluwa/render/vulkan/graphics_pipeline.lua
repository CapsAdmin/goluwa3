local prototype = import("goluwa/prototype.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local InternalGraphicsPipeline = import("goluwa/render/vulkan/internal/graphics_pipeline.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local Hash = import("goluwa/hash.lua")
local common = import("goluwa/render/vulkan/pipeline_common.lua")
local GraphicsPipeline = prototype.CreateTemplate("render_graphics_pipeline")
local state_keys = {}
local state_defaults = {}
local hash_key_groups = {}
local cache_rules = {}
local vulkan_bindings = {}
-- Dynamic state availability callbacks
local has_dynamic_state_basic = function()
	return true
end
local has_dynamic_state_extended = function(device)
	return device.has_extended_dynamic_state
end
local has_dynamic_state_extended2 = function(device)
	return device.has_extended_dynamic_state2
end
local has_dynamic_state_extended3 = function(device)
	return device.has_extended_dynamic_state3
end

do
	GraphicsPipeline:StartStorable()
	GraphicsPipeline:GetSet(
		"Topology",
		"triangle_list",
		{
			path = "input_assembly.topology",
			enums = {
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
			},
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportX",
		0,
		{
			path = "viewport.x",
			validate = "number",
			dynamic_state = "viewport",
			setter = function(cmd, cache, val)
				cmd:SetViewport(
					cache.viewport_x,
					cache.viewport_y,
					cache.viewport_width,
					cache.viewport_height,
					cache.viewport_min_depth,
					cache.viewport_max_depth
				)
			end,
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportY",
		0,
		{
			path = "viewport.y",
			validate = "number",
			dynamic_state = "viewport",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportWidth",
		nil,
		{
			path = "viewport.w",
			validate = "number",
			dynamic_state = "viewport",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportHeight",
		nil,
		{
			path = "viewport.h",
			validate = "number",
			dynamic_state = "viewport",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportMinDepth",
		0,
		{
			path = "viewport.min_depth",
			validate = "number",
			dynamic_state = "viewport",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ViewportMaxDepth",
		1,
		{
			path = "viewport.max_depth",
			validate = "number",
			dynamic_state = "viewport",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ScissorX",
		0,
		{
			path = "scissor.x",
			validate = "number",
			dynamic_state = "scissor",
			setter = function(cmd, cache, val)
				cmd:SetScissor(cache.scissor_x, cache.scissor_y, cache.scissor_width, cache.scissor_height)
			end,
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ScissorY",
		0,
		{
			path = "scissor.y",
			validate = "number",
			dynamic_state = "scissor",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ScissorWidth",
		nil,
		{
			path = "scissor.w",
			validate = "number",
			dynamic_state = "scissor",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"ScissorHeight",
		nil,
		{
			path = "scissor.h",
			validate = "number",
			dynamic_state = "scissor",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
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
		{
			path = "input_assembly.primitive_restart",
			validate = "boolean",
			dynamic_state = "primitive_restart_enable",
			setter = function(cmd, cache, val)
				cmd:SetPrimitiveRestartEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended2,
		}
	)
	GraphicsPipeline:GetSet(
		"PatchControlPoints",
		3,
		{path = "tessellation.patch_control_points", validate = "integer"}
	)
	GraphicsPipeline:GetSet(
		"PolygonMode",
		"fill",
		{
			path = "rasterizer.polygon_mode",
			enums = {"fill", "line", "point"},
			dynamic_state = "polygon_mode_ext",
			setter = function(cmd, cache, val)
				cmd:SetPolygonMode(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state3 then return false end

				return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3PolygonMode
			end,
		}
	)
	GraphicsPipeline:GetSet(
		"CullMode",
		"back",
		{
			path = "rasterizer.cull_mode",
			enums = {"none", "front", "back", "front_and_back"},
			dynamic_state = "cull_mode",
			setter = function(cmd, cache, val)
				cmd:SetCullMode(val)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontFace",
		"clockwise",
		{
			path = "rasterizer.front_face",
			enums = {"clockwise", "counter_clockwise"},
			dynamic_state = "front_face",
			setter = function(cmd, cache, val)
				cmd:SetFrontFace(val)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthBiasEnable",
		false,
		{
			path = "rasterizer.depth_bias_enable",
			validate = "boolean",
			dynamic_state = "depth_bias_enable",
			setter = function(cmd, cache, val)
				cmd:SetDepthBiasEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended2,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthBias",
		false,
		{
			path = "rasterizer.depth_bias",
			validate = "boolean",
			dynamic_state = "depth_bias",
			setter = function(cmd, cache, val)
				cmd:SetDepthBias(val)
			end,
			has_dynamic_state = has_dynamic_state_extended2,
		}
	)
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
	GraphicsPipeline:GetSet(
		"LineWidth",
		1,
		{
			path = "rasterizer.line_width",
			validate = "number",
			dynamic_state = "line_width",
			has_dynamic_state = has_dynamic_state_basic,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthClamp",
		false,
		{
			path = "rasterizer.depth_clamp",
			validate = "boolean",
			dynamic_state = "depth_clamp_enable_ext",
			setter = function(cmd, cache, val)
				cmd:SetDepthClampEnable(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state3 then return false end

				return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3DepthClampEnable
			end,
		}
	)
	GraphicsPipeline:GetSet(
		"Discard",
		false,
		{
			path = "rasterizer.discard",
			validate = "boolean",
			dynamic_state = "rasterizer_discard_enable",
			setter = function(cmd, cache, val)
				cmd:SetRasterizerDiscardEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended2,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthTest",
		false,
		{
			path = "depth_stencil.depth_test",
			validate = "boolean",
			dynamic_state = "depth_test_enable",
			setter = function(cmd, cache, val)
				cmd:SetDepthTestEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthWrite",
		false,
		{
			path = "depth_stencil.depth_write",
			validate = "boolean",
			dynamic_state = "depth_write_enable",
			setter = function(cmd, cache, val)
				cmd:SetDepthWriteEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"DepthBoundsTest",
		false,
		{path = "depth_stencil.depth_bounds_test", validate = "boolean"}
	)
	GraphicsPipeline:GetSet(
		"StencilTest",
		false,
		{
			path = "depth_stencil.stencil_test",
			validate = "boolean",
			dynamic_state = "stencil_test_enable",
			setter = function(cmd, cache, val)
				cmd:SetStencilTestEnable(val)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilReference",
		0,
		{
			path = "depth_stencil.front.reference",
			validate = "integer",
			dynamic_state = "stencil_reference",
			setter = function(cmd, cache, val)
				cmd:SetStencilReference("front_and_back", cache.stencil_reference)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)

	do
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
		GraphicsPipeline:GetSet(
			"FrontStencilFailOp",
			"keep",
			{
				path = "depth_stencil.front.fail_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				setter = function(cmd, cache, val)
					cmd:SetStencilOp(
						"front_and_back",
						cache.stencil_fail_op,
						cache.stencil_pass_op,
						cache.stencil_depth_fail_op,
						cache.stencil_compare_op
					)
				end,
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"FrontStencilPassOp",
			"keep",
			{
				path = "depth_stencil.front.pass_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"FrontStencilDepthFailOp",
			"keep",
			{
				path = "depth_stencil.front.depth_fail_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"BackStencilFailOp",
			"keep",
			{
				path = "depth_stencil.back.fail_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"BackStencilPassOp",
			"keep",
			{
				path = "depth_stencil.back.pass_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"BackStencilDepthFailOp",
			"keep",
			{
				path = "depth_stencil.back.depth_fail_op",
				enums = STENCIL_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
	end

	do
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
		GraphicsPipeline:GetSet(
			"FrontStencilCompareOp",
			"always",
			{
				path = "depth_stencil.front.compare_op",
				enums = COMPARE_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"BackStencilCompareOp",
			"always",
			{
				path = "depth_stencil.back.compare_op",
				enums = COMPARE_OPS,
				dynamic_state = "stencil_op",
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
		GraphicsPipeline:GetSet(
			"DepthCompareOp",
			"less",
			{
				path = "depth_stencil.depth_compare_op",
				enums = COMPARE_OPS,
				dynamic_state = "depth_compare_op",
				setter = function(cmd, cache, val)
					cmd:SetDepthCompareOp(val)
				end,
				has_dynamic_state = has_dynamic_state_extended,
			}
		)
	end

	GraphicsPipeline:GetSet(
		"FrontStencilCompareMask",
		0xFF,
		{
			path = "depth_stencil.front.compare_mask",
			validate = "integer",
			dynamic_state = "stencil_compare_mask",
			setter = function(cmd, cache, val)
				cmd:SetStencilCompareMask("front_and_back", cache.stencil_compare_mask)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"FrontStencilWriteMask",
		0xFF,
		{
			path = "depth_stencil.front.write_mask",
			validate = "integer",
			dynamic_state = "stencil_write_mask",
			setter = function(cmd, cache, val)
				cmd:SetStencilWriteMask("front_and_back", cache.stencil_write_mask)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilReference",
		0,
		{
			path = "depth_stencil.back.reference",
			validate = "integer",
			dynamic_state = "stencil_reference",
			setter = function(cmd, cache, val)
				cmd:SetStencilReference("front_and_back", cache.stencil_reference)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilCompareMask",
		0xFF,
		{
			path = "depth_stencil.back.compare_mask",
			validate = "integer",
			dynamic_state = "stencil_compare_mask",
			setter = function(cmd, cache, val)
				cmd:SetStencilCompareMask("front_and_back", cache.stencil_compare_mask)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"BackStencilWriteMask",
		0xFF,
		{
			path = "depth_stencil.back.write_mask",
			validate = "integer",
			dynamic_state = "stencil_write_mask",
			setter = function(cmd, cache, val)
				cmd:SetStencilWriteMask("front_and_back", cache.stencil_write_mask)
			end,
			has_dynamic_state = has_dynamic_state_extended,
		}
	)
	GraphicsPipeline:GetSet(
		"Blend",
		false,
		{
			path = "color_blend.blend",
			validate = "boolean",
			dynamic_state = "color_blend_enable_ext",
			setter = function(cmd, cache, val)
				cmd:SetColorBlendEnableExt(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state3 then return false end

				return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEnable
			end,
		}
	)

	do
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
		GraphicsPipeline:GetSet(
			"SrcColorBlendFactor",
			"one",
			{
				path = "color_blend.src_color_blend_factor",
				enums = BLEND_FACTORS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
		GraphicsPipeline:GetSet(
			"DstColorBlendFactor",
			"zero",
			{
				path = "color_blend.dst_color_blend_factor",
				enums = BLEND_FACTORS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
		GraphicsPipeline:GetSet(
			"SrcAlphaBlendFactor",
			"one",
			{
				path = "color_blend.src_alpha_blend_factor",
				enums = BLEND_FACTORS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
		GraphicsPipeline:GetSet(
			"DstAlphaBlendFactor",
			"zero",
			{
				path = "color_blend.dst_alpha_blend_factor",
				enums = BLEND_FACTORS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
	end

	do
		local BLEND_OPS = {"add", "subtract", "reverse_subtract", "min", "max"}
		GraphicsPipeline:GetSet(
			"AlphaBlendOp",
			"add",
			{
				path = "color_blend.alpha_blend_op",
				enums = BLEND_OPS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
		GraphicsPipeline:GetSet(
			"ColorBlendOp",
			"add",
			{
				path = "color_blend.color_blend_op",
				enums = BLEND_OPS,
				dynamic_state = "color_blend_equation_ext",
				setter = function(cmd, cache, val)
					cmd:SetColorBlendEquationExt(val)
				end,
				has_dynamic_state = function(device)
					if not device.has_extended_dynamic_state3 then return false end

					return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorBlendEquation
				end,
			}
		)
	end

	GraphicsPipeline:GetSet(
		"ColorWriteMask",
		{"r", "g", "b", "a"},
		{
			path = "color_blend.color_write_mask",
			list_type = "string",
			list_enums = {"r", "g", "b", "a", "R", "G", "B", "A"},
			compare = "list",
			dynamic_state = "color_write_mask_ext",
			setter = function(cmd, cache, val)
				cmd:SetColorWriteMaskExt(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state3 then return false end

				return device.physical_device:GetExtendedDynamicStateFeatures().extendedDynamicState3ColorWriteMask
			end,
		}
	)
	GraphicsPipeline:GetSet(
		"LogicOpEnabled",
		false,
		{
			path = "color_blend.logic_op_enabled",
			validate = "boolean",
			dynamic_state = "logic_op_enable_ext",
			setter = function(cmd, cache, val)
				cmd:SetLogicOpEnable(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state3 then return false end

				return device.has_logic_op_enable_dynamic_state
			end,
		}
	)
	GraphicsPipeline:GetSet(
		"LogicOp",
		"copy",
		{
			path = "color_blend.logic_op",
			enums = {
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
			},
			dynamic_state = "logic_op_ext",
			setter = function(cmd, cache, val)
				cmd:SetLogicOp(val)
			end,
			has_dynamic_state = function(device)
				if not device.has_extended_dynamic_state2 then return false end

				return device.has_logic_op_dynamic_state
			end,
		}
	)
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

local GRAPHICS_PIPELINE_STATE_PROPERTY_INFO = {}

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
	info.state_value_path = {info.state_key}
	info.dynamic_state_name = info.dynamic_state

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

	GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section] = GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section] or {}

	if info.state_subkey then
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] = GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] or {}
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key][info.state_subkey] = info
	else
		GRAPHICS_PIPELINE_STATE_PROPERTY_INFO[info.state_section][info.state_key] = info
	end

	-- Derive metadata only for properties with a valid state_section and state_key
	if not info.state_section or not info.state_key then goto continue end

	-- Derive state_keys (for assert_known_keys validation)
	local section = info.state_section
	local key = info.state_key
	local subkey = info.state_subkey

	if not section or not key then goto continue end

	-- Derive state_keys for all properties except color_blend attachment properties
	-- (color_blend attachment properties are validated separately)
	if not info.is_color_blend_attachment_property then
		state_keys[section] = state_keys[section] or {}

		if subkey then
			state_keys[section][key] = state_keys[section][key] or {}
			state_keys[section][key][subkey] = true
		else
			state_keys[section][key] = true
		end

		-- Derive state_defaults
		state_defaults[section] = state_defaults[section] or {}

		if subkey then
			state_defaults[section][key] = state_defaults[section][key] or {}
			state_defaults[section][key][subkey] = info.default
		else
			state_defaults[section][key] = info.default
		end

		-- Derive hash_key_groups (ordered list of keys per section/subsection)
		-- We collect them in registration order, which gives stable hash ordering
		if subkey then
			hash_key_groups[section] = hash_key_groups[section] or {}
			hash_key_groups[section][subkey] = hash_key_groups[section][subkey] or {}
			table.insert(hash_key_groups[section][subkey], key)
		else
			hash_key_groups[section] = hash_key_groups[section] or {}

			if not hash_key_groups[section][key] then
				hash_key_groups[section][key] = true
			end
		end

		-- Derive cache_rules and vulkan_bindings from dynamic_state_name
		if info.dynamic_state_name then
			local ds = info.dynamic_state_name
			-- For stencil face subkeys, prefix with "stencil_" to match expected cache field names
			local field

			if section == "depth_stencil" and subkey then
				field = "stencil_" .. info.state_subkey
			else
				field = info.state_key
			end

			-- Determine if value needs normalization (only for booleans)
			local normalize = false

			if info.validate == "boolean" then normalize = true end

			cache_rules[ds] = cache_rules[ds] or {}
			table.insert(
				cache_rules[ds],
				{
					field = field,
					section = section,
					key = key,
					subkey = subkey,
					default = info.default,
					normalize = normalize,
				}
			)
			vulkan_bindings[ds] = vulkan_bindings[ds] or {}
			table.insert(
				vulkan_bindings[ds],
				{
					field = field,
					section = section,
					key = key,
					subkey = subkey,
					setter = info.setter,
				}
			)
		end
	end

	-- Derive color_blend state_keys (includes both top-level and attachment properties)
	if section == "color_blend" then
		state_keys.color_blend = state_keys.color_blend or {}
		state_keys.color_blend[key] = true
	end

	::continue::
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

local function get_signature_id(self, signature)
	local color_format = signature.color_format or {}
	local formats = {}

	for i = 1, #color_format do
		if type(color_format[i]) == "table" then
			formats[i] = color_format[i][1]
		else
			formats[i] = color_format[i] or false
		end
	end

	return self.signature_interner:intern(formats, signature.depth_format or false, signature.samples or "1")
end

local function has_static_state_change(self, info)
	return info.dynamic_state_name == nil or
		not self.dynamic_states[info.dynamic_state_name]
end

do
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

	local function get_input_assembly_state_id(self, input_assembly)
		if type(input_assembly) ~= "table" then
			return self.input_assembly_state_interner:intern()
		end

		assert_known_keys("input_assembly", input_assembly, state_keys.input_assembly)
		return self.input_assembly_state_interner:internWith(input_assembly, "topology", "primitive_restart")
	end

	local function get_tessellation_state_id(self, tessellation)
		if type(tessellation) ~= "table" then
			return self.tessellation_state_interner:intern()
		end

		assert_known_keys("tessellation", tessellation, state_keys.tessellation)
		return self.tessellation_state_interner:internWith(tessellation, "patch_control_points")
	end

	local function get_multisampling_state_id(self, multisampling)
		if type(multisampling) ~= "table" then
			return self.multisampling_state_interner:intern()
		end

		assert_known_keys("multisampling", multisampling, state_keys.multisampling)
		return self.multisampling_state_interner:internWith(multisampling, "rasterization_samples", "sample_shading", "min_sample_shading")
	end

	local function get_rasterizer_state_id(self, rasterizer)
		if type(rasterizer) ~= "table" then
			return self.rasterizer_state_interner:intern()
		end

		assert_known_keys("rasterizer", rasterizer, state_keys.rasterizer)
		return self.rasterizer_state_interner:internWith(
			rasterizer,
			"polygon_mode",
			"cull_mode",
			"front_face",
			"depth_bias",
			"depth_bias_constant_factor",
			"depth_bias_clamp",
			"depth_bias_slope_factor",
			"line_width",
			"depth_clamp",
			"discard"
		)
	end

	local function get_depth_stencil_state_id(self, depth_stencil)
		if type(depth_stencil) ~= "table" then
			return self.depth_stencil_state_interner:intern()
		end

		assert_known_keys("depth_stencil", depth_stencil, state_keys.depth_stencil)
		-- Build args list: depth_stencil fields
		local args = {
			depth_stencil.depth_test,
			depth_stencil.depth_write,
			depth_stencil.depth_compare_op,
			depth_stencil.depth_bounds_test,
			depth_stencil.stencil_test,
		}

		-- Add stencil face values using derived hash_key_groups
		for _, face in ipairs({"front", "back"}) do
			local f = depth_stencil[face]
			local keys = hash_key_groups.depth_stencil and hash_key_groups.depth_stencil[face]

			if f and type(f) == "table" and keys and #keys > 0 then
				for _, k in ipairs(keys) do
					table.insert(args, f[k])
				end
			else
				-- No keys defined for this face, insert nil values for each expected key
				local expected_keys = state_defaults.depth_stencil and state_defaults.depth_stencil[face]

				if expected_keys then
					for _ in pairs(expected_keys) do
						table.insert(args, nil)
					end
				end
			end
		end

		return self.depth_stencil_state_interner:intern(unpack(args))
	end

	local function get_viewport_state_id(self, viewport)
		if type(viewport) ~= "table" then
			return self.viewport_state_interner:intern()
		end

		assert_known_keys("viewport", viewport, state_keys.viewport)
		return self.viewport_state_interner:internWith(viewport, "x", "y", "w", "h", "min_depth", "max_depth")
	end

	local function get_scissor_state_id(self, scissor)
		if type(scissor) ~= "table" then
			return self.scissor_state_interner:intern()
		end

		assert_known_keys("scissor", scissor, state_keys.scissor)
		return self.scissor_state_interner:internWith(scissor, "x", "y", "w", "h")
	end

	local function get_color_blend_state_id(self, color_blend)
		if type(color_blend) ~= "table" then
			return self.color_blend_state_interner:intern()
		end

		assert_known_keys("color_blend", color_blend, state_keys.color_blend)
		local attachments = color_blend.attachments
		local attachment_count = attachments and #attachments or 0
		-- Build args list: color_blend fields + attachment_count + attachment values
		local args = {
			color_blend.blend,
			color_blend.src_color_blend_factor,
			color_blend.dst_color_blend_factor,
			color_blend.color_blend_op,
			color_blend.src_alpha_blend_factor,
			color_blend.dst_alpha_blend_factor,
			color_blend.alpha_blend_op,
			normalize_color_write_mask(color_blend.color_write_mask),
			color_blend.logic_op_enabled,
			color_blend.logic_op,
			color_blend.constants,
			attachment_count,
		}

		-- Add each attachment's values as separate arguments (matching original descend_color_blend_attachment)
		if attachment_count > 0 then
			for i = 1, attachment_count do
				local a = attachments[i]

				if type(a) == "table" then
					table.insert(args, a.blend)
					table.insert(args, a.src_color_blend_factor)
					table.insert(args, a.dst_color_blend_factor)
					table.insert(args, a.color_blend_op)
					table.insert(args, a.src_alpha_blend_factor)
					table.insert(args, a.dst_alpha_blend_factor)
					table.insert(args, a.alpha_blend_op)
					table.insert(args, normalize_color_write_mask(a.color_write_mask))
				else
					table.insert(args, nil)
				end
			end
		end

		return self.color_blend_state_interner:intern(unpack(args))
	end

	function GraphicsPipeline:GetVariantId(overrides, signature)
		signature = signature or self.base_pipeline_signature
		local signature_id = get_signature_id(self, signature)
		-- Generate a cache key for this variant using only STATIC overrides
		local static_overrides = {}

		for section, changes in pairs(overrides or {}) do
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
		local tessellation_state_id = get_tessellation_state_id(self, static_overrides.tessellation)
		local multisampling_state_id = get_multisampling_state_id(self, static_overrides.multisampling)
		local rasterizer_state_id = get_rasterizer_state_id(self, static_overrides.rasterizer)
		local depth_stencil_state_id = get_depth_stencil_state_id(self, static_overrides.depth_stencil)
		local viewport_state_id = get_viewport_state_id(self, static_overrides.viewport)
		local scissor_state_id = get_scissor_state_id(self, static_overrides.scissor)
		local color_blend_state_id = get_color_blend_state_id(self, static_overrides.color_blend)
		return self.pipeline_variant_interner:intern(
			signature_id,
			input_assembly_state_id,
			tessellation_state_id,
			multisampling_state_id,
			rasterizer_state_id,
			depth_stencil_state_id,
			viewport_state_id,
			scissor_state_id,
			color_blend_state_id
		)
	end
end

function GraphicsPipeline:GetConfig()
	return self.active_config or self.config
end

local function get_color_attachment_count(self)
	local config = self:GetConfig()

	if type(config.ColorFormat) == "table" then
		return math.max(#config.ColorFormat, 1)
	end

	return 1
end

local function get_state(self, section, key, subkey)
	local config = self:GetConfig()

	if self.overridden_state[section] and self.overridden_state[section][key] ~= nil then
		local val = self.overridden_state[section][key]

		if subkey and type(val) == "table" and val[subkey] ~= nil then
			return val[subkey]
		end

		return val
	end

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

local function get_default_state_value(info)
	if info.compare == "list" then return list.copy(info.default) end

	return info.default
end

local function get_effective_stencil_face(self, face)
	local out = {}
	local defaults = state_defaults.depth_stencil[face] or {}

	for key, default in pairs(defaults) do
		local value = get_state(self, "depth_stencil", face, key)
		out[key] = value == nil and default or value
	end

	return out
end

local function resolve_color_blend_state(self, index, key)
	local overridden = self.overridden_state.color_blend
	local config = self:GetConfig().color_blend

	-- 1. overridden attachment
	if overridden and overridden.attachments then
		local a = overridden.attachments[index]

		if a and a[key] ~= nil then return a[key] end
	end

	-- 2. top-level override (get_state checks overrides)
	if key ~= "blend" then
		local val = get_state(self, "color_blend", key)

		if val ~= nil then return val end
	end

	-- 3. config attachment
	if config and config.attachments then
		local a = config.attachments[index]

		if a and a[key] ~= nil then return a[key] end

		-- 4. config first attachment fallback
		local first = config.attachments[1]

		if first and first[key] ~= nil then return first[key] end
	end

	-- 5. overridden top-level
	if overridden and overridden[key] ~= nil then return overridden[key] end

	-- 6. config first attachment final fallback
	if config and config.attachments and config.attachments[1] then
		return config.attachments[1][key]
	end

	return nil
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
	local config = self:GetConfig()
	local cache = {
		zero_dynamic_offsets = build_zero_offsets(self.dynamic_descriptor_count or 0),
	}

	if self.dynamic_states.color_blend_enable_ext then
		local attachment_count = get_color_attachment_count(self)

		if attachment_count > 0 then
			local enables = {}

			for i = 1, attachment_count do
				enables[i] = resolve_color_blend_state(self, i, "blend") or false
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
					src_color_blend_factor = resolve_color_blend_state(self, i, "src_color_blend_factor") or "src_alpha",
					dst_color_blend_factor = resolve_color_blend_state(self, i, "dst_color_blend_factor") or
						"one_minus_src_alpha",
					color_blend_op = resolve_color_blend_state(self, i, "color_blend_op") or "add",
					src_alpha_blend_factor = resolve_color_blend_state(self, i, "src_alpha_blend_factor") or "one",
					dst_alpha_blend_factor = resolve_color_blend_state(self, i, "dst_alpha_blend_factor") or
						"one_minus_src_alpha",
					alpha_blend_op = resolve_color_blend_state(self, i, "alpha_blend_op") or "add",
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
				masks[i] = normalize_color_write_mask(resolve_color_blend_state(self, i, "color_write_mask") or {"r", "g", "b", "a"})
			end

			cache.color_write_mask = masks
		end
	end

	-- Derive cache values from dynamic_states using cache_rules
	for ds_name, rules in pairs(cache_rules) do
		if self.dynamic_states[ds_name] then
			for _, rule in ipairs(rules) do
				local val

				if rule.subkey then
					val = get_state(self, rule.section, rule.key, rule.subkey)
				else
					val = get_state(self, rule.section, rule.key)
				end

				-- Apply normalization if needed
				if rule.normalize and val ~= nil and val ~= false and val ~= 0 then
					val = true
				end

				-- Apply default if nil
				if val == nil then val = rule.default end

				cache[rule.field] = val
			end
		end
	end

	-- Special handling for viewport/scissor (need config fallbacks)
	if self.dynamic_states.viewport then
		cache.viewport_x = get_state(self, "viewport", "x") or config.viewport and config.viewport.x or 0
		cache.viewport_y = get_state(self, "viewport", "y") or config.viewport and config.viewport.y or 0
		cache.viewport_width = get_state(self, "viewport", "w") or
			config.extent and
			config.extent.width or
			config.viewport and
			config.viewport.w or
			0
		cache.viewport_height = get_state(self, "viewport", "h") or
			config.extent and
			config.extent.height or
			config.viewport and
			config.viewport.h or
			0
		cache.viewport_min_depth = get_state(self, "viewport", "min_depth") or
			config.viewport and
			config.viewport.min_depth or
			0
		cache.viewport_max_depth = get_state(self, "viewport", "max_depth") or
			config.viewport and
			config.viewport.max_depth or
			1
	end

	if self.dynamic_states.scissor then
		cache.scissor_x = get_state(self, "scissor", "x") or config.scissor and config.scissor.x or 0
		cache.scissor_y = get_state(self, "scissor", "y") or config.scissor and config.scissor.y or 0
		cache.scissor_width = get_state(self, "scissor", "w") or
			config.extent and
			config.extent.width or
			config.scissor and
			config.scissor.w or
			0
		cache.scissor_height = get_state(self, "scissor", "h") or
			config.extent and
			config.extent.height or
			config.scissor and
			config.scissor.h or
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

	if
		rendering_state and
		rendering_state.color_formats and
		#rendering_state.color_formats > 0
	then
		color_format = rendering_state.color_formats
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
	local pipeline_extent = config.extent

	if pipeline_extent == nil and render.target and render.target:IsValid() then
		local target_extent = render.target:GetExtent()
		pipeline_extent = {
			width = tonumber(target_extent.width),
			height = tonumber(target_extent.height),
		}
	end

	local pipeline = InternalGraphicsPipeline.New(
		vulkan_instance.device,
		{
			shaderModules = shader_modules,
			extent = pipeline_extent,
			vertexBindings = vertex_bindings,
			vertexAttributes = vertex_attributes,
			input_assembly = config.input_assembly,
			tessellation = config.tessellation,
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

local function build_dynamic_state_list(device)
	local dynamic_states = {}
	local seen = {}

	for _, var_info in pairs(GraphicsPipeline.prototype_variables) do
		local ds = var_info.dynamic_state
		local has_ds = var_info.has_dynamic_state

		if ds and has_ds and has_ds(device) then
			if not seen[ds] then
				seen[ds] = true
				table.insert(dynamic_states, ds)
			end
		end
	end

	return dynamic_states
end

function GraphicsPipeline.New(vulkan_instance, config)
	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		local top_level = config[info.var_name]

		if top_level ~= nil then
			local top_level = prototype.ValidatePropertyValue(info, top_level, 3)
			config[info.var_name] = nil
			local section = config[info.state_section]

			if type(section) ~= "table" then
				section = {}
				config[info.state_section] = section
			end

			set_path_value(
				section,
				info.constructor_value_path,
				info.compare == "list" and list.copy(top_level) or top_level
			)
		end
	end

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
	local descriptor_binding_counts = {}

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
					layout_map[binding_index].update_after_bind = layout_map[binding_index].update_after_bind or ds.update_after_bind or false
				else
					layout_map[binding_index] = {
						binding_index = binding_index,
						type = ds.type,
						stageFlags = stage_bits,
						count = ds.count or 1,
						update_after_bind = ds.update_after_bind or false,
					}
					pool_size_map[ds.type] = (pool_size_map[ds.type] or 0) + (ds.count or 1)

					if ds.type == "uniform_buffer_dynamic" or ds.type == "storage_buffer_dynamic" then
						dynamic_descriptor_count = dynamic_descriptor_count + 1
					end
				end

				descriptor_binding_counts[set_index] = descriptor_binding_counts[set_index] or {}
				descriptor_binding_counts[set_index][binding_index] = layout_map[binding_index].count or 1

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

		table.sort(layout, function(a, b)
			return a.binding_index < b.binding_index
		end)

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

	if not config.Static then
		local dynamic_state_list = build_dynamic_state_list(vulkan_instance.device)
		self.dynamic_state_list = dynamic_state_list and list.copy(dynamic_state_list) or nil
		self.dynamic_states = {}

		for _, s in ipairs(dynamic_state_list) do
			self.dynamic_states[s] = true
		end
	else
		self.dynamic_state_list = nil
		self.dynamic_states = {}
	end

	-- Always use format and samples to ensure they match
	local multisampling_config = config.multisampling or {}
	multisampling_config.rasterization_samples = config.RasterizationSamples or "1"
	pipeline, shader_modules = build_internal_pipeline(vulkan_instance, pipelineLayout, config, self.dynamic_state_list)
	self.pipeline = pipeline
	self.descriptor_sets = descriptorSets
	self.pipeline_layout = pipelineLayout
	self.vulkan_instance = vulkan_instance
	self.config = config
	self.active_config = config
	self.sampler_config = common.normalize_pipeline_sampler_config(config.Sampler or config.sampler)
	self.uniform_buffers = uniform_buffers
	self.descriptor_set_layouts = descriptorSetLayouts
	self.descriptor_binding_counts = descriptor_binding_counts
	self.descriptorPools = descriptorPools -- Array of pools, one per frame
	self.shader_modules = shader_modules -- Keep shader modules alive to prevent GC
	-- GraphicsPipeline variant caching for compatibility and static state emulation
	self.base_pipeline = pipeline
	self.base_pipeline_signature = {
		color_format = config.ColorFormat,
		depth_format = config.DepthFormat,
		samples = config.RasterizationSamples or "1",
	}
	self.overridden_state = {}
	self.pipeline_variants = {}
	self.signature_interner = Hash.New()
	self.input_assembly_state_interner = Hash.New()
	self.tessellation_state_interner = Hash.New()
	self.multisampling_state_interner = Hash.New()
	self.rasterizer_state_interner = Hash.New()
	self.depth_stencil_state_interner = Hash.New()
	self.viewport_state_interner = Hash.New()
	self.scissor_state_interner = Hash.New()
	self.color_blend_state_interner = Hash.New()
	self.pipeline_variant_interner = Hash.New()
	self.base_signature_id = get_signature_id(self, self.base_pipeline_signature)
	self.base_variant_id = self:GetVariantId()
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
	common.bind_texture_registry(self)
	common.bind_sampler_config_methods(self)
	common.bind_descriptor_set_methods(self)
	self.PushConstants = common.push_constants
	self.max_textures = common.get_bindless_binding_capacity(self, 0) or 0
	self.max_cubemaps = common.get_bindless_binding_capacity(self, 1) or 0
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
						local args = ds.args

						if type(args) == "function" then args = args() end

						if type(args) ~= "table" then args = {args} end

						self:UpdateDescriptorSet(ds.type, frame_index, ds.binding_index, ds.set_index or 0, unpack(args))
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
	return self.RasterizationSamples or self.base_pipeline_signature.samples
end

function GraphicsPipeline:GetSamples()
	return self:GetRasterizationSamples()
end

function GraphicsPipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
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

	if self.descriptor_sets then
		if frame_index < 1 or self.descriptor_sets[frame_index] == nil then
			frame_index = 1
		end
	end

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

		if render.stats then render_stats.AddPipelineSwitches(1) end

		if
			graphics_pipeline_switch_count >= GRAPHICS_PIPELINE_SWITCH_WARNING_THRESHOLD and
			warned_graphics_pipeline_switch_frame ~= frame_number and
			logn and
			false
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

	-- Derive Vulkan API calls from vulkan_bindings
	for ds_name, bindings in pairs(vulkan_bindings) do
		if self.dynamic_states[ds_name] then
			for _, binding in ipairs(bindings) do
				local val = cache[binding.field]

				-- Special handling for viewport/scissor (need size check)
				if
					ds_name == "viewport" and
					(
						cache.viewport_width <= 0 or
						cache.viewport_height <= 0
					)
				then
					break
				end

				if ds_name == "scissor" and (cache.scissor_width <= 0 or cache.scissor_height <= 0) then
					break
				end

				-- Call the Vulkan setter from metadata
				if binding.setter then binding.setter(cmd, cache, val) end
			end
		end
	end

	-- Bind descriptor sets
	if self.descriptor_sets then
		do
			local dirty = self.bindless_descriptor_sets_dirty

			if dirty and dirty[frame_index] then
				local set_index = common.get_bindless_texture_set_index(self)
				self:UpdateDescriptorSetArray(frame_index, 0, set_index, self.texture_array)
				self:UpdateDescriptorSetArray(frame_index, 1, set_index, self.cubemap_array)
				dirty[frame_index] = nil
			end
		end

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
	for _, stage in ipairs(self:GetConfig().shader_stages) do
		if stage.type == "vertex" then return stage.attributes end
	end

	return nil
end

do
	local function get_property_effective_value(self, info)
		local value = get_state(self, info.state_section, info.state_key, info.state_subkey)

		if value == nil then return get_default_state_value(info) end

		if info.compare == "list" then return list.copy(value) end

		return value
	end

	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		GraphicsPipeline[info.set_name] = function(self, value)
			if value == nil then
				value = get_default_state_value(info)
			else
				value = prototype.ValidatePropertyValue(info, value, 2)

				if info.compare == "list" then value = list.copy(value) end
			end

			local current = get_property_effective_value(self, info)

			if prototype.ComparePropertyValues(info, current, value) then return end

			local section_name = info.state_section
			local key = info.state_key
			local subkey = info.state_subkey
			local section_overrides = self.overridden_state[section_name] or {}
			local changed_static = has_static_state_change(self, info)
			local stored_value = info.compare == "list" and list.copy(value) or value

			if subkey then
				section_overrides[key] = get_effective_stencil_face(self, key)
			end

			set_path_value(section_overrides, info.state_value_path, stored_value)
			self.overridden_state[section_name] = section_overrides
			self.bind_state_dirty = true

			if changed_static then self.static_variant_dirty = true end
		end
		GraphicsPipeline[info.get_name] = function(self)
			return get_property_effective_value(self, info)
		end
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
	local variant_id = self:GetVariantId(overrides, signature)
	local signature_id = get_signature_id(self, signature)

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
	local modified_config = table.copy(self.config, true)
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
					modified_config[section][k] = table.copy(modified_config[section][k])

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
