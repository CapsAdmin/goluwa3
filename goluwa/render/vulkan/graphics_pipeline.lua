local prototype = require("prototype")
local ShaderModule = require("render.vulkan.internal.shader_module")
local DescriptorSetLayout = require("render.vulkan.internal.descriptor_set_layout")
local PipelineLayout = require("render.vulkan.internal.pipeline_layout")
local InternalGraphicsPipeline = require("render.vulkan.internal.graphics_pipeline")
local DescriptorPool = require("render.vulkan.internal.descriptor_pool")
local vulkan = require("render.vulkan.internal.vulkan")
local luadata = require("codecs.luadata")
local ffi = require("ffi")
local GraphicsPipeline = prototype.CreateTemplate("render_graphics_pipeline")

local function hash_table(tbl)
	return luadata.Encode(tbl)
end

function GraphicsPipeline.New(vulkan_instance, config)
	local self = GraphicsPipeline:CreateObject({})
	local uniform_buffers = {}
	local shader_modules = {}
	local layout_map = {}
	local pool_size_map = {}
	local push_constant_ranges = {}
	local all_stage_bits = 0
	local max_end = 0
	local has_push_constants = false

	for i, stage in ipairs(config.shader_stages) do
		local stage_bits = vulkan.vk.e.VkShaderStageFlagBits(stage.type)
		all_stage_bits = bit.bor(all_stage_bits, tonumber(ffi.cast("uint32_t", stage_bits)))
		shader_modules[i] = {
			type = stage_bits,
			module = ShaderModule.New(vulkan_instance.device, stage.code, stage.type),
		}

		if stage.descriptor_sets then
			for _, ds in ipairs(stage.descriptor_sets) do
				local binding_index = ds.binding_index

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
				end

				if ds.type == "uniform_buffer" then
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

	local layout = {}

	for _, l in pairs(layout_map) do
		table.insert(layout, l)
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

	local descriptorSetLayout = DescriptorSetLayout.New(vulkan_instance.device, layout)
	local pipelineLayout = PipelineLayout.New(vulkan_instance.device, {descriptorSetLayout}, push_constant_ranges)
	self.push_constant_ranges = push_constant_ranges
	-- BINDLESS DESCRIPTOR SET MANAGEMENT:
	-- For bindless rendering, we create one descriptor set per frame containing
	-- an array of all textures. The descriptor sets are updated when new textures
	-- are registered, not per-draw. Each draw just pushes a texture index.
	local descriptor_set_count = config.descriptor_set_count or 1
	local descriptorPools = {}
	local descriptorSets = {}

	for frame = 1, descriptor_set_count do
		-- Create a pool for this frame - just needs space for one descriptor set with large array
		local frame_pool_sizes = {}

		for i, pool_size in ipairs(pool_sizes) do
			frame_pool_sizes[i] = {
				type = pool_size.type,
				count = pool_size.count, -- count already accounts for array size from descriptor_sets config
			}
		end

		descriptorPools[frame] = DescriptorPool.New(vulkan_instance.device, frame_pool_sizes, 1)
		descriptorSets[frame] = descriptorPools[frame]:AllocateDescriptorSet(descriptorSetLayout)
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
			table.insert(config.dynamic_states, "stencil_test_enable")
			table.insert(config.dynamic_states, "stencil_op")
			table.insert(config.dynamic_states, "stencil_compare_mask")
			table.insert(config.dynamic_states, "stencil_write_mask")
			table.insert(config.dynamic_states, "stencil_reference")
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

	pipeline = InternalGraphicsPipeline.New(
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
		pipelineLayout
	)
	self.pipeline = pipeline
	self.descriptor_sets = descriptorSets
	self.pipeline_layout = pipelineLayout
	self.vulkan_instance = vulkan_instance
	self.config = config
	self.uniform_buffers = uniform_buffers
	self.descriptorSetLayout = descriptorSetLayout
	self.descriptorPools = descriptorPools -- Array of pools, one per frame
	self.shader_modules = shader_modules -- Keep shader modules alive to prevent GC
	-- GraphicsPipeline variant caching for dynamic state emulation
	self.pipeline_variants = {}
	self.current_variant_key = nil
	self.base_pipeline = pipeline
	self.overridden_state = {}
	self.dynamic_states = {}

	if config.dynamic_states then
		for _, s in ipairs(config.dynamic_states) do
			self.dynamic_states[s] = true
		end
	end

	do
		self.texture_registry = setmetatable({}, {__mode = "k"}) -- texture_object -> index mapping
		self.texture_array = {} -- array of {view, sampler} for descriptor set
		self.next_texture_index = 0
		self.texture_free_list = {}
		self.cubemap_registry = setmetatable({}, {__mode = "k"})
		self.cubemap_array = {}
		self.next_cubemap_index = 0
		self.cubemap_free_list = {}
		self.max_textures = 1024
	end

	local event = require("event")

	event.AddListener("TextureRemoved", self, function(removed_tex)
		if self:IsValid() then self:ReleaseTextureIndex(removed_tex) end
	end)

	-- Initialize all descriptor sets with the same initial bindings
	for frame_index = 1, descriptor_set_count do
		for i, stage in ipairs(config.shader_stages) do
			if stage.descriptor_sets then
				for i, ds in ipairs(stage.descriptor_sets) do
					if ds.args then
						self:UpdateDescriptorSet(ds.type, frame_index, ds.binding_index, unpack(ds.args))
					end
				end
			end
		end
	end

	return self
end

function GraphicsPipeline:GetFallbackView()
	local Texture = require("render.texture")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetView then return fallback:GetView() end

	return fallback and fallback.view
end

function GraphicsPipeline:GetFallbackSampler()
	local Texture = require("render.texture")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetSampler then return fallback:GetSampler() end

	return fallback and fallback.sampler
end

function GraphicsPipeline:ReleaseTextureIndex(tex)
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
			self:UpdateDescriptorSetArray(frame_i, binding_index, array)
		end
	end
end

function GraphicsPipeline:GetTextureIndex(tex)
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
				self:UpdateDescriptorSetArray(frame_i, binding_index, array)
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
				type(tex) == "table" and
				tex.GetView and
				tex:GetView()
			) or
			tex.view or
			self:GetFallbackView(),
		sampler = (
				type(tex) == "table" and
				tex.GetSampler and
				tex:GetSampler()
			) or
			tex.sampler or
			self:GetFallbackSampler(),
	}

	for frame_i = 1, #self.descriptor_sets do
		self:UpdateDescriptorSetArray(frame_i, binding_index, array)
	end

	return index
end

function GraphicsPipeline:UpdateDescriptorSet(type, index, binding_index, ...)
	local count = select("#", ...)

	if type == "combined_image_sampler" then
		if count > 2 then
			-- Multiple textures passed, convert to array and use UpdateDescriptorSetArray
			local textures = {...}
			local array = {}

			for i, tex in ipairs(textures) do
				if type(tex) == "table" and tex.view and tex.sampler then
					array[i] = {
						view = (tex.GetView and tex:GetView()) or tex.view,
						sampler = (tex.GetSampler and tex:GetSampler()) or tex.sampler,
					}
				else
					array[i] = tex
				end
			end

			self:UpdateDescriptorSetArray(index, binding_index, array)
			return
		elseif count == 1 then
			local tex = ...

			if type(tex) == "table" and (tex.view or (tex.GetView and tex:GetView())) then
				-- Single texture object passed, extract view and sampler
				self.vulkan_instance.device:UpdateDescriptorSet(
					type,
					self.descriptor_sets[index],
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

	self.vulkan_instance.device:UpdateDescriptorSet(
		type,
		self.descriptor_sets[index],
		binding_index,
		...,
		self:GetFallbackView(),
		self:GetFallbackSampler()
	)
end

function GraphicsPipeline:UpdateDescriptorSetArray(frame_index, binding_index, texture_array)
	-- Update a descriptor set with an array of textures for bindless rendering
	self.vulkan_instance.device:UpdateDescriptorSetArray(
		self.descriptor_sets[frame_index],
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

function GraphicsPipeline:Bind(cmd, frame_index)
	frame_index = frame_index or 1
	cmd:BindPipeline(self.pipeline, "graphics")

	local function get_color_attachment_count()
		if type(self.config.color_format) == "table" then
			return math.max(#self.config.color_format, 1)
		end

		return 1
	end

	-- Helper to get effective state (overridden or config)
	local function get_state(section, key, subkey)
		if self.overridden_state[section] and self.overridden_state[section][key] ~= nil then
			local val = self.overridden_state[section][key]

			if subkey and type(val) == "table" then return val[subkey] end

			return val
		end

		if section == "color_blend" then
			local cb = self.config.color_blend

			if cb and cb.attachments and cb.attachments[1] then
				if key == "blend" then return cb.attachments[1].blend end

				return cb.attachments[1][key]
			end
		end

		if self.config[section] and self.config[section][key] ~= nil then
			local val = self.config[section][key]

			if subkey and type(val) == "table" then return val[subkey] end

			return val
		end

		return nil
	end

	-- Always apply dynamic states if they are enabled in this pipeline
	if self.dynamic_states.color_blend_enable_ext then
		local attachment_count = get_color_attachment_count()

		if attachment_count > 0 then
			local enables = {}

			for i = 1, attachment_count do
				local val

				if
					self.overridden_state.color_blend and
					self.overridden_state.color_blend.attachments and
					self.overridden_state.color_blend.attachments[i]
				then
					val = self.overridden_state.color_blend.attachments[i].blend
				end

				if val == nil then
					local cb = self.config.color_blend

					if cb and cb.attachments and cb.attachments[i] and cb.attachments[i].blend ~= nil then
						val = cb.attachments[i].blend
					elseif cb and cb.attachments and cb.attachments[1] and cb.attachments[1].blend ~= nil then
						val = cb.attachments[1].blend
					elseif
						self.overridden_state.color_blend and
						self.overridden_state.color_blend.blend ~= nil
					then
						val = self.overridden_state.color_blend.blend
					elseif cb and cb.attachments and cb.attachments[1] then
						val = cb.attachments[1].blend
					else
						val = false
					end
				end

				enables[i] = val == true
			end

			cmd:SetColorBlendEnable(0, enables)
		end
	end

	if self.dynamic_states.color_blend_equation_ext then
		local attachment_count = get_color_attachment_count()

		if attachment_count > 0 then
			for i = 1, attachment_count do
				local function get_cb_state(key, default)
					local val

					if
						self.overridden_state.color_blend and
						self.overridden_state.color_blend.attachments and
						self.overridden_state.color_blend.attachments[i]
					then
						val = self.overridden_state.color_blend.attachments[i][key]
					end

					if val == nil then val = get_state("color_blend", key) end

					if val == nil then
						local cb = self.config.color_blend

						if cb and cb.attachments and cb.attachments[i] and cb.attachments[i][key] ~= nil then
							val = cb.attachments[i][key]
						elseif cb and cb.attachments and cb.attachments[1] and cb.attachments[1][key] ~= nil then
							val = cb.attachments[1][key]
						elseif
							self.overridden_state.color_blend and
							self.overridden_state.color_blend[key] ~= nil
						then
							val = self.overridden_state.color_blend[key]
						end
					end

					return val or default
				end

				cmd:SetColorBlendEquation(
					i - 1,
					{
						src_color_blend_factor = get_cb_state("src_color_blend_factor", "src_alpha"),
						dst_color_blend_factor = get_cb_state("dst_color_blend_factor", "one_minus_src_alpha"),
						color_blend_op = get_cb_state("color_blend_op", "add"),
						src_alpha_blend_factor = get_cb_state("src_alpha_blend_factor", "one"),
						dst_alpha_blend_factor = get_cb_state("dst_alpha_blend_factor", "one_minus_src_alpha"),
						alpha_blend_op = get_cb_state("alpha_blend_op", "add"),
					}
				)
			end
		end
	end

	if self.dynamic_states.polygon_mode_ext then
		cmd:SetPolygonMode(get_state("rasterizer", "polygon_mode") or "fill")
	end

	if self.dynamic_states.cull_mode then
		cmd:SetCullMode(get_state("rasterizer", "cull_mode") or "none")
	end

	if self.dynamic_states.stencil_test_enable then
		cmd:SetStencilTestEnable(get_state("depth_stencil", "stencil_test") == true)
	end

	if self.dynamic_states.stencil_op then
		cmd:SetStencilOp(
			"front_and_back",
			get_state("depth_stencil", "front", "fail_op") or "keep",
			get_state("depth_stencil", "front", "pass_op") or "keep",
			get_state("depth_stencil", "front", "depth_fail_op") or "keep",
			get_state("depth_stencil", "front", "compare_op") or "always"
		)
	end

	if self.dynamic_states.stencil_reference then
		cmd:SetStencilReference("front_and_back", get_state("depth_stencil", "front", "reference") or 0)
	end

	if self.dynamic_states.stencil_compare_mask then
		cmd:SetStencilCompareMask("front_and_back", get_state("depth_stencil", "front", "compare_mask") or 0xFF)
	end

	if self.dynamic_states.stencil_write_mask then
		cmd:SetStencilWriteMask("front_and_back", get_state("depth_stencil", "front", "write_mask") or 0xFF)
	end

	if self.dynamic_states.viewport then
		local width = (
				self.config.extent and
				self.config.extent.width
			)
			or
			(
				self.config.viewport and
				self.config.viewport.w
			)
			or
			0
		local height = (
				self.config.extent and
				self.config.extent.height
			)
			or
			(
				self.config.viewport and
				self.config.viewport.h
			)
			or
			0

		if width > 0 and height > 0 then
			cmd:SetViewport(0, 0, width, height, 0, 1)
		end
	end

	if self.dynamic_states.scissor then
		local width = (
				self.config.extent and
				self.config.extent.width
			)
			or
			(
				self.config.scissor and
				self.config.scissor.w
			)
			or
			0
		local height = (
				self.config.extent and
				self.config.extent.height
			)
			or
			(
				self.config.scissor and
				self.config.scissor.h
			)
			or
			0

		if width > 0 and height > 0 then cmd:SetScissor(0, 0, width, height) end
	end

	-- Bind descriptor sets
	if self.descriptor_sets then
		local ds = self.descriptor_sets[frame_index] or self.descriptor_sets[1]

		if ds then
			cmd:BindDescriptorSets("graphics", self.pipeline_layout, {ds}, 0)
		end
	end
end

function GraphicsPipeline:GetVertexAttributes()
	-- Find the vertex shader stage in config
	for _, stage in ipairs(self.config.shader_stages) do
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
	local event = require("event")
	event.RemoveListener("TextureRemoved", self)

	if self.descriptorPools then
		for _, pool in ipairs(self.descriptorPools) do
			pool:Remove()
		end
	end

	if self.pipeline then self.pipeline:Remove() end

	if self.descriptorSetLayout then self.descriptorSetLayout:Remove() end

	if self.pipeline_layout then self.pipeline_layout:Remove() end
end

-- Rebuild pipeline with modified state
-- overrides: table where keys are sections (e.g., "color_blend") and values are change tables
function GraphicsPipeline:RebuildPipeline(overrides)
	-- Generate a cache key for this variant using only STATIC overrides
	local static_overrides = {}

	for section, changes in pairs(overrides) do
		local static_changes = {}
		local has_static = false

		for k, v in pairs(changes or {}) do
			local state_key = k

			if section == "color_blend" then
				if k == "blend" then
					state_key = "color_blend_enable_ext"
				elseif k ~= "attachments" and k ~= "color_write_mask" then
					state_key = "color_blend_equation_ext"
				end
			elseif section == "rasterizer" then
				if k == "polygon_mode" then state_key = "polygon_mode_ext" end
			elseif section == "depth_stencil" then
				if k == "stencil_test" then
					state_key = "stencil_test_enable"
				elseif k == "front" or k == "back" then
					state_key = "stencil_op"
				end
			end

			if not self.dynamic_states[state_key] then
				static_changes[k] = v
				has_static = true
			end
		end

		if has_static then static_overrides[section] = static_changes end
	end

	local variant_key = hash_table(static_overrides)

	if variant_key == "" or variant_key == "{\n}" then
		self.pipeline = self.base_pipeline
		self.current_variant_key = nil
		return
	end

	-- Return cached variant if it exists
	if self.pipeline_variants[variant_key] then
		self.current_variant_key = variant_key
		self.pipeline = self.pipeline_variants[variant_key]
		return
	end

	-- Create a modified config
	local modified_config = deep_copy(self.config)

	-- Apply ALL overrides (both static and dynamic ones, though dynamic ones don't STRICTLY need to be in the baked pipeline, it's safer)
	for section, changes in pairs(overrides) do
		if section == "color_blend" then
			modified_config.color_blend = modified_config.color_blend or {}
			modified_config.color_blend.attachments = modified_config.color_blend.attachments or {{}}

			-- Apply changes to first attachment (index 1)
			for k, v in pairs(changes) do
				modified_config.color_blend.attachments[1][k] = v
			end
		else
			modified_config[section] = modified_config[section] or {}

			for k, v in pairs(changes) do
				modified_config[section][k] = v
			end
		end
	end

	-- Build the new pipeline variant
	local shader_modules = {}

	for i, stage in ipairs(modified_config.shader_stages) do
		shader_modules[i] = {
			type = stage.type,
			module = ShaderModule.New(self.vulkan_instance.device, stage.code, stage.type),
		}
	end

	local vertex_bindings
	local vertex_attributes

	for i, stage in ipairs(modified_config.shader_stages) do
		if stage.type == "vertex" then
			vertex_bindings = stage.bindings
			vertex_attributes = stage.attributes

			break
		end
	end

	-- Use format and samples if not explicitly specified
	local multisampling_config = modified_config.multisampling or {}
	multisampling_config.rasterization_samples = modified_config.samples or "1"
	local new_pipeline = InternalGraphicsPipeline.New(
		self.vulkan_instance.device,
		{
			shaderModules = shader_modules,
			extent = modified_config.extent,
			vertexBindings = vertex_bindings,
			vertexAttributes = vertex_attributes,
			input_assembly = modified_config.input_assembly,
			rasterizer = modified_config.rasterizer,
			viewport = modified_config.viewport,
			scissor = modified_config.scissor,
			multisampling = multisampling_config,
			color_blend = modified_config.color_blend,
			dynamic_states = modified_config.dynamic_states,
			depth_stencil = modified_config.depth_stencil,
		},
		{
			{
				format = modified_config.color_format,
				depth_format = modified_config.depth_format,
			},
		},
		self.pipeline_layout
	)
	-- Store shader modules with the pipeline variant to prevent GC
	new_pipeline._shader_modules = shader_modules
	-- Cache the variant
	self.pipeline_variants[variant_key] = new_pipeline
	self.current_variant_key = variant_key
	self.pipeline = new_pipeline
end

-- High level state override. 
-- Will use dynamic state if available, or rebuild the pipeline if not.
function GraphicsPipeline:SetState(section, changes)
	if not changes then return end

	-- Normalize section names
	if section == "blend" then section = "color_blend" end

	local section_overrides = self.overridden_state[section] or {}
	local changed_static = false

	for k, v in pairs(changes) do
		if section_overrides[k] ~= v then
			section_overrides[k] = v
			local state_key = k

			if section == "color_blend" then
				if k == "blend" then
					state_key = "color_blend_enable_ext"
				elseif k ~= "attachments" and k ~= "color_write_mask" then
					state_key = "color_blend_equation_ext"
				end
			elseif section == "rasterizer" then
				if k == "polygon_mode" then state_key = "polygon_mode_ext" end
			elseif section == "depth_stencil" then
				if k == "stencil_test" then
					state_key = "stencil_test_enable"
				elseif k == "front" or k == "back" then
					state_key = "stencil_op"
				end
			end

			if not self.dynamic_states[state_key] then changed_static = true end
		end
	end

	self.overridden_state[section] = section_overrides

	if changed_static then self:RebuildPipeline(self.overridden_state) end
end

-- Reset to base pipeline
function GraphicsPipeline:ResetToBase()
	self.pipeline = self.base_pipeline
	self.current_variant_key = nil
	self.overridden_state = {}
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
		current = self.current_variant_key,
	}
end

return GraphicsPipeline:Register()
