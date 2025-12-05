local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Swapchain = {}
Swapchain.__index = Swapchain

function Swapchain.New(config)
	local ptr = vulkan.T.Box(vulkan.vk.VkSwapchainKHR)()
	vulkan.assert(
		vulkan.lib.vkCreateSwapchainKHR(
			config.device.ptr[0],
			vulkan.vk.s.SwapchainCreateInfoKHR(
				{
					surface = config.surface.ptr[0],
					minImageCount = math.clamp(
						config.image_count or config.surface_capabilities.minImageCount,
						config.surface_capabilities.minImageCount,
						config.surface_capabilities.maxImageCount
					),
					imageFormat = config.surface_format.format,
					imageColorSpace = config.surface_format.color_space,
					imageExtent = config.surface_capabilities.currentExtent,
					imageArrayLayers = 1,
					imageUsage = config.image_usage or {"color_attachment", "transfer_dst"},
					imageSharingMode = "exclusive",
					preTransform = config.pre_transform or config.surface_capabilities.currentTransform,
					compositeAlpha = config.composite_alpha or "opaque_khr",
					presentMode = config.present_mode or "fifo_khr",
					clipped = config.clipped ~= nil and (config.clipped and 1 or 0) or 1,
					oldSwapchain = config.old_swapchain and config.old_swapchain.ptr[0],
					--
					flags = 0,
					queueFamilyIndexCount = 0,
				}
			),
			nil,
			ptr
		),
		"failed to create swapchain"
	)
	return setmetatable(
		{
			ptr = ptr,
			device = config.device,
			-- pointer references to prevent GC
			old_swapchain = config.old_swapchain,
			surface = config.surface,
		},
		Swapchain
	)
end

function Swapchain:__gc()
	vulkan.lib.vkDestroySwapchainKHR(self.device.ptr[0], self.ptr[0], nil)
end

function Swapchain:GetImages()
	local imageCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, nil)
	local swapchainImages = vulkan.T.Array(vulkan.vk.VkImage)(imageCount[0])
	vulkan.lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, swapchainImages)
	local out = {}

	for i = 0, imageCount[0] - 1 do
		local ptr = vulkan.T.Box(vulkan.vk.VkImage)()
		ptr[0] = swapchainImages[i]
		out[i + 1] = {ptr = ptr}
	end

	return out
end

function Swapchain:GetNextImage(imageAvailableSemaphore)
	local imageIndex = ffi.new("uint32_t[1]", 0)
	local result = vulkan.lib.vkAcquireNextImageKHR(
		self.device.ptr[0],
		self.ptr[0],
		ffi.cast("uint64_t", -1),
		imageAvailableSemaphore.ptr[0],
		nil,
		imageIndex
	)

	if result == vulkan.vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
		return nil, "out_of_date"
	elseif result == vulkan.vk.VkResult("VK_SUBOPTIMAL_KHR") then
		return imageIndex[0], "suboptimal"
	elseif result ~= 0 then
		error("failed to acquire next image: " .. vulkan.enum_to_string(result))
	end

	return imageIndex[0], "ok"
end

function Swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
	local result = vulkan.lib.vkQueuePresentKHR(
		deviceQueue.ptr[0],
		vulkan.vk.s.PresentInfoKHR(
			{
				waitSemaphoreCount = 1,
				pWaitSemaphores = renderFinishedSemaphore.ptr,
				swapchainCount = 1,
				pSwapchains = self.ptr,
				pImageIndices = imageIndex,
			}
		)
	)

	if result == vulkan.vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
		return false
	elseif result == vulkan.vk.VkResult("VK_SUBOPTIMAL_KHR") then
		return false
	elseif result ~= vulkan.vk.VkResult("VK_SUCCESS") then
		error("failed to present: " .. vulkan.enum_to_string(result))
	end

	return true
end

return Swapchain
