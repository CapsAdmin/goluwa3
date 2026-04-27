local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Queue = prototype.CreateTemplate("vulkan_queue")

local function append_resource(resources, resource)
	if resource ~= nil then resources[#resources + 1] = resource end
end

local function capture_submission_resources(commandBuffer, ...)
	local resources = {}
	append_resource(resources, commandBuffer)

	for i = 1, select("#", ...) do
		append_resource(resources, select(i, ...))
	end

	for _, resource in ipairs(commandBuffer.keepalive_resources or {}) do
		resources[#resources + 1] = resource
	end

	commandBuffer.keepalive_resources = nil
	return resources
end

function Queue.New(device, graphicsQueueFamily)
	local ptr = vulkan.T.Box(vulkan.vk.VkQueue)()
	vulkan.lib.vkGetDeviceQueue(device.ptr[0], graphicsQueueFamily, 0, ptr)
	return Queue:CreateObject{ptr = ptr, device = device, pending_submissions = {}}
end

function Queue:OnRemove() -- Queues are managed by the device, so nothing to do here
end

function Queue:TrackSubmission(commandBuffer, fence, ...)
	local serial = self.device:AllocateSubmissionSerial()
	local submission = {
		serial = serial,
		resources = capture_submission_resources(commandBuffer, fence, ...),
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

function Queue:Submit(commandBuffer, imageAvailableSemaphore, renderFinishedSemaphore, inFlightFence)
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
	self:TrackSubmission(commandBuffer, inFlightFence, imageAvailableSemaphore, renderFinishedSemaphore)
end

function Queue:SubmitAndWait(device, commandBuffer, fence)
	local submission = self:TrackSubmission(commandBuffer, fence)
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
