local ComputePipeline = {}
ComputePipeline.__index = ComputePipeline

function ComputePipeline.New(renderer, config)
	local self = setmetatable({}, ComputePipeline)
	self.renderer = renderer
	self.config = config
	self.current_image_index = 1
	-- Create shader module
	local shader = renderer.device:CreateShaderModule(config.shader, "compute")
	-- Create descriptor set layout
	local descriptor_set_layout = renderer.device:CreateDescriptorSetLayout(config.descriptor_layout)
	local pipeline_layout = renderer.device:CreatePipelineLayout({descriptor_set_layout})
	-- Create compute pipeline
	local pipeline = renderer.device:CreateComputePipeline(shader, pipeline_layout)
	-- Determine number of descriptor sets (for ping-pong or single set)
	local descriptor_set_count = config.descriptor_set_count or 1
	-- Create descriptor pool
	local descriptor_pool = renderer.device:CreateDescriptorPool(config.descriptor_pool, descriptor_set_count)
	-- Create descriptor sets
	local descriptor_sets = {}

	for i = 1, descriptor_set_count do
		descriptor_sets[i] = descriptor_pool:AllocateDescriptorSet(descriptor_set_layout)
	end

	self.shader = shader
	self.pipeline = pipeline
	self.pipeline_layout = pipeline_layout
	self.descriptor_set_layout = descriptor_set_layout
	self.descriptor_pool = descriptor_pool
	self.descriptor_sets = descriptor_sets
	self.workgroup_size = config.workgroup_size or 16
	return self
end

function ComputePipeline:UpdateDescriptorSet(type, index, binding_index, ...)
	self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
end

function ComputePipeline:Dispatch(cmd)
	-- Bind compute pipeline
	cmd:BindPipeline(self.pipeline, "compute")
	cmd:BindDescriptorSets(
		"compute",
		self.pipeline_layout,
		{self.descriptor_sets[self.current_image_index]},
		0
	)
	local extent = self.renderer:GetExtent()
	local w = tonumber(extent.width)
	local h = tonumber(extent.height)
	-- Dispatch compute shader
	local group_count_x = math.ceil(w / self.workgroup_size)
	local group_count_y = math.ceil(h / self.workgroup_size)
	cmd:Dispatch(group_count_x, group_count_y, 1)
end

function ComputePipeline:SwapImages()
	-- Swap images for next frame (useful for ping-pong patterns)
	self.current_image_index = (self.current_image_index % #self.descriptor_sets) + 1
end

return ComputePipeline
