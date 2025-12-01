local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local ffi_helpers = require("helpers.ffi_helpers")
local e = ffi_helpers.translate_enums({
	{vulkan.vk.VkImageLayout, "VK_IMAGE_LAYOUT_"},
})
local CommandBuffer = {}
CommandBuffer.__index = CommandBuffer

function CommandBuffer.New(command_pool)
	local ptr = vulkan.T.Box(vulkan.vk.VkCommandBuffer)()
	vulkan.assert(
		vulkan.lib.vkAllocateCommandBuffers(
			command_pool.device.ptr[0],
			vulkan.vk.VkCommandBufferAllocateInfo(
				{
					sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO",
					commandPool = command_pool.ptr[0],
					level = "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
					commandBufferCount = 1,
				}
			),
			ptr
		),
		"failed to allocate command buffer"
	)
	return setmetatable({ptr = ptr}, CommandBuffer)
end

function CommandBuffer:__gc() -- Command buffers are freed when the command pool is destroyed, so nothing to do here
end

function CommandBuffer:Begin()
	vulkan.assert(
		vulkan.lib.vkBeginCommandBuffer(
			self.ptr[0],
			vulkan.vk.VkCommandBufferBeginInfo(
				{
					sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO",
					flags = vulkan.vk.VkCommandBufferUsageFlagBits("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT"),
				}
			)
		),
		"failed to begin command buffer"
	)
end

function CommandBuffer:Reset()
	vulkan.lib.vkResetCommandBuffer(self.ptr[0], 0)
end

function CommandBuffer:UpdateBuffer(buffer, offset, size, data)
	vulkan.lib.vkCmdUpdateBuffer(self.ptr[0], buffer.ptr[0], offset, size, data)
end

function CommandBuffer:CreateImageMemoryBarrier(imageIndex, swapchainImages, isFirstFrame)
	-- For first frame, transition from UNDEFINED
	-- For subsequent frames, transition from PRESENT_SRC_KHR (what the render pass leaves it in)
	local oldLayout = isFirstFrame and "VK_IMAGE_LAYOUT_UNDEFINED" or "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
	local barrier = vulkan.vk.VkImageMemoryBarrier(
		{
			sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
			oldLayout = oldLayout,
			newLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
			srcQueueFamilyIndex = 0xFFFFFFFF,
			dstQueueFamilyIndex = 0xFFFFFFFF,
			image = swapchainImages[imageIndex],
			subresourceRange = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcAccessMask = 0,
			dstAccessMask = vulkan.vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
		}
	)
	return barrier
end

function CommandBuffer:StartPipelineBarrier(barrier)
	vulkan.lib.vkCmdPipelineBarrier(
		self.ptr[0],
		vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT"),
		vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
		0,
		0,
		nil,
		0,
		nil,
		1,
		barrier
	)
end

function CommandBuffer:EndPipelineBarrier(barrier)
	barrier[0].oldLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL"
	barrier[0].newLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
	barrier[0].srcAccessMask = vulkan.vk.VkAccessFlagBits("VK_ACCESS_TRANSFER_WRITE_BIT")
	barrier[0].dstAccessMask = 0
	vulkan.lib.vkCmdPipelineBarrier(
		self.ptr[0],
		vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
		vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT"),
		0,
		0,
		nil,
		0,
		nil,
		1,
		barrier
	)
end

function CommandBuffer:End()
	vulkan.assert(vulkan.lib.vkEndCommandBuffer(self.ptr[0]), "failed to end command buffer")
end

function CommandBuffer:BeginRendering(config)
	local colorAttachmentInfo = nil
	local colorAttachmentCount = 0

	-- Only create color attachment if colorImageView is provided
	if config.color_image_view then
		colorAttachmentCount = 1
		colorAttachmentInfo = vulkan.vk.VkRenderingAttachmentInfo(
			{
				sType = "VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO",
				pNext = nil,
				imageView = config.color_image_view.ptr[0],
				imageLayout = e.VK_IMAGE_LAYOUT_("color_attachment_optimal"),
				resolveMode = config.msaa_image_view and
					"VK_RESOLVE_MODE_AVERAGE_BIT" or
					"VK_RESOLVE_MODE_NONE",
				resolveImageView = config.msaa_image_view and config.color_image_view.ptr[0] or nil,
				resolveImageLayout = e.VK_IMAGE_LAYOUT_(config.msaa_image_view and "color_attachment_optimal" or "undefined"),
				loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
				storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
				clearValue = {
					color = {
						float32 = {
							config.clear_color[1],
							config.clear_color[2],
							config.clear_color[3],
							config.clear_color[4],
						},
					},
				},
			}
		)

		if config.msaa_image_view then
			colorAttachmentInfo.imageView = config.msaa_image_view.ptr[0]
			colorAttachmentInfo.imageLayout = e.VK_IMAGE_LAYOUT_("COLOR_ATTACHMENT_OPTIMAL")
			colorAttachmentInfo.resolveMode = "VK_RESOLVE_MODE_AVERAGE_BIT"
			colorAttachmentInfo.resolveImageView = config.color_image_view.ptr[0]
			colorAttachmentInfo.resolveImageLayout = e.VK_IMAGE_LAYOUT_("COLOR_ATTACHMENT_OPTIMAL")
		end
	end

	local depthAttachmentInfo = nil

	if config.depth_image_view then
		depthAttachmentInfo = vulkan.vk.VkRenderingAttachmentInfo(
			{
				sType = "VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO",
				pNext = nil,
				imageView = config.depth_image_view.ptr[0],
				imageLayout = e.VK_IMAGE_LAYOUT_(config.depth_layout or "DEPTH_ATTACHMENT_OPTIMAL"),
				resolveMode = "VK_RESOLVE_MODE_NONE",
				resolveImageView = nil,
				resolveImageLayout = e.VK_IMAGE_LAYOUT_("UNDEFINED"),
				loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
				storeOp = config.depth_store and
					"VK_ATTACHMENT_STORE_OP_STORE" or
					"VK_ATTACHMENT_STORE_OP_DONT_CARE",
				clearValue = {
					depthStencil = {
						depth = config.clear_depth or 1.0,
						stencil = 0,
					},
				},
			}
		)
	end

	vulkan.lib.vkCmdBeginRendering(
		self.ptr[0],
		vulkan.vk.VkRenderingInfo(
			{
				sType = "VK_STRUCTURE_TYPE_RENDERING_INFO",
				pNext = nil,
				flags = 0,
				renderArea = {
					offset = {x = config.x or 0, y = config.y or 0},
					extent = {width = config.w, height = config.h},
				},
				layerCount = 1,
				viewMask = 0,
				colorAttachmentCount = colorAttachmentCount,
				pColorAttachments = colorAttachmentInfo,
				pDepthAttachment = depthAttachmentInfo,
				pStencilAttachment = nil,
			}
		)
	)
end

function CommandBuffer:EndRendering()
	vulkan.lib.vkCmdEndRendering(self.ptr[0])
end

function CommandBuffer:BindPipeline(pipeline, type)
	vulkan.lib.vkCmdBindPipeline(self.ptr[0], vulkan.enums.VK_PIPELINE_BIND_POINT_(type), pipeline.ptr[0])
end

function CommandBuffer:BindVertexBuffers(firstBinding, buffers, offsets)
	-- buffers is an array of Buffer objects
	-- offsets is optional array of offsets
	local bufferCount = #buffers
	local bufferArray = vulkan.T.Array(vulkan.vk.VkBuffer)(bufferCount)
	local offsetArray = vulkan.T.Array(vulkan.vk.VkDeviceSize)(bufferCount)

	for i, buffer in ipairs(buffers) do
		bufferArray[i - 1] = buffer.ptr[0]
		offsetArray[i - 1] = offsets and offsets[i] or 0
	end

	vulkan.lib.vkCmdBindVertexBuffers(self.ptr[0], firstBinding or 0, bufferCount, bufferArray, offsetArray)
end

function CommandBuffer:BindVertexBuffer(buffer, binding, offset)
	self:BindVertexBuffers(binding, {buffer}, offset and {offset} or nil)
end

function CommandBuffer:BindDescriptorSets(type, pipelineLayout, descriptorSets, firstSet)
	-- descriptorSets is an array of descriptor set objects
	local setCount = #descriptorSets
	local setArray = vulkan.T.Array(vulkan.vk.VkDescriptorSet)(setCount)

	for i, ds in ipairs(descriptorSets) do
		setArray[i - 1] = ds.ptr[0]
	end

	vulkan.lib.vkCmdBindDescriptorSets(
		self.ptr[0],
		vulkan.enums.VK_PIPELINE_BIND_POINT_(type),
		pipelineLayout.ptr[0],
		firstSet or 0,
		setCount,
		setArray,
		0,
		nil
	)
end

function CommandBuffer:Draw(vertexCount, instanceCount, firstVertex, firstInstance)
	vulkan.lib.vkCmdDraw(
		self.ptr[0],
		vertexCount or 3,
		instanceCount or 1,
		firstVertex or 0,
		firstInstance or 0
	)
end

function CommandBuffer:BindIndexBuffer(buffer, offset, indexType)
	if indexType == "uint16_t" then indexType = "uint16" end

	vulkan.lib.vkCmdBindIndexBuffer(self.ptr[0], buffer.ptr[0], offset, vulkan.enums.VK_INDEX_TYPE_(indexType or "uint32"))
end

function CommandBuffer:DrawIndexed(indexCount, instanceCount, firstIndex, vertexOffset, firstInstance)
	vulkan.lib.vkCmdDrawIndexed(
		self.ptr[0],
		indexCount,
		instanceCount or 1,
		firstIndex or 0,
		vertexOffset or 0,
		firstInstance or 0
	)
end

function CommandBuffer:SetViewport(x, y, width, height, minDepth, maxDepth)
	assert(width > 0)
	assert(height > 0)
	vulkan.lib.vkCmdSetViewport(
		self.ptr[0],
		0,
		1,
		vulkan.vk.VkViewport(
			{
				x = x or 0.0,
				y = y or 0.0,
				width = width,
				height = height,
				minDepth = minDepth or 0.0,
				maxDepth = maxDepth or 1.0,
			}
		)
	)
end

function CommandBuffer:SetScissor(x, y, width, height)
	assert(width > 0)
	assert(height > 0)
	vulkan.lib.vkCmdSetScissor(
		self.ptr[0],
		0,
		1,
		vulkan.vk.VkRect2D(
			{
				offset = {x = x or 0, y = y or 0},
				extent = {width = width, height = height},
			}
		)
	)
end

function CommandBuffer:SetBlendConstants(r, g, b, a)
	local constants = ffi.new("float[4]", {r or 0.0, g or 0.0, b or 0.0, a or 0.0})
	vulkan.lib.vkCmdSetBlendConstants(self.ptr[0], constants)
end

function CommandBuffer:SetColorBlendEnable(first_attachment, blend_enable)
	-- blend_enable should be a boolean (for single attachment) or table of booleans (for multiple)
	local enable_array
	local count

	if type(blend_enable) == "boolean" then
		-- Single attachment
		enable_array = ffi.new("uint32_t[1]", {blend_enable and 1 or 0})
		count = 1
	elseif type(blend_enable) == "table" then
		-- Multiple attachments
		count = #blend_enable
		enable_array = ffi.new("uint32_t[?]", count)

		for i = 1, count do
			enable_array[i - 1] = blend_enable[i] and 1 or 0
		end
	else
		error("blend_enable must be a boolean or table of booleans")
	end

	vulkan.ext.vkCmdSetColorBlendEnableEXT(self.ptr[0], first_attachment or 0, count, enable_array)
end

function CommandBuffer:SetColorBlendEquation(first_attachment, blend_equation)
	vulkan.ext.vkCmdSetColorBlendEquationEXT(
		self.ptr[0],
		first_attachment or 0,
		1,
		vulkan.vk.VkColorBlendEquationEXT(
			{
				srcColorBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.src_color_blend_factor),
				dstColorBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.dst_color_blend_factor),
				colorBlendOp = vulkan.enums.VK_BLEND_OP_(blend_equation.color_blend_op),
				srcAlphaBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.src_alpha_blend_factor),
				dstAlphaBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.dst_alpha_blend_factor),
				alphaBlendOp = vulkan.enums.VK_BLEND_OP_(blend_equation.alpha_blend_op),
			}
		)
	)
end

function CommandBuffer:PushConstants(layout, stage, binding, data_size, data)
	vulkan.lib.vkCmdPushConstants(
		self.ptr[0],
		layout.ptr[0],
		vulkan.enums.VK_SHADER_STAGE_(stage),
		binding,
		data_size,
		data
	)
end

function CommandBuffer:ClearColorImage(config)
	vulkan.lib.vkCmdClearColorImage(
		self.ptr[0],
		config.image,
		"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
		vulkan.vk.VkClearColorValue({
			float32 = config.color or {0.0, 0.0, 0.0, 1.0},
		}),
		1,
		vulkan.vk.VkImageSubresourceRange(
			{
				aspectMask = vulkan.enums.VK_IMAGE_ASPECT_(config.aspect_mask or "color"),
				baseMipLevel = config.base_mip_level or 0,
				levelCount = config.level_count or 1,
				baseArrayLayer = config.base_array_layer or 0,
				layerCount = config.layer_count or 1,
			}
		)
	)
end

function CommandBuffer:Dispatch(groupCountX, groupCountY, groupCountZ)
	vulkan.lib.vkCmdDispatch(self.ptr[0], groupCountX or 1, groupCountY or 1, groupCountZ or 1)
end

function CommandBuffer:PipelineBarrier(config)
	-- Map stage names to pipeline stage flags
	local stage_map = {
		compute = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT"),
		fragment = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT"),
		transfer = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
		vertex = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_VERTEX_SHADER_BIT"),
		vertex_input = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_VERTEX_INPUT_BIT"),
		all_commands = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_ALL_COMMANDS_BIT"),
		top_of_pipe = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT"),
		color_attachment_output = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
	}
	local srcStage = stage_map[config.srcStage or "compute"]
	local dstStage = stage_map[config.dstStage or "fragment"]
	local imageBarriers = nil
	local imageBarrierCount = 0
	local bufferBarriers = nil
	local bufferBarrierCount = 0

	if config.imageBarriers then
		imageBarrierCount = #config.imageBarriers
		imageBarriers = vulkan.T.Array(vulkan.vk.VkImageMemoryBarrier)(imageBarrierCount)

		for i, barrier in ipairs(config.imageBarriers) do
			imageBarriers[i - 1] = vulkan.vk.VkImageMemoryBarrier(
				{
					sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
					srcAccessMask = vulkan.enums.VK_ACCESS_(barrier.srcAccessMask or "none"),
					dstAccessMask = vulkan.enums.VK_ACCESS_(barrier.dstAccessMask or "none"),
					oldLayout = vulkan.enums.VK_IMAGE_LAYOUT_(barrier.oldLayout or "undefined"),
					newLayout = vulkan.enums.VK_IMAGE_LAYOUT_(barrier.newLayout or "general"),
					srcQueueFamilyIndex = 0xFFFFFFFF,
					dstQueueFamilyIndex = 0xFFFFFFFF,
					image = barrier.image.ptr[0],
					subresourceRange = {
						aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
						baseMipLevel = barrier.base_mip_level or 0,
						levelCount = barrier.level_count or
							(
								barrier.image.GetMipLevels and
								barrier.image:GetMipLevels() or
								1
							),
						baseArrayLayer = 0,
						layerCount = 1,
					},
				}
			)
		end
	end

	if config.bufferBarriers then
		bufferBarrierCount = #config.bufferBarriers
		bufferBarriers = vulkan.T.Array(vulkan.vk.VkBufferMemoryBarrier)(bufferBarrierCount)

		for i, barrier in ipairs(config.bufferBarriers) do
			bufferBarriers[i - 1] = vulkan.vk.VkBufferMemoryBarrier(
				{
					sType = "VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER",
					srcAccessMask = vulkan.enums.VK_ACCESS_(barrier.srcAccessMask or "host_write"),
					dstAccessMask = vulkan.enums.VK_ACCESS_(barrier.dstAccessMask or "vertex_attribute_read"),
					srcQueueFamilyIndex = 0xFFFFFFFF,
					dstQueueFamilyIndex = 0xFFFFFFFF,
					buffer = barrier.buffer.ptr[0],
					offset = barrier.offset or 0,
					size = barrier.size or 0xFFFFFFFFFFFFFFFF,
				}
			)
		end
	end

	vulkan.lib.vkCmdPipelineBarrier(
		self.ptr[0],
		srcStage,
		dstStage,
		0,
		0,
		nil,
		bufferBarrierCount,
		bufferBarriers,
		imageBarrierCount,
		imageBarriers
	)
end

function CommandBuffer:CopyImageToImage(srcImage, dstImage, width, height)
	local region = vulkan.vk.VkImageCopy(
		{
			srcSubresource = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcOffset = {x = 0, y = 0, z = 0},
			dstSubresource = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			dstOffset = {x = 0, y = 0, z = 0},
			extent = {width = width, height = height, depth = 1},
		}
	)
	vulkan.lib.vkCmdCopyImage(
		self.ptr[0],
		srcImage,
		"VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL",
		dstImage,
		"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
		1,
		region
	)
end

function CommandBuffer:CopyBufferToImage(buffer, image, width, height)
	local region = vulkan.vk.VkBufferImageCopy(
		{
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			imageOffset = {x = 0, y = 0, z = 0},
			imageExtent = {width = width, height = height, depth = 1},
		}
	)
	vulkan.lib.vkCmdCopyBufferToImage(
		self.ptr[0],
		buffer.ptr[0],
		image.ptr[0],
		"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
		1,
		region
	)
end

function CommandBuffer:BlitImage(config)
	local region = vulkan.vk.VkImageBlit(
		{
			srcSubresource = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				mipLevel = config.src_mip_level or 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcOffsets = {
				{x = 0, y = 0, z = 0},
				{x = config.src_width, y = config.src_height, z = 1},
			},
			dstSubresource = {
				aspectMask = vulkan.vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
				mipLevel = config.dst_mip_level or 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			dstOffsets = {
				{x = 0, y = 0, z = 0},
				{x = config.dst_width, y = config.dst_height, z = 1},
			},
		}
	)
	vulkan.lib.vkCmdBlitImage(
		self.ptr[0],
		config.src_image.ptr[0],
		vulkan.enums.VK_IMAGE_LAYOUT_(config.src_layout or "transfer_src_optimal"),
		config.dst_image.ptr[0],
		vulkan.enums.VK_IMAGE_LAYOUT_(config.dst_layout or "transfer_dst_optimal"),
		1,
		region,
		vulkan.enums.VK_FILTER_(config.filter or "linear")
	)
end

return CommandBuffer
