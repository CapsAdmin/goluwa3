local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Memory = require("render.vulkan.internal.memory")
local Buffer = prototype.CreateTemplate("vulkan_buffer")

function Buffer.New(config)
	local device = config.device
	local size = config.size
	assert(size > 0, "buffer size must be greater than 0")
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
	local self = Buffer:CreateObject({
		ptr = ptr,
		size = size,
		device = device,
	})
	local requirements = device:GetBufferMemoryRequirements(self)
	local allocate_flags

	if type(usage) == "table" then
		for _, u in ipairs(usage) do
			if u == "shader_device_address" then
				allocate_flags = allocate_flags or {}
				table.insert(allocate_flags, "device_address")

				break
			end
		end
	end

	self.memory = Memory.New(
		device,
		{
			size = requirements.size,
			type_index = device.physical_device:FindMemoryType(requirements.memoryTypeBits, properties or {"host_visible", "host_coherent"}),
			flags = allocate_flags,
		}
	)
	self:BindMemory()
	return self
end

function Buffer:OnRemove()
	if self.device:IsValid() then
		self.device:WaitIdle()
		vulkan.lib.vkDestroyBuffer(self.device.ptr[0], self.ptr[0], nil)
	end
end

function Buffer:BindMemory()
	vulkan.assert(
		vulkan.lib.vkBindBufferMemory(self.device.ptr[0], self.ptr[0], self.memory.ptr[0], 0),
		"failed to bind image memory"
	)
end

function Buffer:GetDeviceAddress()
	if not vulkan.lib.vkGetBufferDeviceAddress then return 0 end

	local info = vulkan.vk.VkBufferDeviceAddressInfo(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
			buffer = self.ptr[0],
		}
	)
	return vulkan.lib.vkGetBufferDeviceAddress(self.device.ptr[0], info)
end

function Buffer:Map(offset, size)
	local data = ffi.new("void*[1]")
	vulkan.lib.vkMapMemory(self.device.ptr[0], self.memory.ptr[0], offset or 0, size or self.size, 0, data)
	return data[0]
end

function Buffer:Unmap()
	vulkan.lib.vkUnmapMemory(self.device.ptr[0], self.memory.ptr[0])
end

function Buffer:CopyData(src_data, size, offset)
	local data = self:Map(offset or 0, size or self.size)
	ffi.copy(data, src_data, size or self.size)
	self:Unmap()
end

return Buffer:Register()
