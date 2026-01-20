local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Framebuffer = prototype.CreateTemplate("vulkan_framebuffer")

function Framebuffer.New(config)
	local device = config.device
	local render_pass = config.render_pass
	local image_view = config.image_view
	local width = config.width
	local height = config.height
	local msaa_image_view = config.msaa_image_view
	local depth_image_view = config.depth_image_view
	local attachments
	local attachmentCount

	if msaa_image_view and depth_image_view then
		-- MSAA with depth: MSAA color, resolve target (swapchain), MSAA depth
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(3)
		attachment_array[0] = msaa_image_view.ptr[0]
		attachment_array[1] = image_view.ptr[0]
		attachment_array[2] = depth_image_view.ptr[0]
		attachments = attachment_array
		attachmentCount = 3
	elseif msaa_image_view then
		-- MSAA without depth: MSAA color, resolve target (swapchain)
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(2)
		attachment_array[0] = msaa_image_view.ptr[0]
		attachment_array[1] = image_view.ptr[0]
		attachments = attachment_array
		attachmentCount = 2
	elseif depth_image_view then
		-- Non-MSAA with depth: color + depth
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(2)
		attachment_array[0] = image_view.ptr[0]
		attachment_array[1] = depth_image_view.ptr[0]
		attachments = attachment_array
		attachmentCount = 2
	else
		-- Non-MSAA: single attachment
		local attachment_array = vulkan.T.Array(vulkan.vk.VkImageView)(1)
		attachment_array[0] = image_view.ptr[0]
		attachments = attachment_array
		attachmentCount = 1
	end

	local ptr = vulkan.T.Box(vulkan.vk.VkFramebuffer)()
	vulkan.assert(
		vulkan.lib.vkCreateFramebuffer(
			device.ptr[0],
			vulkan.vk.s.FramebufferCreateInfo(
				{
					renderPass = render_pass.ptr[0],
					attachmentCount = attachmentCount,
					pAttachments = attachments,
					width = width,
					height = height,
					layers = 1,
				}
			),
			nil,
			ptr
		),
		"failed to create framebuffer"
	)
	return Framebuffer:CreateObject(
		{
			ptr = ptr,
			device = device,
			_attachments = attachments, -- Keep attachment array alive
		}
	)
end

function Framebuffer:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroyFramebuffer(self.device.ptr[0], self.ptr[0], nil)
	end
end

return Framebuffer:Register()
