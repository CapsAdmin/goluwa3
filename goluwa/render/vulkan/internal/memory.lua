local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Memory = prototype.CreateTemplate("vulkan", "memory")

function Memory.New(device, config)
	local ptr = vulkan.T.Box(vulkan.vk.VkDeviceMemory)()
	local allocate_info = vulkan.vk.s.MemoryAllocateInfo({
		allocationSize = config.size,
		memoryTypeIndex = config.type_index,
	})

	if config.flags then
		allocate_info.pNext = vulkan.vk.s.MemoryAllocateFlagsInfo({
			flags = config.flags,
			deviceMask = 0,
		})
	end

	vulkan.assert(
		vulkan.lib.vkAllocateMemory(device.ptr[0], allocate_info, nil, ptr),
		"failed to allocate memory"
	)
	return Memory:CreateObject({
		ptr = ptr,
		device = device,
	})
end

function Memory:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkFreeMemory(self.device.ptr[0], self.ptr[0], nil)
	end
end

return Memory:Register()
