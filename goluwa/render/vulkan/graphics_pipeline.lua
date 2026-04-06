local prototype = import("goluwa/prototype.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local InternalGraphicsPipeline = import("goluwa/render/vulkan/internal/graphics_pipeline.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
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
local INPUT_ASSEMBLY_STATE_KEYS = {
	primitive_restart = true,
}

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

local function get_pipeline_variant_id(
	self,
	signature_id,
	input_assembly_state_id,
	rasterizer_state_id,
	depth_stencil_state_id,
	color_blend_state_id
)
	local node = self.pipeline_variant_id_root
	node = descend_id_node(node, signature_id)
	node = descend_id_node(node, input_assembly_state_id)
	node = descend_id_node(node, rasterizer_state_id)
	node = descend_id_node(node, depth_stencil_state_id)
	node = descend_id_node(node, color_blend_state_id)
	return finalize_id(self, node, "next_pipeline_variant_id")
end

local function get_input_assembly_state_id(self, input_assembly)
	local node = self.input_assembly_state_id_root

	if type(input_assembly) == "table" then
		assert_known_keys("input_assembly", input_assembly, INPUT_ASSEMBLY_STATE_KEYS)
		node = descend_id_node(node, input_assembly.primitive_restart)
	end

	return finalize_id(self, node, "next_input_assembly_state_id")
end

local function get_state_key_name(section, key)
	local state_key = key

	if section == "color_blend" then
		if key == "blend" then
			state_key = "color_blend_enable_ext"
		elseif key == "logic_op_enabled" then
			state_key = "logic_op_enable_ext"
		elseif key == "logic_op" then
			state_key = "logic_op_ext"
		elseif key == "color_write_mask" then
			state_key = "color_write_mask_ext"
		elseif key ~= "attachments" and key ~= "color_write_mask" then
			state_key = "color_blend_equation_ext"
		end
	elseif section == "rasterizer" then
		if key == "polygon_mode" then
			state_key = "polygon_mode_ext"
		elseif key == "front_face" then
			state_key = "front_face"
		elseif key == "depth_bias" then
			state_key = "depth_bias_enable"
		elseif
			key == "depth_bias_constant_factor" or
			key == "depth_bias_clamp" or
			key == "depth_bias_slope_factor"
		then
			state_key = "depth_bias"
		elseif key == "depth_clamp" then
			state_key = "depth_clamp_enable_ext"
		elseif key == "discard" then
			state_key = "rasterizer_discard_enable"
		end
	elseif section == "input_assembly" then
		if key == "primitive_restart" then state_key = "primitive_restart_enable" end
	elseif section == "depth_stencil" then
		if key == "depth_test" then
			state_key = "depth_test_enable"
		elseif key == "depth_write" then
			state_key = "depth_write_enable"
		elseif key == "depth_compare_op" then
			state_key = "depth_compare_op"
		elseif key == "stencil_test" then
			state_key = "stencil_test_enable"
		elseif key == "front" or key == "back" then
			state_key = "stencil_op"
		end
	end

	return state_key
end

local function has_static_state_change(self, section, key)
	return not self.dynamic_states[get_state_key_name(section, key)]
end

local function get_active_config(self)
	return self.active_config or self.config
end

local function get_color_attachment_count(self)
	local config = get_active_config(self)

	if type(config.color_format) == "table" then
		return math.max(#config.color_format, 1)
	end

	return 1
end

local function get_state(self, section, key, subkey)
	local config = get_active_config(self)

	if self.overridden_state[section] and self.overridden_state[section][key] ~= nil then
		local val = self.overridden_state[section][key]

		if subkey and type(val) == "table" then return val[subkey] end

		return val
	end

	if section == "color_blend" then
		local cb = config.color_blend

		if cb and cb.attachments and cb.attachments[1] then
			if key == "blend" then return cb.attachments[1].blend end

			return cb.attachments[1][key]
		end
	end

	if config[section] and config[section][key] ~= nil then
		local val = config[section][key]

		if subkey and type(val) == "table" then return val[subkey] end

		return val
	end

	return nil
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
	return normalize_color_write_mask(get_color_blend_state(self, index, "color_write_mask", {"R", "G", "B", "A"}))
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
		cache.viewport_width = (
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
	end

	if self.dynamic_states.scissor then
		cache.scissor_width = (
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
			color_format = self.config.color_format,
			depth_format = self.config.depth_format,
			samples = self.config.samples or "1",
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

local function build_internal_pipeline(vulkan_instance, pipeline_layout, config)
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

	local multisampling_config = config.multisampling or {}
	multisampling_config.rasterization_samples = config.samples or "1"
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
			color_blend = config.color_blend,
			dynamic_states = config.dynamic_states,
			depth_stencil = config.depth_stencil,
		},
		{{format = config.color_format, depth_format = config.depth_format}},
		pipeline_layout
	)
	pipeline._shader_modules = shader_modules
	return pipeline, shader_modules
end

function GraphicsPipeline.New(vulkan_instance, config)
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
	local descriptor_set_count = config.descriptor_set_count or 1
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
	multisampling_config.rasterization_samples = config.samples or "1"

	-- Automatic dynamic state registration if not explicitly static
	if not config.static then
		config.dynamic_states = config.dynamic_states or {"viewport", "scissor"}
		local device = vulkan_instance.device

		if device.has_extended_dynamic_state then
			table.insert(config.dynamic_states, "cull_mode")
			table.insert(config.dynamic_states, "front_face")
			table.insert(config.dynamic_states, "depth_test_enable")
			table.insert(config.dynamic_states, "depth_write_enable")
			table.insert(config.dynamic_states, "depth_compare_op")
			table.insert(config.dynamic_states, "stencil_test_enable")
			table.insert(config.dynamic_states, "stencil_op")
			table.insert(config.dynamic_states, "stencil_compare_mask")
			table.insert(config.dynamic_states, "stencil_write_mask")
			table.insert(config.dynamic_states, "stencil_reference")
		end

		if device.has_extended_dynamic_state2 then
			table.insert(config.dynamic_states, "depth_bias_enable")
			table.insert(config.dynamic_states, "depth_bias")
			table.insert(config.dynamic_states, "primitive_restart_enable")
			table.insert(config.dynamic_states, "rasterizer_discard_enable")

			if device.has_logic_op_dynamic_state then
				table.insert(config.dynamic_states, "logic_op_ext")
			end
		end

		if device.has_extended_dynamic_state3 then
			local dyn3 = device.physical_device:GetExtendedDynamicStateFeatures()

			if dyn3.extendedDynamicState3ColorBlendEnable then
				table.insert(config.dynamic_states, "color_blend_enable_ext")
			end

			if dyn3.extendedDynamicState3ColorBlendEquation then
				table.insert(config.dynamic_states, "color_blend_equation_ext")
			end

			if dyn3.extendedDynamicState3PolygonMode then
				table.insert(config.dynamic_states, "polygon_mode_ext")
			end

			if dyn3.extendedDynamicState3DepthClampEnable then
				table.insert(config.dynamic_states, "depth_clamp_enable_ext")
			end

			if dyn3.extendedDynamicState3ColorWriteMask then
				table.insert(config.dynamic_states, "color_write_mask_ext")
			end

			if device.has_logic_op_enable_dynamic_state then
				table.insert(config.dynamic_states, "logic_op_enable_ext")
			end
		end

		-- De-duplicate dynamic_states
		local unique = {}

		for i = #config.dynamic_states, 1, -1 do
			local s = config.dynamic_states[i]

			if unique[s] then
				table.remove(config.dynamic_states, i)
			else
				unique[s] = true
			end
		end
	end

	pipeline, shader_modules = build_internal_pipeline(vulkan_instance, pipelineLayout, config)
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
		color_format = config.color_format,
		depth_format = config.depth_format,
		samples = config.samples or "1",
	}
	self.overridden_state = {}
	self.dynamic_states = {}

	if config.dynamic_states then
		for _, s in ipairs(config.dynamic_states) do
			self.dynamic_states[s] = true
		end
	end

	self.pipeline_variants = {}
	self.signature_id_root = {}
	self.input_assembly_state_id_root = {}
	self.rasterizer_state_id_root = {}
	self.depth_stencil_state_id_root = {}
	self.color_blend_state_id_root = {}
	self.pipeline_variant_id_root = {}
	self.base_signature_id = get_signature_id(self, self.base_pipeline_signature)
	self.base_input_assembly_state_id = get_input_assembly_state_id(self)
	self.base_rasterizer_state_id = get_rasterizer_state_id(self)
	self.base_depth_stencil_state_id = get_depth_stencil_state_id(self)
	self.base_color_blend_state_id = get_color_blend_state_id(self)
	self.base_variant_id = get_pipeline_variant_id(
		self,
		self.base_signature_id,
		self.base_input_assembly_state_id,
		self.base_rasterizer_state_id,
		self.base_depth_stencil_state_id,
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
		if self:IsValid() then
			-- Most pipelines now use set 1 for bindless textures.
			-- If set 1 exists, use it.
			local set_index = #self.descriptor_set_layouts > 1 and 1 or 0
			self:ReleaseTextureIndex(removed_tex, set_index)
		end
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
				". Consider sorting draws by pipeline/material, reducing static SetState changes, or moving more state to dynamic state."
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
			cmd:SetViewport(0, 0, cache.viewport_width, cache.viewport_height, 0, 1)
		end
	end

	if self.dynamic_states.scissor then
		if cache.scissor_width > 0 and cache.scissor_height > 0 then
			cmd:SetScissor(0, 0, cache.scissor_width, cache.scissor_height)
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
			section ~= "rasterizer" and
			section ~= "depth_stencil" and
			section ~= "color_blend"
		then
			error("unknown static pipeline state section for variant cache: " .. tostring(section))
		end

		local static_changes = {}
		local has_static = false

		for k, v in pairs(changes or {}) do
			if has_static_state_change(self, section, k) then
				static_changes[k] = v
				has_static = true
			end
		end

		if has_static then static_overrides[section] = static_changes end
	end

	local input_assembly_state_id = get_input_assembly_state_id(self, static_overrides.input_assembly)
	local rasterizer_state_id = get_rasterizer_state_id(self, static_overrides.rasterizer)
	local depth_stencil_state_id = get_depth_stencil_state_id(self, static_overrides.depth_stencil)
	local color_blend_state_id = get_color_blend_state_id(self, static_overrides.color_blend)
	local variant_id = get_pipeline_variant_id(
		self,
		signature_id,
		input_assembly_state_id,
		rasterizer_state_id,
		depth_stencil_state_id,
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
	modified_config.color_format = signature.color_format
	modified_config.depth_format = signature.depth_format
	modified_config.samples = signature.samples

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
				modified_config[section][k] = v
			end
		end
	end

	local new_pipeline, shader_modules = build_internal_pipeline(self.vulkan_instance, self.pipeline_layout, modified_config)
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

-- High level state override. 
-- Will use dynamic state if available, or rebuild the pipeline if not.
function GraphicsPipeline:SetState(section, changes)
	if not changes then return end

	-- Normalize section names
	if section == "blend" then section = "color_blend" end

	local section_overrides = self.overridden_state[section] or {}
	local changed = false
	local changed_static = false

	for k, v in pairs(changes) do
		if section_overrides[k] ~= v then
			changed = true
			section_overrides[k] = v

			if has_static_state_change(self, section, k) then changed_static = true end
		end
	end

	if not changed then return end

	self.overridden_state[section] = section_overrides
	self.bind_state_dirty = true

	if changed_static then self.static_variant_dirty = true end
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
