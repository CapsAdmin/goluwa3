local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Memory = prototype.CreateTemplate("vulkan", "memory")

function Memory.New(device, size, type_index)
	local ptr = vulkan.T.Box(vulkan.vk.VkDeviceMemory)()
	vulkan.assert(
		vulkan.lib.vkAllocateMemory(
			device.ptr[0],
			vulkan.vk.s.MemoryAllocateInfo({
				allocationSize = size,
				memoryTypeIndex = type_index,
			}),
			nil,
			ptr
		),
		"failed to allocate memory"
	)
	return Memory:CreateObject({
		ptr = ptr,
		device = device,
	})
end

function Memory:__gc()
	vulkan.lib.vkFreeMemory(self.device.ptr[0], self.ptr[0], nil)
end

return Memory:Register()
