local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Memory = require("graphics.vulkan.internal.memory")
local Buffer = {}
Buffer.__index = Buffer

function Buffer.New(config)
	local device = config.device
	local size = config.size
	local usage = config.usage
	local properties = config.properties
	local ptr = vulkan.T.Box(vulkan.vk.VkBuffer)()
	vulkan.assert(
		vulkan.lib.vkCreateBuffer(
			device.ptr[0],
			vulkan.vk.s.BufferCreateInfo(
				{
					flags = 0,
					size = size,
					usage = usage,
					sharingMode = "exclusive",
					queueFamilyIndexCount = 0,
					pQueueFamilyIndices = nil,
				}
			),
			nil,
			ptr
		),
		"failed to create buffer"
	)
	local self = setmetatable({
		ptr = ptr,
		size = size,
		device = device,
	}, Buffer)
	local requirements = device:GetBufferMemoryRequirements(self)
	self.memory = Memory.New(
		device,
		requirements.size,
		device.physical_device:FindMemoryType(requirements.memoryTypeBits, properties or {"host_visible", "host_coherent"})
	)
	self:BindMemory()
	return self
end

function Buffer:__gc()
	vulkan.lib.vkDestroyBuffer(self.device.ptr[0], self.ptr[0], nil)
end

function Buffer:BindMemory()
	vulkan.assert(
		vulkan.lib.vkBindBufferMemory(self.device.ptr[0], self.ptr[0], self.memory.ptr[0], 0),
		"failed to bind image memory"
	)
end

function Buffer:Map()
	local data = ffi.new("void*[1]")
	vulkan.lib.vkMapMemory(self.device.ptr[0], self.memory.ptr[0], 0, self.size, 0, data)
	return data[0]
end

function Buffer:Unmap()
	vulkan.lib.vkUnmapMemory(self.device.ptr[0], self.memory.ptr[0])
end

function Buffer:CopyData(src_data, size)
	local data = self:Map()
	ffi.copy(data, src_data, size or self.size)
	self:Unmap()
end

return Buffer
