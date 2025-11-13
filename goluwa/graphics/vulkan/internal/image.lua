local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ImageView = require("graphics.vulkan.internal.image_view")
local CommandPool = require("graphics.vulkan.internal.command_pool")
local Fence = require("graphics.vulkan.internal.fence")
local Image = {}
Image.__index = Image

function Image.New(device, width, height, format, usage, properties, samples)
	samples = samples or "1"
	local imageInfo = vulkan.vk.VkImageCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO",
			imageType = "VK_IMAGE_TYPE_2D",
			format = vulkan.enums.VK_FORMAT_(format),
			extent = {
				width = width,
				height = height,
				depth = 1,
			},
			mipLevels = 1,
			arrayLayers = 1,
			samples = "VK_SAMPLE_COUNT_" .. samples .. "_BIT",
			tiling = "VK_IMAGE_TILING_OPTIMAL",
			usage = vulkan.enums.VK_IMAGE_USAGE_(usage),
			sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
			initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
		}
	)
	local image_ptr = vulkan.T.Box(vulkan.vk.VkImage)()
	vulkan.assert(
		vulkan.lib.vkCreateImage(device.ptr[0], imageInfo, nil, image_ptr),
		"failed to create image"
	)
	local memRequirements = vulkan.vk.VkMemoryRequirements()
	vulkan.lib.vkGetImageMemoryRequirements(device.ptr[0], image_ptr[0], memRequirements)
	properties = vulkan.enums.VK_MEMORY_PROPERTY_(properties or "device_local")
	local allocInfo = vulkan.vk.VkMemoryAllocateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO",
			allocationSize = memRequirements.size,
			memoryTypeIndex = device.physical_device:FindMemoryType(memRequirements.memoryTypeBits, properties),
		}
	)
	local memory_ptr = vulkan.T.Box(vulkan.vk.VkDeviceMemory)()
	vulkan.assert(
		vulkan.lib.vkAllocateMemory(device.ptr[0], allocInfo, nil, memory_ptr),
		"failed to allocate image memory"
	)
	vulkan.lib.vkBindImageMemory(device.ptr[0], image_ptr[0], memory_ptr[0], 0)
	return setmetatable(
		{
			ptr = image_ptr,
			memory = memory_ptr,
			device = device,
			width = width,
			height = height,
			format = format,
			usage = usage,
		},
		Image
	)
end

function Image:__gc()
	vulkan.lib.vkDestroyImage(self.device.ptr[0], self.ptr[0], nil)
	vulkan.lib.vkFreeMemory(self.device.ptr[0], self.memory[0], nil)
end

function Image:GetWidth()
	return self.width
end

function Image:GetHeight()
	return self.height
end

function Image:CreateView()
	return ImageView.New(self.device, self, self.format)
end

function Image:TransitionLayout(old_layout, new_layout)
	-- Get the renderer instance to access queue and command pool
	-- This is a bit hacky but necessary for one-off transitions
	local render = require("graphics.render")
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local graphics_queue_family = render.GetGraphicsQueueFamily()
	-- Create temporary command buffer for the transition
	local cmd_pool = CommandPool.New(device, graphics_queue_family)
	local cmd = cmd_pool:CreateCommandBuffer()
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
