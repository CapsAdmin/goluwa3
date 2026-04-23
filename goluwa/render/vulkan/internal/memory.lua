local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Memory = prototype.CreateTemplate("vulkan_memory")

function Memory.New(device, config)
	local ptr = vulkan.T.Box(vulkan.vk.VkDeviceMemory)()
	local allocate_info = vulkan.vk.s.MemoryAllocateInfo{
		allocationSize = config.size,
		memoryTypeIndex = config.type_index,
	}

	if config.flags then
		allocate_info.pNext = vulkan.vk.s.MemoryAllocateFlagsInfo{
			flags = config.flags,
			deviceMask = 0,
		}
	end

	local msg = "failed to allocate memory"

	if config.label then msg = msg .. " for " .. config.label end

	vulkan.assert(vulkan.lib.vkAllocateMemory(device.ptr[0], allocate_info, nil, ptr), msg)
	return Memory:CreateObject{
		ptr = ptr,
		device = device,
	}
end

function Memory:OnRemove()
	if self.device:IsValid() then
		local device_ptr = self.device.ptr[0]
		local memory_ptr = self.ptr[0]
		self.ptr[0] = nil
		self.device:WaitIdle()
		vulkan.lib.vkFreeMemory(device_ptr, memory_ptr, nil)
	end
end

return Memory:Register()
