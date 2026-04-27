local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Semaphore = prototype.CreateTemplate("vulkan_semaphore")

function Semaphore.New(device)
	local ptr = vulkan.T.Box(vulkan.vk.VkSemaphore)()
	vulkan.assert(
		vulkan.lib.vkCreateSemaphore(device.ptr[0], vulkan.vk.s.SemaphoreCreateInfo{
			flags = 0,
		}, nil, ptr),
		"failed to create semaphore"
	)
	return Semaphore:CreateObject{ptr = ptr, device = device}
end

function Semaphore:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local semaphore_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroySemaphore(device_ptr, semaphore_ptr, nil)
		end)
	end
end

return Semaphore:Register()
