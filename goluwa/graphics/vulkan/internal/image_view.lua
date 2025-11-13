local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ImageView = {}
ImageView.__index = ImageView

function ImageView.New(device, image, format_or_config)
	local config

	if type(format_or_config) == "string" then
		-- Backwards compatibility: simple (image, format) call
		config = {format = format_or_config}
	else
		-- New style: (image, config_table)
		config = format_or_config or {}
	end

	local viewInfo = vulkan.vk.VkImageViewCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO",
			image = image.ptr[0],
			viewType = vulkan.enums.VK_IMAGE_VIEW_TYPE_(config.view_type or "2d"),
			format = vulkan.enums.VK_FORMAT_(config.format),
			subresourceRange = {
				aspectMask = vulkan.enums.VK_IMAGE_ASPECT_(config.aspect or "color"),
				baseMipLevel = config.base_mip_level or 0,
				levelCount = config.level_count or 1,
				baseArrayLayer = config.base_array_layer or 0,
				layerCount = config.layer_count or 1,
			},
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkImageView)()
	vulkan.assert(
		vulkan.lib.vkCreateImageView(device.ptr[0], viewInfo, nil, ptr),
		"failed to create image view"
	)
	return setmetatable({ptr = ptr, device = device}, ImageView)
end

function ImageView:__gc()
	vulkan.lib.vkDestroyImageView(self.device.ptr[0], self.ptr[0], nil)
end

return ImageView
