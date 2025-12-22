local ffi = require("ffi")
local vulkan = require("render.vulkan.internal.vulkan")
local Queue = {}
Queue.__index = Queue

function Queue.New(device, graphicsQueueFamily)
	local ptr = vulkan.T.Box(vulkan.vk.VkQueue)()
	vulkan.lib.vkGetDeviceQueue(device.ptr[0], graphicsQueueFamily, 0, ptr)
	return setmetatable({ptr = ptr, device = device}, Queue)
end

function Queue:__gc() -- Queues are managed by the device, so nothing to do here
end

function Queue:Submit(commandBuffer, imageAvailableSemaphore, renderFinishedSemaphore, inFlightFence)
	local waitStages = ffi.new("uint32_t[1]", vulkan.vk.e.VkPipelineStageFlagBits("color_attachment_output"))
	local submitInfo = vulkan.vk.s.SubmitInfo(
		{
			waitSemaphoreCount = 1,
			pWaitSemaphores = imageAvailableSemaphore.ptr,
			pWaitDstStageMask = waitStages,
			commandBufferCount = 1,
			pCommandBuffers = commandBuffer.ptr,
			signalSemaphoreCount = 1,
			pSignalSemaphores = renderFinishedSemaphore.ptr,
		}
	)
	vulkan.assert(
		vulkan.lib.vkQueueSubmit(self.ptr[0], 1, submitInfo, inFlightFence.ptr[0]),
		"failed to submit queue"
	)
end

function Queue:SubmitAndWait(device, commandBuffer, fence)
	vulkan.lib.vkResetFences(device.ptr[0], 1, fence.ptr)
	vulkan.assert(
		vulkan.lib.vkQueueSubmit(
			self.ptr[0],
			1,
			vulkan.vk.s.SubmitInfo(
				{
					waitSemaphoreCount = 0,
					pWaitSemaphores = nil,
					pWaitDstStageMask = nil,
					commandBufferCount = 1,
					pCommandBuffers = commandBuffer.ptr,
					signalSemaphoreCount = 0,
					pSignalSemaphores = nil,
				}
			),
			fence.ptr[0]
		),
		"failed to submit queue"
	)
	vulkan.lib.vkWaitForFences(device.ptr[0], 1, fence.ptr, 1, ffi.cast("uint64_t", -1))
end

return Queue
