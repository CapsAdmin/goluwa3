local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.New(device)
	local semaphoreCreateInfo = vulkan.vk.VkSemaphoreCreateInfo({
		sType = "VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO",
		flags = 0,
	})
	local ptr = vulkan.T.Box(vulkan.vk.VkSemaphore)()
	vulkan.assert(
		vulkan.lib.vkCreateSemaphore(device.ptr[0], semaphoreCreateInfo, nil, ptr),
		"failed to create semaphore"
	)
	return setmetatable({ptr = ptr, device = device}, Semaphore)
end

function Semaphore:__gc()
	vulkan.lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
end

return Semaphore
