local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Fence = prototype.CreateTemplate("vulkan", "fence")

function Fence.New(device)
	local fenceCreateInfo = vulkan.vk.s.FenceCreateInfo({
		flags = "signaled",
	})
	local ptr = vulkan.T.Box(vulkan.vk.VkFence)()
	vulkan.assert(
		vulkan.lib.vkCreateFence(device.ptr[0], fenceCreateInfo, nil, ptr),
		"failed to create fence"
	)
	return Fence:CreateObject({ptr = ptr, device = device})
end

function Fence:OnRemove()
	vulkan.lib.vkDestroyFence(self.device.ptr[0], self.ptr[0], nil)
end

function Fence:Wait(skip_reset)
	vulkan.lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))

	if not skip_reset then
		vulkan.lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
	end
end

return Fence:Register()
