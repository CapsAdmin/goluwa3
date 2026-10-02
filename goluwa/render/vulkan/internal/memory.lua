local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Memory = objects.CreateTemplate("vulkan_memory")
local callstack = import("goluwa/debug/callstack.lua")
local VkDeviceMemoryBox = ffi.typeof("$[1]", vulkan.vk.VkDeviceMemory)
Memory.total_freed_count = Memory.total_freed_count or 0
Memory.total_freed_bytes = Memory.total_freed_bytes or 0
-- bytes of removed allocations the device still holds until the submissions
-- that may use them are done
Memory.pending_release_bytes = Memory.pending_release_bytes or 0
-- the same by debug name, to see what is waiting
Memory.pending_release_by_name = Memory.pending_release_by_name or {}
vulkan.SetupDebugFunctions(Memory, vulkan.vk.VkObjectType.VK_OBJECT_TYPE_DEVICE_MEMORY)

function Memory.New(device, config)
	local ptr = VkDeviceMemoryBox()
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

	local result = vulkan.lib.vkAllocateMemory(device.ptr[0], allocate_info, nil, ptr)

	if result ~= 0 then
		local live = 0
		local by_type = {}

		for _, memory in pairs(Memory.Instances) do
			if memory:IsValid() then
				live = live + tonumber(memory.size)
				by_type[memory.type_index] = (by_type[memory.type_index] or 0) + tonumber(memory.size)
			end
		end

		local types = {}

		for index, bytes in pairs(by_type) do
			types[#types + 1] = string.format("type %d: %.2f GiB", index, bytes / 1073741824)
		end

		table.sort(types)
		msg = string.format(
			"%s (type %d requested; %.2f GiB live [%s], %.2f GiB awaiting release)",
			msg,
			config.type_index,
			live / 1073741824,
			table.concat(types, ", "),
			Memory.pending_release_bytes / 1073741824
		)
	end

	vulkan.assert(result, msg)
	return Memory:CreateObject{
		ptr = ptr,
		device = device,
		size = config.size,
		type_index = config.type_index,
	}
end

function Memory:OnRemove()
	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local memory_ptr = self.ptr[0]
		self.ptr[0] = nil
		local size = tonumber(self.size) or 0
		Memory.pending_release_bytes = Memory.pending_release_bytes + size
		local name = self.debug_name or "(unnamed)"
		local pending = Memory.pending_release_by_name
		pending[name] = (pending[name] or 0) + size

		device:DeferRelease(function()
			vulkan.lib.vkFreeMemory(device_ptr, memory_ptr, nil)
			Memory.pending_release_bytes = Memory.pending_release_bytes - size
			pending[name] = pending[name] - size

			if pending[name] == 0 then pending[name] = nil end

			Memory.total_freed_count = (Memory.total_freed_count or 0) + 1
			Memory.total_freed_bytes = (Memory.total_freed_bytes or 0) + (tonumber(self.size) or 0)
		end)
	end
end

return Memory:Register()
