local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local ImageView = prototype.CreateTemplate("vulkan", "image_view")

function ImageView.New(config)
	config = config or {}
	assert(config.device)
	assert(config.image)
	assert(config.format)
	local ptr = vulkan.T.Box(vulkan.vk.VkImageView)()
	vulkan.assert(
		vulkan.lib.vkCreateImageView(
			config.device.ptr[0],
			vulkan.vk.s.ImageViewCreateInfo(
				{
					flags = config.flags,
					image = config.image.ptr[0],
					viewType = config.view_type or "2d",
					format = config.format,
					components = {
						r = config.component_r or "identity",
						g = config.component_g or "identity",
						b = config.component_b or "identity",
						a = config.component_a or "identity",
					},
					subresourceRange = {
						aspectMask = config.aspect or "color",
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
	return ImageView:CreateObject({
		ptr = ptr,
		device = config.device,
	})
end

function ImageView:OnRemove()
	vulkan.lib.vkDestroyImageView(self.device.ptr[0], self.ptr[0], nil)
end

return ImageView:Register()
