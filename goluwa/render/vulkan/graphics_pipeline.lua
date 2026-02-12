local prototype = require("prototype")
local ShaderModule = require("render.vulkan.internal.shader_module")
local DescriptorSetLayout = require("render.vulkan.internal.descriptor_set_layout")
local PipelineLayout = require("render.vulkan.internal.pipeline_layout")
local InternalGraphicsPipeline = require("render.vulkan.internal.graphics_pipeline")
local DescriptorPool = require("render.vulkan.internal.descriptor_pool")
local vulkan = require("render.vulkan.internal.vulkan")
local ffi = require("ffi")
local GraphicsPipeline = prototype.CreateTemplate("render_graphics_pipeline")

function GraphicsPipeline.New(vulkan_instance, config)
	local self = GraphicsPipeline:CreateObject({})
	local uniform_buffers = {}
	local shader_modules = {}
	local layout_map = {}
	local pool_size_map = {}
	local push_constant_ranges = {}
	local all_stage_bits = 0
	local min_offset = 1000000
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
			min_offset = math.min(min_offset, offset)
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
	return Texture.GetFallback():GetView()
end

function GraphicsPipeline:GetFallbackSampler()
	local Texture = require("render.texture")
	return Texture.GetFallback():GetSampler()
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
		view = tex.view or self:GetFallbackView(),
		sampler = tex.sampler or self:GetFallbackSampler(),
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
					array[i] = {view = tex.view, sampler = tex.sampler}
				else
					array[i] = tex
				end
			end

			self:UpdateDescriptorSetArray(index, binding_index, array)
			return
		elseif count == 1 then
			local tex = ...

			if type(tex) == "table" and tex.view and tex.sampler then
				-- Single texture object passed, extract view and sampler
				self.vulkan_instance.device:UpdateDescriptorSet(
					type,
					self.descriptor_sets[index],
					binding_index,
					tex.view,
					tex.sampler,
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
	-- Set stencil test enable to satisfy dynamic state requirements
	-- Only call this if stencil_test_enable is in the dynamic states list
	local device = self.vulkan_instance.device

	if device.has_extended_dynamic_state and self.config.dynamic_states then
		local has_stencil_test_enable_dynamic = false
		local has_cull_mode_dynamic = false

		for _, state in ipairs(self.config.dynamic_states) do
			if state == "stencil_test_enable" then
				has_stencil_test_enable_dynamic = true
			elseif state == "cull_mode" then
				has_cull_mode_dynamic = true
			end
		end

		if has_cull_mode_dynamic then
			local rasterizer = self.config.rasterizer or {}
			cmd:SetCullMode(rasterizer.cull_mode or "none")
		end

		if has_stencil_test_enable_dynamic then
			local stencil_test = (self.config.depth_stencil and self.config.depth_stencil.stencil_test) or false
			cmd:SetStencilTestEnable(stencil_test)

			-- If stencil test is enabled, also set the other required stencil dynamic states
			if stencil_test then
				local depth_stencil = self.config.depth_stencil or {}
				local front = depth_stencil.front or {}
				cmd:SetStencilOp(
					"front_and_back",
					front.fail_op or "keep",
					front.pass_op or "keep",
					front.depth_fail_op or "keep",
					front.compare_op or "always"
				)
				cmd:SetStencilReference("front_and_back", front.reference or 0)
				cmd:SetStencilCompareMask("front_and_back", front.compare_mask or 0xFF)
				cmd:SetStencilWriteMask("front_and_back", front.write_mask or 0xFF)
			end
		end
	end

	-- Bind descriptor sets - they should always exist for pipelines with descriptor sets
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

-- Generate a hash key from a state table
local function hash_state(state)
	local keys = {}

	for k in pairs(state) do
		table.insert(keys, k)
	end

	table.sort(keys)
	local parts = {}

	for _, k in ipairs(keys) do
		local v = state[k]

		if type(v) == "table" then
			table.insert(parts, k .. "=" .. hash_state(v))
		else
			table.insert(parts, k .. "=" .. tostring(v))
		end
	end

	return table.concat(parts, ";")
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
-- section: the config section to modify (e.g., "color_blend", "rasterizer")
-- changes: table with the changes to apply to that section
function GraphicsPipeline:RebuildPipeline(section, changes)
	if not changes then return end

	-- Generate a cache key for this variant
	local variant_key = section .. ":" .. hash_state(changes)

	-- Return cached variant if it exists
	if self.pipeline_variants[variant_key] then
		self.current_variant_key = variant_key
		self.pipeline = self.pipeline_variants[variant_key]
		return
	end

	-- Create a modified config
	local modified_config = deep_copy(self.config)

	-- Apply changes to the specified section
	if section == "color_blend" then
		-- For color_blend, we need to handle the attachments array specially
		modified_config.color_blend = modified_config.color_blend or {}
		modified_config.color_blend.attachments = modified_config.color_blend.attachments or {{}}

		-- Apply changes to first attachment (index 1)
		for k, v in pairs(changes) do
			modified_config.color_blend.attachments[1][k] = v
		end
	else
		-- For other sections, just merge the changes
		modified_config[section] = modified_config[section] or {}

		for k, v in pairs(changes) do
			modified_config[section][k] = v
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

-- Reset to base pipeline
function GraphicsPipeline:ResetToBase()
	self.pipeline = self.base_pipeline
	self.current_variant_key = nil
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
