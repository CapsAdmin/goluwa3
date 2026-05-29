local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Memory = prototype.CreateTemplate("vulkan_memory")
local callstack = import("goluwa/helpers/callstack.lua")
Memory.total_freed_count = Memory.total_freed_count or 0
Memory.total_freed_bytes = Memory.total_freed_bytes or 0
vulkan.SetupDebugFunctions(Memory, vulkan.vk.VkObjectType.VK_OBJECT_TYPE_DEVICE_MEMORY)

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
		size = config.size,
	}
end

function Memory:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local memory_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkFreeMemory(device_ptr, memory_ptr, nil)
			Memory.total_freed_count = (Memory.total_freed_count or 0) + 1
			Memory.total_freed_bytes = (Memory.total_freed_bytes or 0) + (tonumber(self.size) or 0)
		end)
	end
end

return Memory:Register()
