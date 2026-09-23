local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Swapchain = objects.CreateTemplate("vulkan_swap_chain")
local VkImageArray = ffi.typeof("$[?]", vulkan.vk.VkImage)
local VkSwapchainKHRBox = ffi.typeof("$[1]", vulkan.vk.VkSwapchainKHR)
local VkImageBox = ffi.typeof("$[1]", vulkan.vk.VkImage)

local function get_image_count(config)
	local desired = config.image_count or config.surface_capabilities.minImageCount
	local min = config.surface_capabilities.minImageCount
	local max = config.surface_capabilities.maxImageCount

	if max == 0 then return math.max(desired, min) end

	return math.clamp(desired, min, max)
end

function Swapchain.New(config)
	local ptr = VkSwapchainKHRBox()
	vulkan.assert(
		vulkan.lib.vkCreateSwapchainKHR(
			config.device.ptr[0],
			vulkan.vk.s.SwapchainCreateInfoKHR{
				surface = config.surface.ptr[0],
				minImageCount = get_image_count(config),
				imageFormat = config.surface_format.format,
				imageColorSpace = config.surface_format.color_space,
				imageExtent = config.surface_capabilities.currentExtent,
				imageArrayLayers = 1,
				imageUsage = config.image_usage or {"color_attachment", "transfer_dst", "transfer_src"},
				imageSharingMode = "exclusive",
				preTransform = config.pre_transform or config.surface_capabilities.currentTransform,
				compositeAlpha = config.composite_alpha or "opaque_khr",
				presentMode = config.present_mode or "fifo_khr",
				clipped = config.clipped ~= nil and (config.clipped and 1 or 0) or 1,
				oldSwapchain = config.old_swapchain and config.old_swapchain.ptr[0],
				--
				flags = 0,
				queueFamilyIndexCount = 0,
			},
			nil,
			ptr
		),
		"failed to create swapchain"
	)
	return Swapchain:CreateObject{
		ptr = ptr,
		device = config.device,
		format = config.surface_format.format,
		width = config.surface_capabilities.currentExtent.width,
		height = config.surface_capabilities.currentExtent.height,
		-- pointer references to prevent GC
		old_swapchain = config.old_swapchain,
		surface = config.surface,
	}
end

do
	local HdrMetadata = ffi.typeof("$[1]", vulkan.vk.VkHdrMetadataEXT)

	-- Describes the content to the compositor or display (VK_EXT_hdr_metadata)
	-- so it can fit it to what the display can show. primaries are CIE xy
	-- pairs {red, green, blue, white}, luminances in nits. Returns false when
	-- the extension isn't enabled.
	function Swapchain:SetHdrMetadata(t)
		local set = self.device:TryGetExtension("vkSetHdrMetadataEXT")

		if not set then return false end

		local metadata = HdrMetadata()
		local m = metadata[0]
		m.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_HDR_METADATA_EXT
		m.displayPrimaryRed.x, m.displayPrimaryRed.y = t.primaries[1][1], t.primaries[1][2]
		m.displayPrimaryGreen.x, m.displayPrimaryGreen.y = t.primaries[2][1], t.primaries[2][2]
		m.displayPrimaryBlue.x, m.displayPrimaryBlue.y = t.primaries[3][1], t.primaries[3][2]
		m.whitePoint.x, m.whitePoint.y = t.primaries[4][1], t.primaries[4][2]
		m.maxLuminance = t.max_luminance
		m.minLuminance = t.min_luminance
		m.maxContentLightLevel = t.max_content_light_level
		m.maxFrameAverageLightLevel = t.max_frame_average_light_level
		set(self.device.ptr[0], 1, self.ptr, metadata)
		return true
	end
end

function Swapchain:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroySwapchainKHR(self.device.ptr[0], self.ptr[0], nil)
	end
end

function Swapchain:GetImages()
	local imageCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, nil)
	local count = imageCount[0]
	local swapchainImages = VkImageArray(count)
	vulkan.lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, swapchainImages)
	local Image = import("goluwa/render/vulkan/internal/image.lua")
	local out = {}

	for i = 0, count - 1 do
		local ptr = VkImageBox()
		ptr[0] = swapchainImages[i]
		out[i + 1] = Image:CreateObject{
			ptr = ptr,
			device = self.device,
			format = self.format,
			width = self.width,
			height = self.height,
			dont_destroy = true,
			is_swapchain = true,
		}
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

	if result == vulkan.vk.VkResult.VK_ERROR_OUT_OF_DATE_KHR then
		return nil, "out_of_date"
	elseif result == vulkan.vk.VkResult.VK_SUBOPTIMAL_KHR then
		return imageIndex[0], "suboptimal"
	elseif result ~= 0 then
		error("failed to acquire next image: " .. vulkan.vk.str.VkResult(result))
	end

	return imageIndex[0], "ok"
end

function Swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
	local result = vulkan.lib.vkQueuePresentKHR(
		deviceQueue.ptr[0],
		vulkan.vk.s.PresentInfoKHR{
			waitSemaphoreCount = 1,
			pWaitSemaphores = renderFinishedSemaphore.ptr,
			swapchainCount = 1,
			pSwapchains = self.ptr,
			pImageIndices = imageIndex,
		}
	)

	if result == vulkan.vk.VkResult.VK_ERROR_OUT_OF_DATE_KHR then
		return false
	elseif result == vulkan.vk.VkResult.VK_SUBOPTIMAL_KHR then
		return false
	elseif result ~= vulkan.vk.VkResult.VK_SUCCESS then
		error("failed to present: " .. vulkan.vk.str.VkResult(result))
	end

	return true
end

return Swapchain:Register()
