local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Buffer = {}
Buffer.__index = Buffer

function Buffer.New(device, size, usage, properties)
	usage = vulkan.enums.VK_BUFFER_USAGE_(usage)
	properties = vulkan.enums.VK_MEMORY_PROPERTY_(properties or {"host_visible", "host_coherent"})
	local bufferInfo = vulkan.vk.VkBufferCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO",
			size = size,
			usage = usage,
			sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
		}
	)
	local buffer_ptr = vulkan.T.Box(vulkan.vk.VkBuffer)()
	vulkan.assert(
		vulkan.lib.vkCreateBuffer(device.ptr[0], bufferInfo, nil, buffer_ptr),
		"failed to create buffer"
	)
	local memRequirements = vulkan.vk.VkMemoryRequirements()
	vulkan.lib.vkGetBufferMemoryRequirements(device.ptr[0], buffer_ptr[0], memRequirements)
	local allocInfo = vulkan.vk.VkMemoryAllocateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO",
			allocationSize = memRequirements.size,
			memoryTypeIndex = device.physical_device:FindMemoryType(memRequirements.memoryTypeBits, properties),
		}
	)
	local memory_ptr = vulkan.T.Box(vulkan.vk.VkDeviceMemory)()
	vulkan.assert(
		vulkan.lib.vkAllocateMemory(device.ptr[0], allocInfo, nil, memory_ptr),
		"failed to allocate buffer memory"
	)
	vulkan.lib.vkBindBufferMemory(device.ptr[0], buffer_ptr[0], memory_ptr[0], 0)
	return setmetatable(
		{
			ptr = buffer_ptr,
			memory = memory_ptr,
			size = size,
			device = device,
		},
		Buffer
	)
end

function Buffer:__gc()
	vulkan.lib.vkDestroyBuffer(self.device.ptr[0], self.ptr[0], nil)
	vulkan.lib.vkFreeMemory(self.device.ptr[0], self.memory[0], nil)
end

function Buffer:Map()
	local data = ffi.new("void*[1]")
	vulkan.lib.vkMapMemory(self.device.ptr[0], self.memory[0], 0, self.size, 0, data)
	return data[0]
end

function Buffer:Unmap()
	vulkan.lib.vkUnmapMemory(self.device.ptr[0], self.memory[0])
end

function Buffer:CopyData(src_data, size)
	local data = self:Map()
	ffi.copy(data, src_data, size or self.size)
	self:Unmap()
end

return Buffer
