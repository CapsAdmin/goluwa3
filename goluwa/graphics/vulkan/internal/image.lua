local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Fence = require("graphics.vulkan.internal.fence")
local Memory = require("graphics.vulkan.internal.memory")
local Image = {}
Image.__index = Image

function Image.New(config)
	local device = config.device
	local width = config.width
	local height = config.height
	local format = config.format
	local usage = config.usage
	local properties = config.properties or "device_local"
	local samples = config.samples
	local mip_levels = config.mip_levels or 1
	local ptr = vulkan.T.Box(vulkan.vk.VkImage)()
	vulkan.assert(
		vulkan.lib.vkCreateImage(
			device.ptr[0],
			vulkan.vk.VkImageCreateInfo(
				{
					sType = "VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO",
					imageType = "VK_IMAGE_TYPE_2D",
					format = vulkan.enums.VK_FORMAT_(format),
					extent = {
						width = width,
						height = height,
						depth = 1,
					},
					mipLevels = mip_levels,
					arrayLayers = 1,
					samples = "VK_SAMPLE_COUNT_" .. (samples or "1") .. "_BIT",
					tiling = "VK_IMAGE_TILING_OPTIMAL",
					usage = vulkan.enums.VK_IMAGE_USAGE_(usage),
					sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
					initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
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
			device = device,
			width = width,
			height = height,
			format = format,
			usage = usage,
			mip_levels = mip_levels,
		},
		Image
	)
	local requirements = device:GetImageMemoryRequirements(self)
	self.memory = Memory.New(
		device,
		requirements.size,
		device.physical_device:FindMemoryType(requirements.memoryTypeBits, vulkan.enums.VK_MEMORY_PROPERTY_(properties))
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

function Image:CreateView()
	return ImageView.New(
		{
			device = self.device,
			image = self,
			format = self.format,
			level_count = self.mip_levels or 1,
		}
	)
end

function Image:TransitionLayout(old_layout, new_layout)
	-- Get the render_instance instance to access queue and command pool
	-- This is a bit hacky but necessary for one-off transitions
	local render = require("graphics.render")
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local graphics_queue_family = render.GetGraphicsQueueFamily()
	-- Create temporary command buffer for the transition
	local cmd_pool = CommandPool.New(device, graphics_queue_family)
	local cmd = cmd_pool:AllocateCommandBuffer()
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
