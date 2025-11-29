local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ffi_helpers = require("helpers.ffi_helpers")
local e = ffi_helpers.translate_enums(
	{
		{vulkan.vk.VkImageViewType, "VK_IMAGE_VIEW_TYPE_"},
		{vulkan.vk.VkFormat, "VK_FORMAT_"},
		{vulkan.vk.VkImageAspectFlagBits, "VK_IMAGE_ASPECT_", "_BIT"},
		{vulkan.vk.VkComponentSwizzle, "VK_COMPONENT_SWIZZLE_"},
		{vulkan.vk.VkImageViewCreateFlagBits, "VK_IMAGE_VIEW_CREATE_", "_BIT"},
	}
)
local ImageView = {}
ImageView.__index = ImageView

function ImageView.New(config)
	config = config or {}
	assert(config.device)
	assert(config.image)
	assert(config.format)
	local ptr = vulkan.T.Box(vulkan.vk.VkImageView)()
	vulkan.assert(
		vulkan.lib.vkCreateImageView(
			config.device.ptr[0],
			vulkan.vk.VkImageViewCreateInfo(
				{
					sType = "VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO",
					flags = config.flags and e.VK_IMAGE_VIEW_CREATE_(config.flags) or 0,
					image = config.image.ptr[0],
					viewType = e.VK_IMAGE_VIEW_TYPE_(config.view_type or "2d"),
					format = e.VK_FORMAT_(config.format),
					components = {
						r = e.VK_COMPONENT_SWIZZLE_(config.component_r or "identity"),
						g = e.VK_COMPONENT_SWIZZLE_(config.component_g or "identity"),
						b = e.VK_COMPONENT_SWIZZLE_(config.component_b or "identity"),
						a = e.VK_COMPONENT_SWIZZLE_(config.component_a or "identity"),
					},
					subresourceRange = {
						aspectMask = e.VK_IMAGE_ASPECT_(config.aspect or "color"),
						baseMipLevel = config.base_mip_level or 0,
						levelCount = config.level_count or 1,
						baseArrayLayer = config.base_array_layer or 0,
						layerCount = config.layer_count or 1,
					},
				}
			),
			nil,
			ptr
		),
		"failed to create image view"
	)
	return setmetatable({
		ptr = ptr,
		device = config.device,
	}, ImageView)
end

function ImageView:__gc()
	vulkan.lib.vkDestroyImageView(self.device.ptr[0], self.ptr[0], nil)
end

return ImageView
