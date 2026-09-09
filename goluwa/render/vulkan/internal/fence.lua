local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Fence = objects.CreateTemplate("vulkan_fence")
local VkFenceBox = ffi.typeof("$[1]", vulkan.vk.VkFence)

function Fence.New(device)
	local fenceCreateInfo = vulkan.vk.s.FenceCreateInfo{
		flags = "signaled",
	}
	local ptr = VkFenceBox()
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

do
	local max= ffi.cast("uint64_t", -1)

	function Fence:Wait()
		vulkan.lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, max)
	end
end

function Fence:IsSignaled()
	local result = vulkan.lib.vkGetFenceStatus(self.device.ptr[0], self.ptr[0])

	if result == vulkan.vk.VkResult.VK_SUCCESS then return true end

	if result == vulkan.vk.VkResult.VK_NOT_READY then return false end

	vulkan.assert(result, "failed to query fence status")
	return false
end

return Fence:Register()
