local ShaderModule = require("graphics.vulkan.internal.shader_module")
local DescriptorSetLayout = require("graphics.vulkan.internal.descriptor_set_layout")
local PipelineLayout = require("graphics.vulkan.internal.pipeline_layout")
local GraphicsPipeline = require("graphics.vulkan.internal.graphics_pipeline")
local DescriptorPool = require("graphics.vulkan.internal.descriptor_pool")
local ffi = require("ffi")
local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.New(vulkan_instance, config)
	local self = setmetatable({}, Pipeline)
	local uniform_buffers = {}
	local shader_modules = {}
	local layout = {}
	local pool_sizes = {}
	local push_constant_ranges = {}

	for i, stage in ipairs(config.shader_stages) do
		shader_modules[i] = {
			type = stage.type,
			module = ShaderModule.New(vulkan_instance.device, stage.code, stage.type),
		}

		if stage.descriptor_sets then
			local counts = {}

			for i, ds in ipairs(stage.descriptor_sets) do
				layout[i] = {
					binding_index = ds.binding_index,
					type = ds.type,
					stageFlags = stage.type,
					count = ds.count or 1, -- Use count from descriptor config for bindless arrays
				}
				counts[ds.type] = (counts[ds.type] or 0) + (ds.count or 1)

				if ds.type == "uniform_buffer" then
					uniform_buffers[ds.binding_index] = ds.args[1]
				end
			end

			for type, count in pairs(counts) do
				table.insert(pool_sizes, {type = type, count = count})
			end
		end

		if stage.push_constants then
			table.insert(
				push_constant_ranges,
				{
					stage = stage.type,
					offset = stage.push_constants.offset or 0,
					size = stage.push_constants.size,
				}
			)
		end
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

	-- Always use render pass sample count to ensure they match
	local multisampling_config = config.multisampling or {}

	if config.render_pass then
		multisampling_config.rasterization_samples = config.render_pass.samples
	end

	pipeline = GraphicsPipeline.New(
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
		{config.render_pass},
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
	-- Pipeline variant caching for dynamic state emulation
	self.pipeline_variants = {}
	self.current_variant_key = nil
	self.base_pipeline = pipeline

	do
		self.texture_registry = {} -- texture_object -> index mapping
		self.texture_array = {} -- array of {view, sampler} for descriptor set
		self.next_texture_index = 0
		self.max_textures = 1024
	end

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

function Pipeline:RegisterTexture(tex)
	if self.texture_registry[tex] then return self.texture_registry[tex] end

	-- Check if we have space
	if self.next_texture_index >= self.max_textures then
		error("Texture registry full! Max textures: " .. self.max_textures)
	end

	-- Register the texture
	local index = self.next_texture_index
	self.texture_registry[tex] = index
	self.texture_array[index + 1] = {view = tex.view, sampler = tex.sampler}
	self.next_texture_index = self.next_texture_index + 1

	-- Update all descriptor sets with the new texture array
	for frame_i = 1, #self.descriptor_sets do
		self:UpdateDescriptorSetArray(frame_i, 0, self.texture_array)
	end
end

function Pipeline:GetTextureIndex(tex)
	return self.texture_registry[tex] or 0
end

function Pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
	self.vulkan_instance.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
end

function Pipeline:UpdateDescriptorSetArray(frame_index, binding_index, texture_array)
	-- Update a descriptor set with an array of textures for bindless rendering
	self.vulkan_instance.device:UpdateDescriptorSetArray(self.descriptor_sets[frame_index], binding_index, texture_array)
end

function Pipeline:PushConstants(cmd, stage, binding_index, data, data_size)
	cmd:PushConstants(self.pipeline_layout, stage, binding_index, data_size or ffi.sizeof(data), data)
end

function Pipeline:GetUniformBuffer(binding_index)
	local ub = self.uniform_buffers[binding_index]

	if not ub then
		error("Invalid uniform buffer binding index: " .. binding_index)
	end

	return ub
end

function Pipeline:Bind(cmd, frame_index)
	frame_index = frame_index or 1
	cmd:BindPipeline(self.pipeline, "graphics")
	cmd:BindDescriptorSets("graphics", self.pipeline_layout, {self.descriptor_sets[frame_index]}, 0)
end

function Pipeline:GetVertexAttributes()
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

-- Rebuild pipeline with modified state
-- section: the config section to modify (e.g., "color_blend", "rasterizer")
-- changes: table with the changes to apply to that section
function Pipeline:RebuildPipeline(section, changes)
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

	-- Use render pass sample count if not explicitly specified
	local multisampling_config = modified_config.multisampling or {}

	if modified_config.render_pass then
		multisampling_config.rasterization_samples = modified_config.render_pass.samples
	end

	local new_pipeline = GraphicsPipeline.New(
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
		{modified_config.render_pass},
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
function Pipeline:ResetToBase()
	self.pipeline = self.base_pipeline
	self.current_variant_key = nil
end

-- Get information about cached variants (for debugging)
function Pipeline:GetVariantInfo()
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

return Pipeline
