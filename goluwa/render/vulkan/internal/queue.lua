local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local flags = import("goluwa/flags.lua")
local Queue = prototype.CreateTemplate("vulkan_queue")

function Queue.New(device, graphicsQueueFamily)
	local ptr = vulkan.T.Box(vulkan.vk.VkQueue)()
	vulkan.lib.vkGetDeviceQueue(device.ptr[0], graphicsQueueFamily, 0, ptr)
	return Queue:CreateObject{ptr = ptr, device = device, pending_submissions = {}}
end

function Queue:OnRemove() -- Queues are managed by the device, so nothing to do here
end

function Queue:TrackSubmission(commandBuffer, fence, submissionResources)
	local serial = self.device:AllocateSubmissionSerial()
	local keepalive_resources = commandBuffer.keepalive_resources
	commandBuffer.keepalive_resources = nil
	local submission = {
		serial = serial,
		commandBuffer = commandBuffer,
		resources = submissionResources,
		keepalive_resources = keepalive_resources,
		fence = fence,
	}

	if fence then self.pending_submissions[fence] = submission end

	return submission
end

function Queue:RetireFence(fence)
	if not fence or not self.pending_submissions then return end

	local submission = self.pending_submissions[fence]

	if not submission then return end

	self.pending_submissions[fence] = nil
	self.device:MarkSubmissionCompleted(submission.serial)
end

function Queue:HasPendingSubmission(fence)
	return fence ~= nil and
		self.pending_submissions ~= nil and
		self.pending_submissions[fence] ~= nil
end

function Queue:Submit(commandBuffer, imageAvailableSemaphore, renderFinishedSemaphore, inFlightFence)
	if flags.render_noop then
		local submission = self:TrackSubmission(
			commandBuffer,
			inFlightFence,
			{imageAvailableSemaphore, renderFinishedSemaphore}
		)
		self:RetireFence(submission.fence)
		return
	end

	local waitStages = ffi.new("uint32_t[1]", vulkan.vk.e.VkPipelineStageFlagBits("color_attachment_output"))
	local submitInfo = vulkan.vk.s.SubmitInfo{
		waitSemaphoreCount = 1,
		pWaitSemaphores = imageAvailableSemaphore.ptr,
		pWaitDstStageMask = waitStages,
		commandBufferCount = 1,
		pCommandBuffers = commandBuffer.ptr,
		signalSemaphoreCount = 1,
		pSignalSemaphores = renderFinishedSemaphore.ptr,
	}
	vulkan.assert(
		vulkan.lib.vkQueueSubmit(self.ptr[0], 1, submitInfo, inFlightFence.ptr[0]),
		"failed to submit queue"
	)
	self:TrackSubmission(commandBuffer, inFlightFence, {imageAvailableSemaphore, renderFinishedSemaphore})
end

function Queue:SubmitNoWait(device, commandBuffer, fence)
	if flags.render_noop then
		self:RetireFence(self:TrackSubmission(commandBuffer, fence, {}).fence)
		return
	end

	local submission = self:TrackSubmission(commandBuffer, fence, {})
	vulkan.lib.vkResetFences(device.ptr[0], 1, fence.ptr)
	vulkan.assert(
		vulkan.lib.vkQueueSubmit(
			self.ptr[0],
			1,
			vulkan.vk.s.SubmitInfo{
				waitSemaphoreCount = 0,
				pWaitSemaphores = nil,
				pWaitDstStageMask = nil,
				commandBufferCount = 1,
				pCommandBuffers = commandBuffer.ptr,
				signalSemaphoreCount = 0,
				pSignalSemaphores = nil,
			},
			fence.ptr[0]
		),
		"failed to submit queue"
	)
	return submission
end

function Queue:SubmitAndWait(device, commandBuffer, fence)
	if flags.render_noop then
		local submission = self:TrackSubmission(commandBuffer, fence, {})

		if commandBuffer then
			commandBuffer.keepalive_resources = nil
			commandBuffer.is_recording = false
			commandBuffer.is_rendering = false
		end

		self:RetireFence(submission.fence)
		return
	end

	local submission = self:TrackSubmission(commandBuffer, fence, {})
	vulkan.lib.vkResetFences(device.ptr[0], 1, fence.ptr)
	vulkan.assert(
		vulkan.lib.vkQueueSubmit(
			self.ptr[0],
			1,
			vulkan.vk.s.SubmitInfo{
				waitSemaphoreCount = 0,
				pWaitSemaphores = nil,
				pWaitDstStageMask = nil,
				commandBufferCount = 1,
				pCommandBuffers = commandBuffer.ptr,
				signalSemaphoreCount = 0,
				pSignalSemaphores = nil,
			},
			fence.ptr[0]
		),
		"failed to submit queue"
	)
	vulkan.lib.vkWaitForFences(device.ptr[0], 1, fence.ptr, 1, ffi.cast("uint64_t", -1))
	self:RetireFence(submission.fence)
end

return Queue:Register()
