local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local CommandBuffer = prototype.CreateTemplate("vulkan_command_buffer")
local type = _G.type
local VkBufferArray = vulkan.T.Array(vulkan.vk.VkBuffer)
local VkBufferArray1 = vulkan.T.Array(vulkan.vk.VkBuffer, 1)
local VkDescriptorSetArray = vulkan.T.Array(vulkan.vk.VkDescriptorSet)
local VkDeviceSizeArray = vulkan.T.Array(vulkan.vk.VkDeviceSize)
local VkDeviceSizeArray1 = vulkan.T.Array(vulkan.vk.VkDeviceSize, 1)
local UInt32Array = ffi.typeof("uint32_t[?]")
local UInt32Array1 = ffi.typeof("uint32_t[1]")

local function normalize_bool(value)
	return value ~= nil and value ~= false and value ~= 0
end

local function clone_state_value(value)
	if type(value) ~= "table" then return value end

	local copy = {}

	for key, entry in pairs(value) do
		copy[key] = clone_state_value(entry)
	end

	return copy
end

local function state_value_equals(a, b)
	local ta = type(a)
	local tb = type(b)

	if ta ~= tb then return false end

	if ta ~= "table" then return a == b end

	for key, value in pairs(a) do
		if not state_value_equals(value, b[key]) then return false end
	end

	for key in pairs(b) do
		if a[key] == nil then return false end
	end

	return true
end

local function should_apply_dynamic_state(self, key, value)
	self.dynamic_state_cache = self.dynamic_state_cache or {}
	local cached = self.dynamic_state_cache[key]

	if cached ~= nil and state_value_equals(cached, value) then return false end

	self.dynamic_state_cache[key] = clone_state_value(value)
	return true
end

local function descriptor_sets_equal(a, b)
	if a == b then return true end

	if type(a) ~= "table" or type(b) ~= "table" then return false end

	if a.layout ~= b.layout or a.first_set ~= b.first_set then return false end

	if #a.sets ~= #b.sets or #a.dynamic_offsets ~= #b.dynamic_offsets then
		return false
	end

	for i = 1, #a.sets do
		if a.sets[i] ~= b.sets[i] then return false end
	end

	for i = 1, #a.dynamic_offsets do
		if a.dynamic_offsets[i] ~= b.dynamic_offsets[i] then return false end
	end

	return true
end

local function capture_descriptor_set_binding(pipelineLayout, descriptorSets, dynamicOffsets, firstSet)
	local state = {
		layout = pipelineLayout,
		first_set = firstSet or 0,
		sets = {},
		dynamic_offsets = {},
	}

	for i = 1, #descriptorSets do
		state.sets[i] = descriptorSets[i]
	end

	if type(dynamicOffsets) == "table" then
		for i = 1, #dynamicOffsets do
			state.dynamic_offsets[i] = dynamicOffsets[i]
		end
	elseif type(dynamicOffsets) == "number" and dynamicOffsets > 0 then
		state.dynamic_offsets[1] = dynamicOffsets
	end

	return state
end

local function get_view_samples(view)
	if view and view.image and view.image.samples then return view.image.samples end

	return "1"
end

function CommandBuffer.New(command_pool)
	local ptr = vulkan.T.Box(vulkan.vk.VkCommandBuffer)()
	vulkan.assert(
		vulkan.lib.vkAllocateCommandBuffers(
			command_pool.device.ptr[0],
			vulkan.vk.s.CommandBufferAllocateInfo{
				commandPool = command_pool.ptr[0],
				level = "primary",
				commandBufferCount = 1,
			},
			ptr
		),
		"failed to allocate command buffer"
	)
	return CommandBuffer:CreateObject{ptr = ptr, command_pool = command_pool, is_recording = false}
end

function CommandBuffer:OnRemove()
	self.is_recording = false
	self.is_rendering = false

	if self.command_pool:IsValid() and self.command_pool.device:IsValid() then
		self.command_pool.device:WaitIdle()
		self.command_pool:FreeCommandBuffer(self)
	end
end

function CommandBuffer:Begin()
	self.bound_pipelines = {}
	self.bound_descriptor_sets = {}
	self.dynamic_state_cache = {}
	self.keepalive_resources = nil
	vulkan.assert(
		vulkan.lib.vkBeginCommandBuffer(self.ptr[0], vulkan.vk.s.CommandBufferBeginInfo{
			flags = "one_time_submit",
		}),
		"failed to begin command buffer"
	)
	self.is_recording = true
	self.is_rendering = false
end

function CommandBuffer:Reset()
	self.bound_pipelines = {}
	self.bound_descriptor_sets = {}
	self.dynamic_state_cache = {}
	self.keepalive_resources = nil
	self.is_recording = false
	self.is_rendering = false
	vulkan.lib.vkResetCommandBuffer(self.ptr[0], 0)
end

function CommandBuffer:UpdateBuffer(buffer, offset, size, data)
	vulkan.lib.vkCmdUpdateBuffer(self.ptr[0], buffer.ptr[0], offset, size, data)
end

function CommandBuffer:End()
	vulkan.assert(vulkan.lib.vkEndCommandBuffer(self.ptr[0]), "failed to end command buffer")
	self.is_recording = false
	self.is_rendering = false
end

local RECT = vulkan.vk.VkRect2D()

function CommandBuffer:BeginRendering(config)
	local colorAttachmentInfo = nil
	local colorAttachmentCount = 0
	local rendering_color_formats = nil
	local rendering_color_format = nil
	local rendering_samples = "1"

	if config.color_attachments then
		colorAttachmentCount = #config.color_attachments
		colorAttachmentInfo = vulkan.T.Array(vulkan.vk.VkRenderingAttachmentInfo)(colorAttachmentCount)
		rendering_color_formats = {}

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

			rendering_color_formats[i] = attachment.color_image_view and attachment.color_image_view.format or nil

			if i == 1 then
				rendering_color_format = rendering_color_formats[i]
				rendering_samples = get_view_samples(attachment.msaa_image_view or attachment.color_image_view)
			end

			local clearValue = vulkan.vk.VkClearValue()
			local clear_color = attachment.clear_color or {0, 0, 0, 1}
			clearValue.color.float32[0] = clear_color[1]
			clearValue.color.float32[1] = clear_color[2]
			clearValue.color.float32[2] = clear_color[3]
			clearValue.color.float32[3] = clear_color[4]
			colorAttachmentInfo[i - 1] = vulkan.vk.s.RenderingAttachmentInfo{
				imageView = imageView,
				imageLayout = "color_attachment_optimal",
				resolveMode = resolveMode,
				resolveImageView = resolveImageView,
				resolveImageLayout = resolveImageLayout,
				loadOp = attachment.load_op or "clear",
				storeOp = attachment.store_op or "store",
				clearValue = clearValue,
			}
		end
	elseif config.color_image_view then
		colorAttachmentCount = 1
		local imageView = config.color_image_view.ptr[0]
		local resolveImageView = nil
		local resolveMode = "none"
		local resolveImageLayout = "undefined"
		rendering_color_format = config.color_image_view.format
		rendering_color_formats = {rendering_color_format}
		rendering_samples = get_view_samples(config.msaa_image_view or config.color_image_view)

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
		colorAttachmentInfo = vulkan.vk.s.RenderingAttachmentInfo{
			imageView = imageView,
			imageLayout = "color_attachment_optimal",
			resolveMode = resolveMode,
			resolveImageView = resolveImageView,
			resolveImageLayout = resolveImageLayout,
			loadOp = config.load_op or "clear",
			storeOp = config.store_op or "store",
			clearValue = clearValue,
		}
	end

	local depthAttachmentInfo = nil

	if config.depth_image_view then
		local clearValue = vulkan.vk.VkClearValue()
		clearValue.depthStencil.depth = config.clear_depth or 1.0
		clearValue.depthStencil.stencil = config.clear_stencil or 0
		depthAttachmentInfo = vulkan.vk.s.RenderingAttachmentInfo{
			imageView = config.depth_image_view.ptr[0],
			imageLayout = config.depth_layout or "depth_attachment_optimal",
			resolveMode = "none",
			resolveImageLayout = "undefined",
			loadOp = config.load_op or "clear",
			storeOp = config.depth_store and "store" or "dont_care",
			clearValue = clearValue,
		}
	end

	local stencilAttachmentInfo = nil

	if config.stencil_image_view then
		local clearValue = vulkan.vk.VkClearValue()
		clearValue.depthStencil.depth = config.clear_depth or 1.0
		clearValue.depthStencil.stencil = config.clear_stencil or 0
		stencilAttachmentInfo = vulkan.vk.s.RenderingAttachmentInfo{
			imageView = config.stencil_image_view.ptr[0],
			imageLayout = config.stencil_layout or "stencil_attachment_optimal",
			resolveMode = "none",
			resolveImageLayout = "undefined",
			loadOp = config.stencil_load_op or config.load_op or "clear",
			storeOp = config.stencil_store and "store" or "dont_care",
			clearValue = clearValue,
		}

		if config.depth_image_view == config.stencil_image_view then
			depthAttachmentInfo.imageLayout = vulkan.vk.e.VkImageLayout(config.depth_layout or "depth_stencil_attachment_optimal")
			stencilAttachmentInfo.imageLayout = vulkan.vk.e.VkImageLayout(config.stencil_layout or "depth_stencil_attachment_optimal")
		end
	end

	RECT.offset.x = config.x or 0
	RECT.offset.y = config.y or 0
	RECT.extent.width = config.w
	RECT.extent.height = config.h
	self.rendering_state = {
		color_attachment_count = colorAttachmentCount,
		color_formats = rendering_color_formats,
		color_format = rendering_color_format,
		depth_format = config.depth_image_view and config.depth_image_view.format or nil,
		samples = rendering_samples,
	}
	vulkan.lib.vkCmdBeginRendering(
		self.ptr[0],
		vulkan.vk.s.RenderingInfo{
			renderArea = RECT,
			viewMask = 0,
			layerCount = 1,
			colorAttachmentCount = colorAttachmentCount,
			pColorAttachments = colorAttachmentInfo,
			pDepthAttachment = depthAttachmentInfo,
			pStencilAttachment = stencilAttachmentInfo,
		}
	)
	self.is_rendering = true
end

function CommandBuffer:EndRendering()
	if not self.is_rendering then return end

	vulkan.lib.vkCmdEndRendering(self.ptr[0])
	self.is_rendering = false
	self.rendering_state = nil
end

function CommandBuffer:BindPipeline(pipeline, bind_point)
	self.bound_pipelines = self.bound_pipelines or {}

	if self.bound_pipelines[bind_point] == pipeline then return end

	vulkan.lib.vkCmdBindPipeline(self.ptr[0], vulkan.vk.e.VkPipelineBindPoint(bind_point), pipeline.ptr[0])
	self.bound_pipelines[bind_point] = pipeline
end

function CommandBuffer:BindVertexBuffers(firstBinding, buffers, offsets)
	local bufferCount = #buffers
	local bufferArray = VkBufferArray(bufferCount)
	local offsetArray = VkDeviceSizeArray(bufferCount)
	local hasOffsets = offsets ~= nil

	for i = 1, bufferCount do
		local buffer = buffers[i]
		bufferArray[i - 1] = buffer.ptr[0]
		offsetArray[i - 1] = hasOffsets and offsets[i] or 0
	end

	vulkan.lib.vkCmdBindVertexBuffers(self.ptr[0], firstBinding or 0, bufferCount, bufferArray, offsetArray)
end

function CommandBuffer:BindVertexBuffer(buffer, binding, offset)
	local bufferArray = VkBufferArray1()
	local offsetArray = VkDeviceSizeArray1()
	bufferArray[0] = buffer.ptr[0]
	offsetArray[0] = offset or 0
	vulkan.lib.vkCmdBindVertexBuffers(self.ptr[0], binding or 0, 1, bufferArray, offsetArray)
end

function CommandBuffer:BindDescriptorSets(pipeline_bind_point, pipelineLayout, descriptorSets, dynamicOffsets, firstSet)
	self.bound_descriptor_sets = self.bound_descriptor_sets or {}
	local bind_key = tostring(pipeline_bind_point)
	local binding = capture_descriptor_set_binding(pipelineLayout, descriptorSets, dynamicOffsets, firstSet)

	if descriptor_sets_equal(self.bound_descriptor_sets[bind_key], binding) then
		return
	end

	local setCount = #descriptorSets
	local setArray = VkDescriptorSetArray(setCount)

	for i = 1, setCount do
		local ds = descriptorSets[i]
		setArray[i - 1] = ds.ptr[0]
	end

	local dynamicOffsetCount = 0
	local pDynamicOffsets = nil
	local dynamicOffsetsType = type(dynamicOffsets)

	if dynamicOffsetsType == "table" then
		dynamicOffsetCount = #dynamicOffsets
		pDynamicOffsets = UInt32Array(dynamicOffsetCount)

		for i = 1, dynamicOffsetCount do
			local offset = dynamicOffsets[i]
			pDynamicOffsets[i - 1] = offset
		end
	elseif dynamicOffsetsType == "number" and dynamicOffsets > 0 then
		dynamicOffsetCount = 1
		pDynamicOffsets = UInt32Array1(dynamicOffsets)
	end

	vulkan.lib.vkCmdBindDescriptorSets(
		self.ptr[0],
		vulkan.vk.e.VkPipelineBindPoint(pipeline_bind_point),
		pipelineLayout.ptr[0],
		firstSet or 0,
		setCount,
		setArray,
		dynamicOffsetCount,
		pDynamicOffsets
	)
	self.bound_descriptor_sets[bind_key] = binding
end

function CommandBuffer:Draw(vertexCount, instanceCount, firstVertex, firstInstance)
	vulkan.lib.vkCmdDraw(self.ptr[0], vertexCount or 3, instanceCount or 1, firstVertex or 0, firstInstance or 0)
end

function CommandBuffer:BindIndexBuffer(buffer, offset, indexType)
	if indexType == "uint16_t" then indexType = "uint16" end

	if indexType == "uint32_t" then indexType = "uint32" end

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

function CommandBuffer:DrawMeshTasks(groupCountX, groupCountY, groupCountZ)
	if not vulkan.ext.vkCmdDrawMeshTasksEXT then return end

	vulkan.ext.vkCmdDrawMeshTasksEXT(self.ptr[0], groupCountX, groupCountY, groupCountZ)
end

function CommandBuffer:SetCullMode(cull_mode)
	if not should_apply_dynamic_state(self, "cull_mode", cull_mode or "back") then
		return
	end

	local mode = vulkan.vk.e.VkCullModeFlagBits(cull_mode or "back")

	if vulkan.ext.vkCmdSetCullModeEXT then
		vulkan.ext.vkCmdSetCullModeEXT(self.ptr[0], mode)
	elseif vulkan.lib.vkCmdSetCullMode then
		vulkan.lib.vkCmdSetCullMode(self.ptr[0], mode)
	end
end

local function normalize_color_write_mask(mask)
	if type(mask) ~= "table" then return mask or 0 end

	local bits = 0

	for i = 1, #mask do
		local channel = mask[i]

		if type(channel) == "string" then
			channel = channel:lower()

			if channel == "r" then
				bits = bit.bor(bits, 1)
			elseif channel == "g" then
				bits = bit.bor(bits, 2)
			elseif channel == "b" then
				bits = bit.bor(bits, 4)
			elseif channel == "a" then
				bits = bit.bor(bits, 8)
			end
		elseif type(channel) == "number" then
			bits = bit.bor(bits, channel)
		end
	end

	return bits
end

function CommandBuffer:SetFrontFace(front_face)
	if not should_apply_dynamic_state(self, "front_face", front_face or "clockwise") then
		return
	end

	local face = vulkan.vk.e.VkFrontFace(front_face or "clockwise")

	if vulkan.ext.vkCmdSetFrontFaceEXT then
		vulkan.ext.vkCmdSetFrontFaceEXT(self.ptr[0], face)
	elseif vulkan.lib.vkCmdSetFrontFace then
		vulkan.lib.vkCmdSetFrontFace(self.ptr[0], face)
	end
end

function CommandBuffer:SetDepthTestEnable(enabled)
	if
		not should_apply_dynamic_state(self, "depth_test_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetDepthTestEnableEXT then
		vulkan.ext.vkCmdSetDepthTestEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetDepthTestEnable then
		vulkan.lib.vkCmdSetDepthTestEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetDepthWriteEnable(enabled)
	if
		not should_apply_dynamic_state(self, "depth_write_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetDepthWriteEnableEXT then
		vulkan.ext.vkCmdSetDepthWriteEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetDepthWriteEnable then
		vulkan.lib.vkCmdSetDepthWriteEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetDepthCompareOp(compare_op)
	if not should_apply_dynamic_state(self, "depth_compare_op", compare_op or "less") then
		return
	end

	local op = vulkan.vk.e.VkCompareOp(compare_op or "less")

	if vulkan.ext.vkCmdSetDepthCompareOpEXT then
		vulkan.ext.vkCmdSetDepthCompareOpEXT(self.ptr[0], op)
	elseif vulkan.lib.vkCmdSetDepthCompareOp then
		vulkan.lib.vkCmdSetDepthCompareOp(self.ptr[0], op)
	end
end

function CommandBuffer:SetDepthBiasEnable(enabled)
	if
		not should_apply_dynamic_state(self, "depth_bias_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetDepthBiasEnableEXT then
		vulkan.ext.vkCmdSetDepthBiasEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetDepthBiasEnable then
		vulkan.lib.vkCmdSetDepthBiasEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetDepthBias(constant_factor, clamp, slope_factor)
	if
		not should_apply_dynamic_state(self, "depth_bias", {constant_factor or 0, clamp or 0, slope_factor or 0})
	then
		return
	end

	vulkan.lib.vkCmdSetDepthBias(self.ptr[0], constant_factor or 0, clamp or 0, slope_factor or 0)
end

function CommandBuffer:SetPrimitiveRestartEnable(enabled)
	if
		not should_apply_dynamic_state(self, "primitive_restart_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetPrimitiveRestartEnableEXT then
		vulkan.ext.vkCmdSetPrimitiveRestartEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetPrimitiveRestartEnable then
		vulkan.lib.vkCmdSetPrimitiveRestartEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetRasterizerDiscardEnable(enabled)
	if
		not should_apply_dynamic_state(self, "rasterizer_discard_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetRasterizerDiscardEnableEXT then
		vulkan.ext.vkCmdSetRasterizerDiscardEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetRasterizerDiscardEnable then
		vulkan.lib.vkCmdSetRasterizerDiscardEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetDepthClampEnable(enabled)
	if
		not should_apply_dynamic_state(self, "depth_clamp_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetDepthClampEnableEXT then
		vulkan.ext.vkCmdSetDepthClampEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetDepthClampEnable then
		vulkan.lib.vkCmdSetDepthClampEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetPolygonMode(polygon_mode)
	if not should_apply_dynamic_state(self, "polygon_mode", polygon_mode or "fill") then
		return
	end

	if vulkan.ext.vkCmdSetPolygonModeEXT then
		vulkan.ext.vkCmdSetPolygonModeEXT(self.ptr[0], vulkan.vk.e.VkPolygonMode(polygon_mode or "fill"))
	end
end

function CommandBuffer:SetPrimitiveTopology(topology)
	if
		not should_apply_dynamic_state(self, "primitive_topology", topology or "triangle_list")
	then
		return
	end

	local topo = vulkan.vk.e.VkPrimitiveTopology(topology or "triangle_list")

	if vulkan.ext.vkCmdSetPrimitiveTopologyEXT then
		vulkan.ext.vkCmdSetPrimitiveTopologyEXT(self.ptr[0], topo)
	elseif vulkan.lib.vkCmdSetPrimitiveTopology then
		vulkan.lib.vkCmdSetPrimitiveTopology(self.ptr[0], topo)
	end
end

function CommandBuffer:SetViewport(x, y, width, height, minDepth, maxDepth)
	assert(width > 0)
	assert(height > 0)

	if
		not should_apply_dynamic_state(
			self,
			"viewport0",
			{x or 0.0, y or 0.0, width, height, minDepth or 0.0, maxDepth or 1.0}
		)
	then
		return
	end

	vulkan.lib.vkCmdSetViewport(
		self.ptr[0],
		0,
		1,
		vulkan.vk.VkViewport{
			x = x or 0.0,
			y = y or 0.0,
			width = width,
			height = height,
			minDepth = minDepth or 0.0,
			maxDepth = maxDepth or 1.0,
		}
	)
end

function CommandBuffer:SetScissor(x, y, width, height)
	assert(width > 0)
	assert(height > 0)

	if not should_apply_dynamic_state(self, "scissor0", {x or 0, y or 0, width, height}) then
		return
	end

	vulkan.lib.vkCmdSetScissor(
		self.ptr[0],
		0,
		1,
		vulkan.vk.VkRect2D{
			offset = vulkan.vk.VkOffset2D{x = x or 0, y = y or 0},
			extent = vulkan.vk.VkExtent2D{width = width, height = height},
		}
	)
end

function CommandBuffer:SetStencilReference(face_mask, reference)
	if
		not should_apply_dynamic_state(self, "stencil_reference:" .. tostring(face_mask), reference)
	then
		return
	end

	vulkan.lib.vkCmdSetStencilReference(self.ptr[0], vulkan.vk.e.VkStencilFaceFlagBits(face_mask), reference)
end

function CommandBuffer:SetStencilCompareMask(face_mask, compare_mask)
	if
		not should_apply_dynamic_state(self, "stencil_compare_mask:" .. tostring(face_mask), compare_mask)
	then
		return
	end

	vulkan.lib.vkCmdSetStencilCompareMask(self.ptr[0], vulkan.vk.e.VkStencilFaceFlagBits(face_mask), compare_mask)
end

function CommandBuffer:SetStencilWriteMask(face_mask, write_mask)
	if
		not should_apply_dynamic_state(self, "stencil_write_mask:" .. tostring(face_mask), write_mask)
	then
		return
	end

	vulkan.lib.vkCmdSetStencilWriteMask(self.ptr[0], vulkan.vk.e.VkStencilFaceFlagBits(face_mask), write_mask)
end

function CommandBuffer:SetStencilTestEnable(enabled)
	if
		not should_apply_dynamic_state(self, "stencil_test_enable", normalize_bool(enabled))
	then
		return
	end

	if vulkan.ext.vkCmdSetStencilTestEnableEXT then
		vulkan.ext.vkCmdSetStencilTestEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	elseif vulkan.lib.vkCmdSetStencilTestEnable then
		vulkan.lib.vkCmdSetStencilTestEnable(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetStencilOp(face_mask, fail_op, pass_op, depth_fail_op, compare_op)
	if
		not should_apply_dynamic_state(
			self,
			"stencil_op:" .. tostring(face_mask),
			{fail_op, pass_op, depth_fail_op, compare_op}
		)
	then
		return
	end

	local face = vulkan.vk.e.VkStencilFaceFlagBits(face_mask)
	local fail = vulkan.vk.e.VkStencilOp(fail_op)
	local pass = vulkan.vk.e.VkStencilOp(pass_op)
	local dfail = vulkan.vk.e.VkStencilOp(depth_fail_op)
	local comp = vulkan.vk.e.VkCompareOp(compare_op)

	if vulkan.ext.vkCmdSetStencilOpEXT then
		vulkan.ext.vkCmdSetStencilOpEXT(self.ptr[0], face, fail, pass, dfail, comp)
	elseif vulkan.lib.vkCmdSetStencilOp then
		vulkan.lib.vkCmdSetStencilOp(self.ptr[0], face, fail, pass, dfail, comp)
	end
end

function CommandBuffer:SetBlendConstants(r, g, b, a)
	if
		not should_apply_dynamic_state(self, "blend_constants", {r or 0.0, g or 0.0, b or 0.0, a or 0.0})
	then
		return
	end

	local constants = ffi.new("float[4]", r or 0.0, g or 0.0, b or 0.0, a or 0.0)
	vulkan.lib.vkCmdSetBlendConstants(self.ptr[0], constants)
end

function CommandBuffer:SetColorBlendEnable(first_attachment, blend_enable)
	if
		not should_apply_dynamic_state(
			self,
			"color_blend_enable:" .. tostring(first_attachment or 0),
			blend_enable
		)
	then
		return
	end

	local enable_array
	local count

	if type(blend_enable) == "boolean" then
		enable_array = UInt32Array1(blend_enable and 1 or 0)
		count = 1
	elseif type(blend_enable) == "table" then
		count = #blend_enable
		enable_array = UInt32Array(count)

		for i = 1, count do
			enable_array[i - 1] = blend_enable[i] and 1 or 0
		end
	else
		error("blend_enable must be a boolean or table of booleans")
	end

	if vulkan.ext.vkCmdSetColorBlendEnableEXT then
		vulkan.ext.vkCmdSetColorBlendEnableEXT(self.ptr[0], first_attachment or 0, count, enable_array)
	end
end

function CommandBuffer:SetColorWriteMask(first_attachment, color_write_mask)
	if not vulkan.ext.vkCmdSetColorWriteMaskEXT then return end

	if
		not should_apply_dynamic_state(
			self,
			"color_write_mask:" .. tostring(first_attachment or 0),
			color_write_mask
		)
	then
		return
	end

	local mask_array
	local count

	if
		type(color_write_mask) == "table" and
		(
			type(color_write_mask[1]) == "table" or
			(
				type(color_write_mask[1]) == "number" and
				#color_write_mask > 1
			)
		)
	then
		count = #color_write_mask
		mask_array = UInt32Array(count)

		for i = 1, count do
			mask_array[i - 1] = normalize_color_write_mask(color_write_mask[i])
		end
	else
		count = 1
		mask_array = UInt32Array1(normalize_color_write_mask(color_write_mask))
	end

	vulkan.ext.vkCmdSetColorWriteMaskEXT(self.ptr[0], first_attachment or 0, count, mask_array)
end

function CommandBuffer:SetLogicOpEnable(enabled)
	if not should_apply_dynamic_state(self, "logic_op_enable", normalize_bool(enabled)) then
		return
	end

	if vulkan.ext.vkCmdSetLogicOpEnableEXT then
		vulkan.ext.vkCmdSetLogicOpEnableEXT(self.ptr[0], normalize_bool(enabled) and 1 or 0)
	end
end

function CommandBuffer:SetLogicOp(logic_op)
	if not should_apply_dynamic_state(self, "logic_op", logic_op or "copy") then
		return
	end

	local op = vulkan.vk.e.VkLogicOp(logic_op or "copy")

	if vulkan.ext.vkCmdSetLogicOpEXT then
		vulkan.ext.vkCmdSetLogicOpEXT(self.ptr[0], op)
	end
end

function CommandBuffer:BeginConditionalRendering(buffer, offset, inverted)
	if not buffer then return end

	if not vulkan.ext.vkCmdBeginConditionalRenderingEXT then return end

	local flags = inverted and
		vulkan.vk.VkConditionalRenderingFlagBitsEXT.VK_CONDITIONAL_RENDERING_INVERTED_BIT_EXT or
		0
	local conditional_rendering_begin = vulkan.vk.s.ConditionalRenderingBeginInfoEXT{
		buffer = buffer.ptr[0],
		offset = offset or 0,
		flags = flags,
	}
	vulkan.ext.vkCmdBeginConditionalRenderingEXT(self.ptr[0], conditional_rendering_begin)
end

function CommandBuffer:EndConditionalRendering()
	if not vulkan.ext.vkCmdEndConditionalRenderingEXT then return end

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
	if not vulkan.ext.vkCmdSetColorBlendEquationEXT then return end

	if
		not should_apply_dynamic_state(
			self,
			"color_blend_equation:" .. tostring(first_attachment or 0),
			blend_equation
		)
	then
		return
	end

	vulkan.ext.vkCmdSetColorBlendEquationEXT(
		self.ptr[0],
		first_attachment or 0,
		1,
		vulkan.vk.s.ColorBlendEquationEXT{
			srcColorBlendFactor = blend_equation.src_color_blend_factor,
			dstColorBlendFactor = blend_equation.dst_color_blend_factor,
			colorBlendOp = blend_equation.color_blend_op,
			srcAlphaBlendFactor = blend_equation.src_alpha_blend_factor,
			dstAlphaBlendFactor = blend_equation.dst_alpha_blend_factor,
			alphaBlendOp = blend_equation.alpha_blend_op,
		}
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
	local clear_value = vulkan.vk.VkClearColorValue()
	clear_value.float32 = config.color or {0.0, 0.0, 0.0, 1.0}
	vulkan.lib.vkCmdClearColorImage(
		self.ptr[0],
		config.image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		clear_value,
		1,
		vulkan.vk.s.ImageSubresourceRange{
			aspectMask = config.aspect_mask or "color",
			baseMipLevel = config.base_mip_level or 0,
			levelCount = config.level_count or 1,
			baseArrayLayer = config.base_array_layer or 0,
			layerCount = config.layer_count or 1,
		}
	)
end

function CommandBuffer:ClearAttachments(config)
	local attachments = {}
	local stencil_value = config.stencil

	if stencil_value == false then stencil_value = nil end

	if config.color then
		local clear_value = vulkan.vk.VkClearValue()
		clear_value.color.float32[0] = config.color[1] or 0.0
		clear_value.color.float32[1] = config.color[2] or 0.0
		clear_value.color.float32[2] = config.color[3] or 0.0
		clear_value.color.float32[3] = config.color[4] or 1.0
		attachments[#attachments + 1] = {
			aspectMask = vulkan.vk.e.VkImageAspectFlagBits("color"),
			colorAttachment = config.color_attachment or 0,
			clearValue = clear_value,
		}
	end

	if config.depth ~= nil then
		local clear_value = vulkan.vk.VkClearValue()
		clear_value.depthStencil.depth = config.depth
		clear_value.depthStencil.stencil = stencil_value or 0
		attachments[#attachments + 1] = {
			aspectMask = vulkan.vk.e.VkImageAspectFlagBits("depth"),
			colorAttachment = 0,
			clearValue = clear_value,
		}
	end

	if stencil_value ~= nil then
		local clear_value = vulkan.vk.VkClearValue()
		clear_value.depthStencil.depth = config.depth or 1.0
		clear_value.depthStencil.stencil = stencil_value
		attachments[#attachments + 1] = {
			aspectMask = vulkan.vk.e.VkImageAspectFlagBits("stencil"),
			colorAttachment = 0,
			clearValue = clear_value,
		}
	end

	if #attachments == 0 then return end

	local clear_rect = {
		rect = {
			offset = {x = config.x or 0, y = config.y or 0},
			extent = {width = config.w or 0, height = config.h or 0},
		},
		baseArrayLayer = 0,
		layerCount = 1,
	}
	local attachment_array = vulkan.T.Array(vulkan.vk.VkClearAttachment, #attachments)()

	for i, attachment in ipairs(attachments) do
		attachment_array[i - 1] = vulkan.vk.VkClearAttachment(attachment)
	end

	local clear_rect_array = vulkan.T.Array(vulkan.vk.VkClearRect, 1)()
	clear_rect_array[0] = vulkan.vk.VkClearRect(clear_rect)
	vulkan.lib.vkCmdClearAttachments(self.ptr[0], #attachments, attachment_array, 1, clear_rect_array)
end

function CommandBuffer:CopyImageToBuffer(config)
	vulkan.lib.vkCmdCopyImageToBuffer(
		self.ptr[0],
		config.image.ptr[0],
		vulkan.vk.e.VkImageLayout(config.image_layout or "transfer_src_optimal"),
		config.buffer.ptr[0],
		1,
		vulkan.vk.VkBufferImageCopy{
			bufferOffset = config.buffer_offset or 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = vulkan.vk.s.ImageSubresourceLayers{
				aspectMask = config.aspect_mask or "color",
				mipLevel = config.mip_level or 0,
				baseArrayLayer = config.base_array_layer or 0,
				layerCount = config.layer_count or 1,
			},
			imageOffset = {x = 0, y = 0, z = 0},
			imageExtent = {
				width = config.width,
				height = config.height,
				depth = config.depth or 1,
			},
		}
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
			local aspect

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

local vkCmdPipelineBarrier

if jit.os ~= "OSX" then
	vkCmdPipelineBarrier = vulkan.lib.vkCmdPipelineBarrier
end

function CommandBuffer:PipelineBarrier(config)
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
			-- Handle combined depth-stencil formats
			-- When aspect is a table (e.g., {"depth", "stencil"}), we need to use depth-stencil layouts
			local old_layout = barrier.oldLayout or "undefined"
			local new_layout = barrier.newLayout or "general"

			-- Fix layouts for combined depth-stencil formats
			if type(aspect) == "table" then
				-- Replace depth-only layouts with depth-stencil layouts
				if old_layout == "depth_attachment_optimal" then
					old_layout = "depth_stencil_attachment_optimal"
				elseif old_layout == "depth_read_only_optimal" then
					old_layout = "depth_stencil_read_only_optimal"
				end

				if new_layout == "depth_attachment_optimal" then
					new_layout = "depth_stencil_attachment_optimal"
				elseif new_layout == "depth_read_only_optimal" then
					new_layout = "depth_stencil_read_only_optimal"
				end
			end

			barrier.image.layout = new_layout
			imageBarriers[i - 1] = vulkan.vk.s.ImageMemoryBarrier{
				srcAccessMask = barrier.srcAccessMask or "none",
				dstAccessMask = barrier.dstAccessMask or "none",
				oldLayout = old_layout,
				newLayout = new_layout,
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
					baseArrayLayer = barrier.base_array_layer or 0,
					layerCount = barrier.layer_count or
						(
							barrier.image.GetArrayLayers and
							barrier.image:GetArrayLayers() or
							1
						),
				},
			}
		end
	end

	if config.bufferBarriers then
		bufferBarrierCount = #config.bufferBarriers
		bufferBarriers = vulkan.T.Array(vulkan.vk.VkBufferMemoryBarrier)(bufferBarrierCount)

		for i, barrier in ipairs(config.bufferBarriers) do
			bufferBarriers[i - 1] = vulkan.vk.s.BufferMemoryBarrier{
				srcAccessMask = barrier.srcAccessMask or "host_write",
				dstAccessMask = barrier.dstAccessMask or "vertex_attribute_read",
				srcQueueFamilyIndex = 0xFFFFFFFF,
				dstQueueFamilyIndex = 0xFFFFFFFF,
				buffer = barrier.buffer.ptr[0],
				offset = barrier.offset or 0,
				size = barrier.size or 0xFFFFFFFFFFFFFFFF,
			}
		end
	end

	if not vkCmdPipelineBarrier then
		vkCmdPipelineBarrier = function(...)
			return vulkan.lib.vkCmdPipelineBarrier(...)
		end
		jit.off(vkCmdPipelineBarrier)
	end

	vkCmdPipelineBarrier(
		self.ptr[0],
		srcStage,
		dstStage,
		0,
		0,
		nil,
		bufferBarrierCount,
		bufferBarrierCount > 0 and bufferBarriers or nil,
		imageBarrierCount,
		imageBarrierCount > 0 and imageBarriers or nil
	)
end

function CommandBuffer:CopyImageToImage(srcImage, dstImage, width, height, srcX, srcY, dstX, dstY)
	local region = vulkan.vk.VkImageCopy{
		srcSubresource = vulkan.vk.s.ImageSubresourceLayers{
			aspectMask = "color",
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		srcOffset = vulkan.vk.VkOffset3D{x = srcX or 0, y = srcY or 0, z = 0},
		dstSubresource = vulkan.vk.s.ImageSubresourceLayers{
			aspectMask = "color",
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		dstOffset = vulkan.vk.VkOffset3D{x = dstX or 0, y = dstY or 0, z = 0},
		extent = vulkan.vk.VkExtent3D{width = width, height = height, depth = 1},
	}
	vulkan.lib.vkCmdCopyImage(
		self.ptr[0],
		srcImage.ptr ~= nil and srcImage.ptr[0] or srcImage,
		vulkan.vk.e.VkImageLayout("transfer_src_optimal"),
		dstImage.ptr ~= nil and dstImage.ptr[0] or dstImage,
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		region
	)
end

function CommandBuffer:CopyBufferToImage(buffer, image, width, height, x, y, z)
	vulkan.lib.vkCmdCopyBufferToImage(
		self.ptr[0],
		buffer.ptr[0],
		image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		vulkan.vk.VkBufferImageCopy{
			bufferOffset = 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = vulkan.vk.s.ImageSubresourceLayers{
				aspectMask = "color",
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			imageOffset = vulkan.vk.VkOffset3D{x = x or 0, y = y or 0, z = z or 0},
			imageExtent = vulkan.vk.VkExtent3D{width = width, height = height, depth = 1},
		}
	)
end

function CommandBuffer:CopyBufferToImageMip(buffer, image, width, height, mip_level, buffer_offset, buffer_size)
	vulkan.lib.vkCmdCopyBufferToImage(
		self.ptr[0],
		buffer.ptr[0],
		image.ptr[0],
		vulkan.vk.e.VkImageLayout("transfer_dst_optimal"),
		1,
		vulkan.vk.VkBufferImageCopy{
			bufferOffset = buffer_offset or 0,
			bufferRowLength = 0,
			bufferImageHeight = 0,
			imageSubresource = vulkan.vk.s.ImageSubresourceLayers{
				aspectMask = "color",
				mipLevel = mip_level or 0,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			imageOffset = {x = 0, y = 0, z = 0},
			imageExtent = {width = width, height = height, depth = 1},
		}
	)
end

function CommandBuffer:BlitImage(config)
	local srcSubresource = vulkan.vk.VkImageSubresourceLayers()
	srcSubresource.aspectMask = vulkan.vk.e.VkImageAspectFlagBits("color")
	srcSubresource.mipLevel = config.src_mip_level or 0
	srcSubresource.baseArrayLayer = config.src_base_array_layer or 0
	srcSubresource.layerCount = config.src_layer_count or 1
	local dstSubresource = vulkan.vk.VkImageSubresourceLayers()
	dstSubresource.aspectMask = vulkan.vk.e.VkImageAspectFlagBits("color")
	dstSubresource.mipLevel = config.dst_mip_level or 0
	dstSubresource.baseArrayLayer = config.dst_base_array_layer or 0
	dstSubresource.layerCount = config.dst_layer_count or 1
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
