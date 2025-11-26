local ShaderModule = require("graphics.vulkan.internal.shader_module")
local DescriptorSetLayout = require("graphics.vulkan.internal.descriptor_set_layout")
local PipelineLayout = require("graphics.vulkan.internal.pipeline_layout")
local ComputePipelineInternal = require("graphics.vulkan.internal.compute_pipeline")
local DescriptorPool = require("graphics.vulkan.internal.descriptor_pool")
local ComputePipeline = {}
ComputePipeline.__index = ComputePipeline
local storage_images = {}
local storage_image_views = {}

local function create_storage_images(self, extent)
	local Texture = require("graphics.texture")
	self.storage_textures = {}

	for i = 1, 2 do
		local tex = Texture.New(
			{
				width = 512,
				height = 512,
				format = "R8G8B8A8_UNORM",
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "mirrored_repeat",
				wrap_t = "mirrored_repeat",
				mip_map_levels = 1,
				usage = {"storage", "sampled", "transfer_dst", "transfer_src"},
			}
		)
		tex:Shade([[
			float n = fract(sin(dot(uv * 12.9898, vec2(78.233, 37.719))) * 43758.5453);
			return vec4(vec3(n), 1.0);
		]])
		tex:GetImage():TransitionLayout("shader_read_only_optimal", "general")
		self.storage_textures[i] = tex
	end
end

function ComputePipeline.New(vulkan_instance, config)
	local self = setmetatable({}, ComputePipeline)
	self.vulkan_instance = vulkan_instance
	self.config = config
	self.current_texture_index = 1
	local shader = ShaderModule.New(vulkan_instance.device, config.shader, "compute")
	local descriptor_set_layout = DescriptorSetLayout.New(vulkan_instance.device, config.descriptor_layout)
	local push_constant_ranges = config.push_constant_ranges or {}
	local pipeline_layout = PipelineLayout.New(vulkan_instance.device, {descriptor_set_layout}, push_constant_ranges)
	local pipeline = ComputePipelineInternal.New(vulkan_instance.device, shader, pipeline_layout)
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
	create_storage_images(self)
	self:UpdateDescriptorSet("storage_image", 1, 0, self.storage_textures[1]:GetView())
	self:UpdateDescriptorSet("storage_image", 1, 1, self.storage_textures[2]:GetView())
	self:UpdateDescriptorSet("storage_image", 2, 0, self.storage_textures[2]:GetView())
	self:UpdateDescriptorSet("storage_image", 2, 1, self.storage_textures[1]:GetView())
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
		{self.descriptor_sets[self.current_texture_index]},
		0
	)
	local w = 512
	local h = 512
	-- Dispatch compute shader
	local group_count_x = math.ceil(w / self.workgroup_size)
	local group_count_y = math.ceil(h / self.workgroup_size)
	cmd:Dispatch(group_count_x, group_count_y, 1)
	-- Barrier: compute write -> fragment read
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.storage_textures[(self.current_texture_index % #self.storage_textures) + 1]:GetImage(),
					srcAccessMask = "shader_write",
					dstAccessMask = "shader_read",
					oldLayout = "general",
					newLayout = "general",
				},
			},
		}
	)
	-- Swap descriptor sets for next frame
	self.current_texture_index = (self.current_texture_index % #self.storage_textures) + 1
end

return ComputePipeline
