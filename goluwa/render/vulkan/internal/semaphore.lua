local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Semaphore = prototype.CreateTemplate("vulkan", "semaphore")

function Semaphore.New(device)
	local ptr = vulkan.T.Box(vulkan.vk.VkSemaphore)()
	vulkan.assert(
		vulkan.lib.vkCreateSemaphore(device.ptr[0], vulkan.vk.s.SemaphoreCreateInfo({
			flags = 0,
		}), nil, ptr),
		"failed to create semaphore"
	)
	return Semaphore:CreateObject({ptr = ptr, device = device})
end

function Semaphore:__gc()
	vulkan.lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
end

return Semaphore:Register()
