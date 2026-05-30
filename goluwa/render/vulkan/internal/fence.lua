local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Fence = prototype.CreateTemplate("vulkan_fence")

function Fence.New(device)
	local fenceCreateInfo = vulkan.vk.s.FenceCreateInfo{
		flags = "signaled",
	}
	local ptr = vulkan.T.Box(vulkan.vk.VkFence)()
	vulkan.assert(
		vulkan.lib.vkCreateFence(device.ptr[0], fenceCreateInfo, nil, ptr),
		"failed to create fence"
	)
	return Fence:CreateObject{ptr = ptr, device = device}
end

function Fence:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local fence_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyFence(device_ptr, fence_ptr, nil)
		end)
	end
end

function Fence:Reset()
	vulkan.lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
end

function Fence:Wait(skip_reset)
	vulkan.lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))

	if not skip_reset then self:Reset() end
end

function Fence:IsSignaled()
	local result = vulkan.lib.vkGetFenceStatus(self.device.ptr[0], self.ptr[0])

	if result == vulkan.vk.VkResult.VK_SUCCESS then return true end

	if result == vulkan.vk.VkResult.VK_NOT_READY then return false end

	vulkan.assert(result, "failed to query fence status")
	return false
end

return Fence:Register()
