local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Fence = {}
Fence.__index = Fence

function Fence.New(device)
	local fenceCreateInfo = vulkan.vk.VkFenceCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_FENCE_CREATE_INFO",
			flags = vulkan.vk.VkFenceCreateFlagBits("VK_FENCE_CREATE_SIGNALED_BIT"),
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkFence)()
	vulkan.assert(
		vulkan.lib.vkCreateFence(device.ptr[0], fenceCreateInfo, nil, ptr),
		"failed to create fence"
	)
	return setmetatable({ptr = ptr, device = device}, Fence)
end

function Fence:__gc()
	vulkan.lib.vkDestroyFence(self.device.ptr[0], self.ptr[0], nil)
end

function Fence:Wait()
	vulkan.lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))
	vulkan.lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
end

return Fence
