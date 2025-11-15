local ShaderModule = require("graphics.vulkan.internal.shader_module")
local DescriptorSetLayout = require("graphics.vulkan.internal.descriptor_set_layout")
local PipelineLayout = require("graphics.vulkan.internal.pipeline_layout")
local ComputePipeline = {}
ComputePipeline.__index = ComputePipeline

function ComputePipeline.New(vulkan_instance, config)
	local self = setmetatable({}, ComputePipeline)
	self.vulkan_instance = vulkan_instance
	self.config = config
	self.current_image_index = 1
	local shader = ShaderModule.New(vulkan_instance.device, config.shader, "compute")
	local descriptor_set_layout = DescriptorSetLayout.New(vulkan_instance.device, config.descriptor_layout)
	local pipeline_layout = PipelineLayout.New(vulkan_instance.device, {descriptor_set_layout})
	local pipeline = GraphicsPipeline.New(vulkan_instance.device, shader, pipeline_layout)
	local descriptor_set_count = config.descriptor_set_count or 1
	local descriptor_pool = DescriptorPool.New(vulkan_instance.device, config.descriptor_pool, descriptor_set_count)
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
	self.vulkan_instance.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
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
	local extent = self.vulkan_instance:GetExtent()
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
