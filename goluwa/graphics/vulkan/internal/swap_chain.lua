local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Swapchain = {}
Swapchain.__index = Swapchain

-- config options:
--   presentMode: VkPresentModeKHR (default: "VK_PRESENT_MODE_FIFO_KHR")
--   imageCount: number of images in swapchain (default: surfaceCapabilities.minImageCount)
--   compositeAlpha: VkCompositeAlphaFlagBitsKHR (default: "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR")
--   clipped: boolean (default: true)
--   imageUsage: VkImageUsageFlags (default: COLOR_ATTACHMENT_BIT | TRANSFER_DST_BIT)
--   preTransform: VkSurfaceTransformFlagBitsKHR (default: currentTransform)
function Swapchain.New(device, surface, surfaceFormat, surfaceCapabilities, config, old_swapchain)
	config = config or {}
	local imageCount = config.imageCount or surfaceCapabilities.minImageCount
	local presentMode = vulkan.enums.VK_PRESENT_MODE_(config.presentMode or "fifo")
	local compositeAlpha = vulkan.enums.VK_COMPOSITE_ALPHA_(config.compositeAlpha or "opaque")
	local clipped = config.clipped ~= nil and (config.clipped and 1 or 0) or 1
	local preTransform = config.preTransform or surfaceCapabilities.currentTransform
	local imageUsage = vulkan.enums.VK_IMAGE_USAGE_(config.imageUsage or {"color_attachment", "transfer_dst"})

	-- Clamp image count to valid range
	if imageCount < surfaceCapabilities.minImageCount then
		imageCount = surfaceCapabilities.minImageCount
	end

	if
		surfaceCapabilities.maxImageCount > 0 and
		imageCount > surfaceCapabilities.maxImageCount
	then
		imageCount = surfaceCapabilities.maxImageCount
	end

	local swapchainCreateInfo = vulkan.vk.VkSwapchainCreateInfoKHR(
		{
			sType = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR",
			surface = surface.ptr[0],
			minImageCount = imageCount,
			imageFormat = vulkan.enums.VK_FORMAT_(surfaceFormat.format),
			imageColorSpace = vulkan.enums.VK_COLOR_SPACE_(surfaceFormat.color_space),
			imageExtent = surfaceCapabilities.currentExtent,
			imageArrayLayers = 1,
			imageUsage = imageUsage,
			imageSharingMode = "VK_SHARING_MODE_EXCLUSIVE",
			preTransform = preTransform,
			compositeAlpha = vulkan.vk.VkCompositeAlphaFlagBitsKHR(compositeAlpha),
			presentMode = presentMode,
			clipped = clipped,
			oldSwapchain = old_swapchain and old_swapchain.ptr[0],
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkSwapchainKHR)()
	vulkan.assert(
		vulkan.lib.vkCreateSwapchainKHR(device.ptr[0], swapchainCreateInfo, nil, ptr),
		"failed to create swapchain"
	)
	return setmetatable({ptr = ptr, device = device}, Swapchain)
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
	local presentInfo = vulkan.vk.VkPresentInfoKHR(
		{
			sType = "VK_STRUCTURE_TYPE_PRESENT_INFO_KHR",
			waitSemaphoreCount = 1,
			pWaitSemaphores = renderFinishedSemaphore.ptr,
			swapchainCount = 1,
			pSwapchains = self.ptr,
			pImageIndices = imageIndex,
		}
	)
	local result = vulkan.lib.vkQueuePresentKHR(deviceQueue.ptr[0], presentInfo)

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
