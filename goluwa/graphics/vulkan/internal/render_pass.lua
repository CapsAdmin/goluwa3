local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local RenderPass = {}
RenderPass.__index = RenderPass

function RenderPass.New(device, config)
	config.samples = config.samples or "1"
	config.final_layout = config.final_layout or "present_src_khr"
	-- Normalize format: handle both string and object with .format field
	local format_string = type(config.format) == "string" and config.format or config.format.format
	local attachments
	local attachment_count
	local has_depth = config.depth_format ~= nil

	if config.samples == "1" then
		if has_depth then
			attachment_count = 2
			attachments = vulkan.T.Array(
				vulkan.vk.VkAttachmentDescription,
				2,
				{
					-- Attachment 0: Color
					{
						format = vulkan.enums.VK_FORMAT_(format_string),
						samples = "VK_SAMPLE_COUNT_1_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
						storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = vulkan.enums.VK_IMAGE_LAYOUT_(config.final_layout),
					},
					-- Attachment 1: Depth
					{
						format = vulkan.enums.VK_FORMAT_(config.depth_format),
						samples = "VK_SAMPLE_COUNT_1_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
						storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL",
					},
				}
			)
		else
			attachment_count = 1
			attachments = vulkan.vk.VkAttachmentDescription(
				{
					format = vulkan.enums.VK_FORMAT_(format_string),
					samples = "VK_SAMPLE_COUNT_1_BIT",
					loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
					storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
					stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
					stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
					initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
					finalLayout = vulkan.enums.VK_IMAGE_LAYOUT_(config.final_layout),
				}
			)
		end
	else
		if has_depth then
			attachment_count = 3
			attachments = vulkan.T.Array(
				vulkan.vk.VkAttachmentDescription,
				3,
				{
					-- Attachment 0: MSAA color attachment
					{
						format = vulkan.enums.VK_FORMAT_(format_string),
						samples = "VK_SAMPLE_COUNT_" .. config.samples .. "_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
						storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE", -- Don't need to store MSAA
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
					},
					-- Attachment 1: Resolve target (swapchain)
					{
						format = vulkan.enums.VK_FORMAT_(format_string),
						samples = "VK_SAMPLE_COUNT_1_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE", -- Don't care about initial contents
						storeOp = "VK_ATTACHMENT_STORE_OP_STORE", -- Store resolved result
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR",
					},
					-- Attachment 2: MSAA depth attachment
					{
						format = vulkan.enums.VK_FORMAT_(config.depth_format),
						samples = "VK_SAMPLE_COUNT_" .. config.samples .. "_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
						storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL",
					},
				}
			)
		else
			attachment_count = 2
			attachments = vulkan.T.Array(
				vulkan.vk.VkAttachmentDescription,
				2,
				{
					-- Attachment 0: MSAA color attachment
					{
						format = vulkan.enums.VK_FORMAT_(format_string),
						samples = "VK_SAMPLE_COUNT_" .. config.samples .. "_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
						storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE", -- Don't need to store MSAA
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
					},
					-- Attachment 1: Resolve target (swapchain)
					{
						format = vulkan.enums.VK_FORMAT_(format_string),
						samples = "VK_SAMPLE_COUNT_1_BIT",
						loadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE", -- Don't care about initial contents
						storeOp = "VK_ATTACHMENT_STORE_OP_STORE", -- Store resolved result
						stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
						stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
						initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						finalLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR",
					},
				}
			)
		end
	end

	local colorAttachmentRef = vulkan.vk.VkAttachmentReference({
		attachment = 0,
		layout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
	})
	local depthAttachmentRef = has_depth and
		vulkan.vk.VkAttachmentReference(
			{
				attachment = config.samples == "1" and 1 or 2,
				layout = "VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL",
			}
		) or
		nil
	local subpass = vulkan.vk.VkSubpassDescription(
		{
			pipelineBindPoint = "VK_PIPELINE_BIND_POINT_GRAPHICS",
			colorAttachmentCount = 1,
			pColorAttachments = colorAttachmentRef,
			pResolveAttachments = config.samples ~= "1" and
				vulkan.vk.VkAttachmentReference(
					{
						attachment = 1,
						layout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
					}
				) or
				nil,
			pDepthStencilAttachment = depthAttachmentRef,
		}
	)
	local dependency = vulkan.vk.VkSubpassDependency(
		{
			srcSubpass = vulkan.vk.VK_SUBPASS_EXTERNAL,
			dstSubpass = 0,
			srcStageMask = has_depth and
				bit.bor(
					vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
					vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT")
				) or
				vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
			srcAccessMask = 0,
			dstStageMask = has_depth and
				bit.bor(
					vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
					vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT")
				) or
				vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
			dstAccessMask = has_depth and
				bit.bor(
					vulkan.vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
					vulkan.vk.VkAccessFlagBits("VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT")
				) or
				vulkan.vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
		}
	)
	local renderPassInfo = vulkan.vk.VkRenderPassCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO",
			attachmentCount = attachment_count,
			pAttachments = attachments,
			subpassCount = 1,
			pSubpasses = subpass,
			dependencyCount = 1,
			pDependencies = dependency,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkRenderPass)()
	vulkan.assert(
		vulkan.lib.vkCreateRenderPass(device.ptr[0], renderPassInfo, nil, ptr),
		"failed to create render pass with MSAA"
	)
	return setmetatable(
		{
			ptr = ptr,
			device = device,
			samples = config.samples,
			has_depth = has_depth,
			-- Anchor all temporary FFI structures to prevent premature GC
			_attachments = attachments,
			_colorAttachmentRef = colorAttachmentRef,
			_depthAttachmentRef = depthAttachmentRef,
			_subpass = subpass,
			_dependency = dependency,
			_renderPassInfo = renderPassInfo,
		},
		RenderPass
	)
end

function RenderPass:__gc()
	vulkan.lib.vkDestroyRenderPass(self.device.ptr[0], self.ptr[0], nil)
end

return RenderPass
