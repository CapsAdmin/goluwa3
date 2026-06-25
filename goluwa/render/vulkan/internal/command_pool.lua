local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local CommandPool = objects.CreateTemplate("vulkan_command_pool")
CommandPool.AllocateCommandBuffer = import("goluwa/render/vulkan/internal/command_buffer.lua").New
local VkCommandPoolBox = ffi.typeof("$[1]", vulkan.vk.VkCommandPool)

function CommandPool.New(device, graphicsQueueFamily)
	local info = vulkan.vk.s.CommandPoolCreateInfo{
		queueFamilyIndex = graphicsQueueFamily,
		flags = "reset_command_buffer",
	}
	local ptr = VkCommandPoolBox()
	vulkan.assert(
		vulkan.lib.vkCreateCommandPool(device.ptr[0], info, nil, ptr),
		"failed to create command pool"
	)
	return CommandPool:CreateObject{ptr = ptr, device = device}
end

function CommandPool:FreeCommandBuffer(cmd)
	vulkan.lib.vkFreeCommandBuffers(self.device.ptr[0], self.ptr[0], 1, cmd.ptr)
end

function CommandPool:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local pool_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyCommandPool(device_ptr, pool_ptr, nil)
		end)
	end
end

return CommandPool:Register()
