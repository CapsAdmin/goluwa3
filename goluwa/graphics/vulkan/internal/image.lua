local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ffi_helpers = require("helpers.ffi_helpers")
local e = ffi_helpers.translate_enums(
	{
		{vulkan.vk.VkFormat, "VK_FORMAT_"},
		{vulkan.vk.VkImageUsageFlagBits, "VK_IMAGE_USAGE_", "_BIT"},
		{vulkan.vk.VkMemoryPropertyFlagBits, "VK_MEMORY_PROPERTY_", "_BIT"},
		{vulkan.vk.VkImageType, "VK_IMAGE_TYPE_"},
		{vulkan.vk.VkImageTiling, "VK_IMAGE_TILING_"},
		{vulkan.vk.VkSharingMode, "VK_SHARING_MODE_"},
		{vulkan.vk.VkImageLayout, "VK_IMAGE_LAYOUT_"},
		{vulkan.vk.VkSampleCountFlagBits, "VK_SAMPLE_COUNT_", "_BIT"},
		{vulkan.vk.VkImageCreateFlagBits, "VK_IMAGE_CREATE_", "_BIT"},
	}
)
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Fence = require("graphics.vulkan.internal.fence")
local Memory = require("graphics.vulkan.internal.memory")
local Image = {}
Image.__index = Image

function Image.New(config)
	config = config or {}
	assert(config.device)
	assert(config.width)
	assert(config.height)
	assert(config.format)
	assert(config.usage)
	local ptr = vulkan.T.Box(vulkan.vk.VkImage)()
	local mip_levels = config.mip_levels or 1
	local samples = config.samples or 1
	vulkan.assert(
		vulkan.lib.vkCreateImage(
			config.device.ptr[0],
			vulkan.vk.VkImageCreateInfo(
				{
					sType = "VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO",
					flags = config.flags and e.VK_IMAGE_CREATE_(config.flags) or 0,
					imageType = e.VK_IMAGE_TYPE_(config.image_type or "2d"),
					format = e.VK_FORMAT_(config.format),
					extent = {
						width = config.width,
						height = config.height,
						depth = config.depth or 1,
					},
					mipLevels = mip_levels,
					arrayLayers = config.array_layers or 1,
					samples = e.VK_SAMPLE_COUNT_(tostring(samples)),
					tiling = e.VK_IMAGE_TILING_(config.tiling or "optimal"),
					usage = e.VK_IMAGE_USAGE_(config.usage),
					sharingMode = e.VK_SHARING_MODE_(config.sharing_mode or "exclusive"),
					initialLayout = e.VK_IMAGE_LAYOUT_(config.initial_layout or "undefined"),
				}
			),
			nil,
			ptr
		),
		"failed to create image"
	)
	local self = setmetatable(
		{
			ptr = ptr,
			device = config.device,
			width = config.width,
			height = config.height,
			format = config.format,
			usage = config.usage,
			mip_levels = mip_levels,
		},
		Image
	)
	local requirements = config.device:GetImageMemoryRequirements(self)
	self.memory = Memory.New(
		config.device,
		requirements.size,
		config.device.physical_device:FindMemoryType(requirements.memoryTypeBits, e.VK_MEMORY_PROPERTY_(config.properties or "device_local"))
	)
	self:BindMemory()
	return self
end

function Image:BindMemory()
	vulkan.assert(
		vulkan.lib.vkBindImageMemory(self.device.ptr[0], self.ptr[0], self.memory.ptr[0], 0),
		"failed to bind image memory"
	)
end

function Image:__gc()
	vulkan.lib.vkDestroyImage(self.device.ptr[0], self.ptr[0], nil)
end

function Image:GetWidth()
	return self.width
end

function Image:GetHeight()
	return self.height
end

function Image:GetMipLevels()
	return self.mip_levels or 1
end

function Image:CreateView(config)
	return ImageView.New(
		{
			device = self.device,
			image = self,
			view_type = config.view_type,
			format = config.format or self.format,
			level_count = config.level_count or self.mip_levels or 1,
			aspect = config.aspect,
			layer_count = config.layer_count,
		}
	)
end

function Image:TransitionLayout(old_layout, new_layout)
	-- Get the vulkan_instance instance to access queue and command pool
	-- This is a bit hacky but necessary for one-off transitions
	local render = require("graphics.render")
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	-- Determine access masks and stages based on layouts
	local src_access = "none"
	local dst_access = "none"
	local src_stage = "top_of_pipe"
	local dst_stage = "fragment"

	if old_layout == "undefined" then
		src_access = "none"
		src_stage = "top_of_pipe"
	end

	if new_layout == "shader_read_only_optimal" then
		dst_access = "shader_read"
		dst_stage = "fragment"
	end

	-- Transition image layout
	cmd:PipelineBarrier(
		{
			srcStage = src_stage,
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = self,
					srcAccessMask = src_access,
					dstAccessMask = dst_access,
					oldLayout = old_layout,
					newLayout = new_layout,
				},
			},
		}
	)
	cmd:End()
	-- Submit and wait for completion
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
end

return Image
