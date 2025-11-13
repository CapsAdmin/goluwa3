local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Framebuffer = {}
Framebuffer.__index = Framebuffer

function Framebuffer.New(device, renderPass, imageView, width, height, msaaImageView, depthImageView)
	local attachments
	local attachmentCount

	if msaaImageView then
		-- MSAA: first attachment is MSAA color, second is resolve target (swapchain)
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(2)
		attachment_array[0] = msaaImageView.ptr[0]
		attachment_array[1] = imageView.ptr[0]
		attachments = attachment_array
		attachmentCount = 2
	elseif depthImageView then
		-- Non-MSAA with depth: color + depth
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(2)
		attachment_array[0] = imageView.ptr[0]
		attachment_array[1] = depthImageView.ptr[0]
		attachments = attachment_array
		attachmentCount = 2
	else
		-- Non-MSAA: single attachment
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(1)
		attachment_array[0] = imageView.ptr[0]
		attachments = attachment_array
		attachmentCount = 1
	end

	local framebufferInfo = vulkan.vk.VkFramebufferCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO",
			renderPass = renderPass.ptr[0],
			attachmentCount = attachmentCount,
			pAttachments = attachments,
			width = width,
			height = height,
			layers = 1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkFramebuffer)()
	vulkan.assert(
		vulkan.lib.vkCreateFramebuffer(device.ptr[0], framebufferInfo, nil, ptr),
		"failed to create framebuffer"
	)
	return setmetatable(
		{
			ptr = ptr,
			device = device,
			_attachments = attachments, -- Keep attachment array alive
		},
		Framebuffer
	)
end

function Framebuffer:__gc()
	vulkan.lib.vkDestroyFramebuffer(self.device.ptr[0], self.ptr[0], nil)
end

return Framebuffer
