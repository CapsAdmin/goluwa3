local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local CommandBuffer = {}
CommandBuffer.__index = CommandBuffer

function CommandBuffer.New(command_pool)
	local info = vulkan.vk.VkCommandBufferAllocateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO",
			commandPool = command_pool.ptr[0],
			level = "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
			commandBufferCount = 1,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkCommandBuffer)()
	vulkan.assert(
		vulkan.lib.vkAllocateCommandBuffers(command_pool.device.ptr[0], info, ptr),
		"failed to allocate command buffer"
	)
	return setmetatable({ptr = ptr}, CommandBuffer)
end

function CommandBuffer:__gc() -- Command buffers are freed when the command pool is destroyed, so nothing to do here
end

function CommandBuffer:Begin()
	local info = vulkan.vk.VkCommandBufferBeginInfo(
		{
			sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO",
			flags = vulkan.vk.VkCommandBufferUsageFlagBits("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT"),
		}
	)
	vulkan.assert(vulkan.lib.vkBeginCommandBuffer(self.ptr[0], info), "failed to begin command buffer")
end

function CommandBuffer:Reset()
	vulkan.lib.vkResetCommandBuffer(self.ptr[0], 0)
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

function CommandBuffer:BeginRenderPass(renderPass, framebuffer, extent, clearColor, clearDepth)
	clearColor = clearColor or {0.0, 0.0, 0.0, 1.0}
	clearDepth = clearDepth or 1.0
	local clearValues
	local clearValueCount

	if renderPass.has_depth then
		-- Render pass has depth attachment, provide 2 clear values
		clearValues = vulkan.T.Array(vulkan.vk.VkClearValue, 2)()
		-- Set color clear value (first attachment)
		clearValues[0].color.float32[0] = clearColor[1]
		clearValues[0].color.float32[1] = clearColor[2]
		clearValues[0].color.float32[2] = clearColor[3]
		clearValues[0].color.float32[3] = clearColor[4]
		-- Set depth/stencil clear value (second attachment)
		clearValues[1].depthStencil.depth = clearDepth
		clearValues[1].depthStencil.stencil = 0
		clearValueCount = 2
	else
		-- No depth attachment, only 1 clear value
		clearValues = vulkan.vk.VkClearValue({
			color = {
				float32 = clearColor,
			},
		})
		clearValueCount = 1
	end

	local renderPassInfo = vulkan.vk.VkRenderPassBeginInfo(
		{
			sType = "VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO",
			renderPass = renderPass.ptr[0],
			framebuffer = framebuffer.ptr[0],
			renderArea = {
				offset = {x = 0, y = 0},
				extent = extent,
			},
			clearValueCount = clearValueCount,
			pClearValues = clearValues,
		}
	)
	vulkan.lib.vkCmdBeginRenderPass(self.ptr[0], renderPassInfo, vulkan.vk.VkSubpassContents("VK_SUBPASS_CONTENTS_INLINE"))
end

function CommandBuffer:EndRenderPass()
	vulkan.lib.vkCmdEndRenderPass(self.ptr[0])
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
	indexType = indexType or "uint32"
	vulkan.lib.vkCmdBindIndexBuffer(self.ptr[0], buffer.ptr[0], offset, vulkan.enums.VK_INDEX_TYPE_(indexType))
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
	local viewport = vulkan.vk.VkViewport(
		{
			x = x or 0.0,
			y = y or 0.0,
			width = width,
			height = height,
			minDepth = minDepth or 0.0,
			maxDepth = maxDepth or 1.0,
		}
	)
	vulkan.lib.vkCmdSetViewport(self.ptr[0], 0, 1, viewport)
end

function CommandBuffer:SetScissor(x, y, width, height)
	local scissor = vulkan.vk.VkRect2D(
		{
			offset = {x = x or 0, y = y or 0},
			extent = {width = width, height = height},
		}
	)
	vulkan.lib.vkCmdSetScissor(self.ptr[0], 0, 1, scissor)
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
	-- blend_equation should be a table with blend factors and ops
	local equation = vulkan.vk.VkColorBlendEquationEXT(
		{
			srcColorBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.src_color_blend_factor),
			dstColorBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.dst_color_blend_factor),
			colorBlendOp = vulkan.enums.VK_BLEND_OP_(blend_equation.color_blend_op),
			srcAlphaBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.src_alpha_blend_factor),
			dstAlphaBlendFactor = vulkan.enums.VK_BLEND_FACTOR_(blend_equation.dst_alpha_blend_factor),
			alphaBlendOp = vulkan.enums.VK_BLEND_OP_(blend_equation.alpha_blend_op),
		}
	)
	vulkan.ext.vkCmdSetColorBlendEquationEXT(self.ptr[0], first_attachment or 0, 1, equation)
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
	local range = vulkan.vk.VkImageSubresourceRange(
		{
			aspectMask = vulkan.enums.VK_IMAGE_ASPECT_(config.aspect_mask or "color"),
			baseMipLevel = config.base_mip_level or 0,
			levelCount = config.level_count or 1,
			baseArrayLayer = config.base_array_layer or 0,
			layerCount = config.layer_count or 1,
		}
	)
	vulkan.lib.vkCmdClearColorImage(
		self.ptr[0],
		config.image,
		"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
		vulkan.vk.VkClearColorValue({
			float32 = config.color or {0.0, 0.0, 0.0, 1.0},
		}),
		1,
		range
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
		all_commands = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_ALL_COMMANDS_BIT"),
		top_of_pipe = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT"),
		color_attachment_output = vulkan.vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
	}
	local srcStage = stage_map[config.srcStage or "compute"]
	local dstStage = stage_map[config.dstStage or "fragment"]
	local imageBarriers = nil
	local imageBarrierCount = 0

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
						baseMipLevel = 0,
						levelCount = 1,
						baseArrayLayer = 0,
						layerCount = 1,
					},
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
		0,
		nil,
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

return CommandBuffer
