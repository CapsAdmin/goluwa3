local ffi = require("ffi")
local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.New(renderer, config)
	local self = setmetatable({}, Pipeline)
	local uniform_buffers = {}
	local shader_modules = {}
	local layout = {}
	local pool_sizes = {}
	local push_constant_ranges = {}

	for i, stage in ipairs(config.shader_stages) do
		shader_modules[i] = {
			type = stage.type,
			module = renderer.device:CreateShaderModule(stage.code, stage.type),
		}

		if stage.descriptor_sets then
			local counts = {}

			for i, ds in ipairs(stage.descriptor_sets) do
				layout[i] = {
					binding_index = ds.binding_index,
					type = ds.type,
					stageFlags = stage.type,
					count = 1,
				}
				counts[ds.type] = (counts[ds.type] or 0) + 1

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

	local descriptorSetLayout = renderer.device:CreateDescriptorSetLayout(layout)
	local pipelineLayout = renderer.device:CreatePipelineLayout({descriptorSetLayout}, push_constant_ranges)

	-- Create one descriptor set per swapchain image for frame buffering
	local descriptor_set_count = #renderer.swapchain_images

	-- Multiply pool sizes by descriptor_set_count since we need that many of each descriptor
	for i, pool_size in ipairs(pool_sizes) do
		pool_size.count = pool_size.count * descriptor_set_count
	end

	local descriptorPool = renderer.device:CreateDescriptorPool(pool_sizes, descriptor_set_count)
	local descriptorSets = {}
	for i = 1, descriptor_set_count do
		descriptorSets[i] = descriptorPool:AllocateDescriptorSet(descriptorSetLayout)
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

	pipeline = renderer.device:CreateGraphicsPipeline(
		{
			shaderModules = shader_modules,
			extent = config.extent,
			vertexBindings = vertex_bindings,
			vertexAttributes = vertex_attributes,
			input_assembly = config.input_assembly,
			rasterizer = config.rasterizer,
			viewport = config.viewport,
			scissor = config.scissor,
			multisampling = config.multisampling,
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
	self.renderer = renderer
	self.config = config
	self.uniform_buffers = uniform_buffers
	self.descriptorSetLayout = descriptorSetLayout
	self.descriptorPool = descriptorPool

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

function Pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
	self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
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
		if stage.type == "vertex" then
			return stage.attributes
		end
	end
	return nil
end

return Pipeline
