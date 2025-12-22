local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local CommandPool = {}
CommandPool.__index = CommandPool
CommandPool.AllocateCommandBuffer = require("graphics.vulkan.internal.command_buffer").New

function CommandPool.New(device, graphicsQueueFamily)
	local info = vulkan.vk.s.CommandPoolCreateInfo(
		{
			queueFamilyIndex = graphicsQueueFamily,
			flags = "reset_command_buffer",
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkCommandPool)()
	vulkan.assert(
		vulkan.lib.vkCreateCommandPool(device.ptr[0], info, nil, ptr),
		"failed to create command pool"
	)
	return setmetatable({ptr = ptr, device = device}, CommandPool)
end

function CommandPool:FreeCommandBuffer(cmd)
	vulkan.lib.vkFreeCommandBuffers(self.device.ptr[0], self.ptr[0], 1, cmd.ptr)
end

function CommandPool:__gc()
	vulkan.lib.vkDestroyCommandPool(self.device.ptr[0], self.ptr[0], nil)
end

return CommandPool
