local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local CommandBuffer = prototype.CreateTemplate("vulkan", "command_buffer")

function CommandBuffer.New(command_pool)
	local ptr = vulkan.T.Box(vulkan.vk.VkCommandBuffer)()
	vulkan.assert(
		vulkan.lib.vkAllocateCommandBuffers(
			command_pool.device.ptr[0],
			vulkan.vk.s.CommandBufferAllocateInfo(
				{
					commandPool = command_pool.ptr[0],
					level = "primary",
					commandBufferCount = 1,
				}
			),
			ptr
		),
		"failed to allocate command buffer"
	)
	return CommandBuffer:CreateObject({ptr = ptr, command_pool = command_pool})
end

function CommandBuffer:__gc()
	self.command_pool:FreeCommandBuffer(self)
end

function CommandBuffer:Begin()
	vulkan.assert(
		vulkan.lib.vkBeginCommandBuffer(self.ptr[0], vulkan.vk.s.CommandBufferBeginInfo({
			flags = "one_time_submit",
		})),
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
	local oldLayout = isFirstFrame and "undefined" or "present_src_khr"
	local barrier = vulkan.vk.s.ImageMemoryBarrierInfo(
		{
			oldLayout = oldLayout,
			newLayout = "color_attachment_optimal",
			srcQueueFamilyIndex = 0xFFFFFFFF,
			dstQueueFamilyIndex = 0xFFFFFFFF,
			image = swapchainImages[imageIndex],
			subresourceRange = {
				aspectMask = "color",
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcAccessMask = "none",
			dstAccessMask = "color_attachment_write",
		}
	)
	return barrier
end

function CommandBuffer:StartPipelineBarrier(barrier)
	vulkan.lib.vkCmdPipelineBarrier(
		self.ptr[0],
		vulkan.vk.e.VkPipelineStageFlagBits("top_of_pipe"),
		vulkan.vk.e.VkPipelineStageFlagBits("transfer"),
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
	barrier[0].oldLayout = vulkan.vk.e.VkImageLayout("transfer_dst_optimal")
	barrier[0].newLayout = vulkan.vk.e.VkImageLayout("present_src_khr")
	barrier[0].srcAccessMask = vulkan.vk.e.VkAccessFlagBits("transfer_write")
	barrier[0].dstAccessMask = 0
	vulkan.lib.vkCmdPipelineBarrier(
		self.ptr[0],
		vulkan.vk.e.VkPipelineStageFlagBits("transfer"),
		vulkan.vk.e.VkPipelineStageFlagBits("bottom_of_pipe"),
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

local RECT = vulkan.vk.VkRect2D()

function CommandBuffer:BeginRendering(config)
	local colorAttachmentInfo = nil
	local colorAttachmentCount = 0

	if config.color_attachments then
		colorAttachmentCount = #config.color_attachments
		colorAttachmentInfo = vulkan.T.Array(vulkan.vk.VkRenderingAttachmentInfo)(colorAttachmentCount)

		for i = 1, colorAttachmentCount do
			local attachment = config.color_attachments[i]
			local imageView = attachment.color_image_view.ptr[0]
			local resolveImageView = nil
			local resolveMode = "none"
			local resolveImageLayout = "undefined"

			if attachment.msaa_image_view then
				imageView = attachment.msaa_image_view.ptr[0]
				resolveImageView = attachment.color_image_view.ptr[0]
				resolveMode = "average"
				resolveImageLayout = "color_attachment_optimal"
			end

			local clearValue = vulkan.vk.VkClearValue()
			local clear_color = attachment.clear_color or {0, 0, 0, 1}
			clearValue.color.float32[0] = clear_color[1]
			clearValue.color.float32[1] = clear_color[2]
			clearValue.color.float32[2] = clear_color[3]
			clearValue.color.float32[3] = clear_color[4]
			colorAttachmentInfo[i - 1] = vulkan.vk.s.RenderingAttachmentInfo(
				{
					imageView = imageView,
					imageLayout = "color_attachment_optimal",
					resolveMode = resolveMode,
					resolveImageView = resolveImageView,
					resolveImageLayout = resolveImageLayout,
					loadOp = attachment.load_op or "clear",
					storeOp = attachment.store_op or "store",
					clearValue = clearValue,
				}
			)
		end
	elseif config.color_image_view then
		colorAttachmentCount = 1
		local imageView = config.color_image_view.ptr[0]
		local resolveImageView = nil
		local resolveMode = "none"
		local resolveImageLayout = "undefined"

		if config.msaa_image_view then
			imageView = config.msaa_image_view.ptr[0]
			resolveImageView = config.color_image_view.ptr[0]
			resolveMode = "average"
			resolveImageLayout = "color_attachment_optimal"
		end

		local clearValue = vulkan.vk.VkClearValue()
		local clear_color = config.clear_color or {0, 0, 0, 1}
		clearValue.color.float32[0] = clear_color[1]
		clearValue.color.float32[1] = clear_color[2]
		clearValue.color.float32[2] = clear_color[3]
		clearValue.color.float32[3] = clear_color[4]
		colorAttachmentInfo = vulkan.vk.s.RenderingAttachmentInfo(
			{
				imageView = imageView,
				imageLayout = "color_attachment_optimal",
				resolveMode = resolveMode,
				resolveImageView = resolveImageView,
				resolveImageLayout = resolveImageLayout,
				loadOp = config.load_op or "clear",
				storeOp = config.store_op or "store",
				clearValue = clearValue,
			}
		)
	end

	local depthAttachmentInfo = nil

	if config.depth_image_view then
		local clearValue = vulkan.vk.VkClearValue()
		clearValue.depthStencil.depth = config.clear_depth or 1.0
		clearValue.depthStencil.stencil = 0
		depthAttachmentInfo = vulkan.vk.s.RenderingAttachmentInfo(
			{
				imageView = config.depth_image_view.ptr[0],
				imageLayout = config.depth_layout or "depth_attachment_optimal",
				resolveMode = "none",
				resolveImageLayout = "undefined",
				loadOp = config.load_op or "clear",
				storeOp = config.depth_store and "store" or "dont_care",
				clearValue = clearValue,
			}
		)
	end

	RECT.offset.x = config.x or 0
	RECT.offset.y = config.y or 0
	RECT.extent.width = config.w
	RECT.extent.height = config.h
	vulkan.lib.vkCmdBeginRendering(
		self.ptr[0],
		vulkan.vk.s.RenderingInfo(
			{
				renderArea = RECT,
				viewMask = 0,
				layerCount = 1,
				colorAttachmentCount = colorAttachmentCount,
				pColorAttachments = colorAttachmentInfo,
				pDepthAttachment = depthAttachmentInfo,
			}
		)
	)
	self.is_rendering = true
end

function CommandBuffer:EndRendering()
	if not self.is_rendering then return end

	vulkan.lib.vkCmdEndRendering(self.ptr[0])
	self.is_rendering = false
end

function CommandBuffer:BindPipeline(pipeline, type)
	vulkan.lib.vkCmdBindPipeline(self.ptr[0], vulkan.vk.e.VkPipelineBindPoint(type), pipeline.ptr[0])
end

function CommandBuffer:BindVertexBuffers(firstBinding, buffers, offsets)
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
	local setCount = #descriptorSets
	local setArray = vulkan.T.Array(vulkan.vk.VkDescriptorSet)(setCount)

	for i, ds in ipairs(descriptorSets) do
		setArray[i - 1] = ds.ptr[0]
	end

	vulkan.lib.vkCmdBindDescriptorSets(
		self.ptr[0],
		vulkan.vk.e.VkPipelineBindPoint(type),
		pipelineLayout.ptr[0],
		firstSet or 0,
		setCount,
		setArray,
		0,
		nil
	)
end

function CommandBuffer:Draw(vertexCount, instanceCount, firstVertex, firstInstance)
	vulkan.lib.vkCmdDraw(self.ptr[0], vertexCount or 3, instanceCount or 1, firstVertex or 0, firstInstance or 0)
end

function CommandBuffer:BindIndexBuffer(buffer, offset, indexType)
	if indexType == "uint16_t" then indexType = "uint16" end

	vulkan.lib.vkCmdBindIndexBuffer(self.ptr[0], buffer.ptr[0], offset, vulkan.vk.e.VkIndexType(indexType or "uint32"))
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
				offset = vulkan.vk.VkOffset2D({x = x or 0, y = y or 0}),
				extent = vulkan.vk.VkExtent2D({width = width, height = height}),
			}
		)
	)
end

function CommandBuffer:SetBlendConstants(r, g, b, a)
	local constants = ffi.new("float[4]", r or 0.0, g or 0.0, b or 0.0, a or 0.0)
	vulkan.lib.vkCmdSetBlendConstants(self.ptr[0], constants)
end

function CommandBuffer:SetColorBlendEnable(first_attachment, blend_enable)
	local enable_array
	local count

	if type(blend_enable) == "boolean" then
		enable_array = ffi.new("uint32_t[1]", blend_enable and 1 or 0)
		count = 1
	elseif type(blend_enable) == "table" then
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

function CommandBuffer:BeginConditionalRendering(buffer, offset, inverted)
	if not buffer then return end

	local flags = inverted and
		vulkan.vk.VkConditionalRenderingFlagBitsEXT.VK_CONDITIONAL_RENDERING_INVERTED_BIT_EXT or
		0
	local conditional_rendering_begin = vulkan.vk.s.ConditionalRenderingBeginInfoEXT({
		buffer = buffer.ptr[0],
		offset = offset or 0,
		flags = flags,
	})
	vulkan.ext.vkCmdBeginConditionalRenderingEXT(self.ptr[0], conditional_rendering_begin)
end

function CommandBuffer:EndConditionalRendering()
	vulkan.ext.vkCmdEndConditionalRenderingEXT(self.ptr[0])
end

function CommandBuffer:CopyQueryPoolResults(query_pool, first_query, query_count, dst_buffer, dst_offset, stride, flags)
	vulkan.lib.vkCmdCopyQueryPoolResults(
		self.ptr[0],
		query_pool.ptr[0],
		first_query,
		query_count,
		dst_buffer.ptr[0],
		dst_offset,
		stride,
		flags
	)
end

function CommandBuffer:SetColorBlendEquation(first_attachment, blend_equation)
	vulkan.ext.vkCmdSetColorBlendEquationEXT(
		self.ptr[0],
		first_attachment or 0,
		1,
		vulkan.vk.s.ColorBlendEquationEXT(
			{
				srcColorBlendFactor = blend_equation.src_color_blend_factor,
				dstColorBlendFactor = blend_equation.dst_color_blend_factor,
				colorBlendOp = blend_equation.color_blend_op,
				srcAlphaBlendFactor = blend_equation.src_alpha_blend_factor,
				dstAlphaBlendFactor = blend_equation.dst_alpha_blend_factor,
				alphaBlendOp = blend_equation.alpha_blend_op,
			}
		)
	)
end

function CommandBuffer:PushConstants(layout, stage, binding, data_size, data)
	vulkan.lib.vkCmdPushConstants(
		self.ptr[0],
		layout.ptr[0],
		vulkan.vk.e.VkShaderStageFlagBits(stage),
		binding,
		data_size,
		data
	)
end

function CommandBuffer:ClearColorImage(config)
	vulkan.lib.vkCmdClearColorImage(
		self.ptr[0],
		config.image,
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		vulkan.vk.VkClearColorValue({
			float32 = config.color or {0.0, 0.0, 0.0, 1.0},
		}),
		1,
		vulkan.vk.s.ImageSubresourceRange(
			{
				aspectMask = config.aspect_mask or "color",
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

local format_to_aspect = {}

if true then
	for _, n in pairs(vulkan.vk.VkFormat) do
		local format = vulkan.vk.str.VkFormat(n)

		if format then
			if format:match("d%d+.*s%d+") or format:match("s%d+.*d%d+") then
				-- Depth-stencil format (e.g., D24_UNORM_S8_UINT)
				aspect = {"depth", "stencil"}
			elseif format:match("^d%d") or format:match("depth") then
				-- Depth-only format (e.g., D32_SFLOAT)
				aspect = "depth"
			elseif format:match("^s%d") or format:match("stencil") then
				-- Stencil-only format
				aspect = "stencil"
			else
				aspect = "color"
			end

			format_to_aspect[format] = aspect
		end
	end
end

function CommandBuffer:PipelineBarrier(config)
	local stage_map = {
		compute = "compute_shader",
		fragment = "fragment_shader",
		transfer = "transfer",
		vertex = "vertex_shader",
		vertex_input = "vertex_input",
		all_commands = "all_commands",
		top_of_pipe = "top_of_pipe",
		color_attachment_output = "color_attachment_output",
		early_fragment_tests = "early_fragment_tests",
		late_fragment_tests = "late_fragment_tests",
	}

	local function translate_stage(stage)
		if type(stage) == "table" then
			local out = {}

			for i, v in ipairs(stage) do
				out[i] = stage_map[v] or v
			end

			return out
		end

		return stage_map[stage] or stage
	end

	local srcStage = vulkan.vk.e.VkPipelineStageFlagBits(translate_stage(config.srcStage or "compute"))
	local dstStage = vulkan.vk.e.VkPipelineStageFlagBits(translate_stage(config.dstStage or "fragment"))
	local imageBarriers = nil
	local imageBarrierCount = 0
	local bufferBarriers = nil
	local bufferBarrierCount = 0

	if config.imageBarriers then
		imageBarrierCount = #config.imageBarriers
		imageBarriers = vulkan.T.Array(vulkan.vk.VkImageMemoryBarrier)(imageBarrierCount)

		for i, barrier in ipairs(config.imageBarriers) do
			local aspect = barrier.aspect

			if not aspect and barrier.image.format then
				aspect = assert(format_to_aspect[barrier.image.format])
			end

			aspect = aspect or "color"
			imageBarriers[i - 1] = vulkan.vk.s.ImageMemoryBarrier(
				{
					srcAccessMask = barrier.srcAccessMask or "none",
					dstAccessMask = barrier.dstAccessMask or "none",
					oldLayout = barrier.oldLayout or "undefined",
					newLayout = barrier.newLayout or "general",
					srcQueueFamilyIndex = 0xFFFFFFFF,
					dstQueueFamilyIndex = 0xFFFFFFFF,
					image = barrier.image.ptr[0],
					subresourceRange = {
						aspectMask = aspect,
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
			bufferBarriers[i - 1] = vulkan.vk.s.BufferMemoryBarrier(
				{
					srcAccessMask = barrier.srcAccessMask or "host_write",
					dstAccessMask = barrier.dstAccessMask or "vertex_attribute_read",
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
			srcSubresource = vulkan.vk.s.ImageSubresourceLayers(
				{
					aspectMask = "color",
					mipLevel = 0,
					baseArrayLayer = 0,
					layerCount = 1,
				}
			),
			srcOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
			dstSubresource = vulkan.vk.s.ImageSubresourceLayers(
				{
					aspectMask = "color",
					mipLevel = 0,
					baseArrayLayer = 0,
					layerCount = 1,
				}
			),
			dstOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
			extent = vulkan.vk.VkExtent3D({width = width, height = height, depth = 1}),
		}
	)
	vulkan.lib.vkCmdCopyImage(
		self.ptr[0],
		srcImage,
		vulkan.vk.e.VkImageLayout("transfer_src_optimal"),
		dstImage,
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		region
	)
end

function CommandBuffer:CopyBufferToImage(buffer, image, width, height)
	vulkan.lib.vkCmdCopyBufferToImage(
		self.ptr[0],
		buffer.ptr[0],
		image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		vulkan.vk.VkBufferImageCopy(
			{
				bufferOffset = 0,
				bufferRowLength = 0,
				bufferImageHeight = 0,
				imageSubresource = vulkan.vk.s.ImageSubresourceLayers(
					{
						aspectMask = "color",
						mipLevel = 0,
						baseArrayLayer = 0,
						layerCount = 1,
					}
				),
				imageOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
				imageExtent = vulkan.vk.VkExtent3D({width = width, height = height, depth = 1}),
			}
		)
	)
end

function CommandBuffer:CopyBufferToImageMip(buffer, image, width, height, mip_level, buffer_offset, buffer_size)
	vulkan.lib.vkCmdCopyBufferToImage(
		self.ptr[0],
		buffer.ptr[0],
		image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		vulkan.vk.VkBufferImageCopy(
			{
				bufferOffset = buffer_offset or 0,
				bufferRowLength = 0,
				bufferImageHeight = 0,
				imageSubresource = vulkan.vk.s.ImageSubresourceLayers(
					{
						aspectMask = "color",
						mipLevel = mip_level or 0,
						baseArrayLayer = 0,
						layerCount = 1,
					}
				),
				imageOffset = {x = 0, y = 0, z = 0},
				imageExtent = {width = width, height = height, depth = 1},
			}
		)
	)
end

function CommandBuffer:BlitImage(config)
	local srcSubresource = vulkan.vk.VkImageSubresourceLayers()
	srcSubresource.aspectMask = vulkan.vk.e.VkImageAspectFlagBits("color")
	srcSubresource.mipLevel = config.src_mip_level or 0
	srcSubresource.baseArrayLayer = 0
	srcSubresource.layerCount = 1
	local dstSubresource = vulkan.vk.VkImageSubresourceLayers()
	dstSubresource.aspectMask = vulkan.vk.e.VkImageAspectFlagBits("color")
	dstSubresource.mipLevel = config.dst_mip_level or 0
	dstSubresource.baseArrayLayer = 0
	dstSubresource.layerCount = 1
	local region = vulkan.vk.VkImageBlit()
	region.srcSubresource = srcSubresource
	region.srcOffsets[0].x = 0
	region.srcOffsets[0].y = 0
	region.srcOffsets[0].z = 0
	region.srcOffsets[1].x = config.src_width
	region.srcOffsets[1].y = config.src_height
	region.srcOffsets[1].z = 1
	region.dstSubresource = dstSubresource
	region.dstOffsets[0].x = 0
	region.dstOffsets[0].y = 0
	region.dstOffsets[0].z = 0
	region.dstOffsets[1].x = config.dst_width
	region.dstOffsets[1].y = config.dst_height
	region.dstOffsets[1].z = 1
	vulkan.lib.vkCmdBlitImage(
		self.ptr[0],
		config.src_image.ptr[0],
		vulkan.vk.e.VkImageLayout(config.src_layout or "transfer_src_optimal"),
		config.dst_image.ptr[0],
		vulkan.vk.e.VkImageLayout(config.dst_layout or "transfer_dst_optimal"),
		1,
		region,
		vulkan.vk.e.VkFilter(config.filter or "linear")
	)
end

return CommandBuffer:Register()
