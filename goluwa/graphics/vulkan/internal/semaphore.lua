local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.New(device)
	local ptr = vulkan.T.Box(vulkan.vk.VkSemaphore)()
	vulkan.assert(
		vulkan.lib.vkCreateSemaphore(device.ptr[0], vulkan.vk.s.SemaphoreCreateInfo({
			flags = 0,
		}), nil, ptr),
		"failed to create semaphore"
	)
	return setmetatable({ptr = ptr, device = device}, Semaphore)
end

function Semaphore:__gc()
	vulkan.lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
end

return Semaphore
