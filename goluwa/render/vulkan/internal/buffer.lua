local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Memory = import("goluwa/render/vulkan/internal/memory.lua")
local Buffer = objects.CreateTemplate("vulkan_buffer")
local VkBufferBox = ffi.typeof("$[1]", vulkan.vk.VkBuffer)
-- bumped whenever a buffer whose device address was handed out goes away, so
-- tables of addresses know when they may point at a destroyed buffer
Buffer.address_release_serial = 0

local function build_buffer_memory_name(name)
	if not name or name == "" then return nil end

	return name .. " memory"
end

vulkan.SetupDebugFunctions(
	Buffer,
	vulkan.vk.VkObjectType.VK_OBJECT_TYPE_BUFFER,
	{
		onSetDebugName = function(self, name)
			if self.memory and self.memory.SetDebugName then
				self.memory:SetDebugName(build_buffer_memory_name(name))
			end
		end,
		onSetObjectTag = function(self, key, value)
			if self.memory and self.memory.SetObjectTag then
				self.memory:SetObjectTag(key, value)
			end
		end,
	}
)

-- buffers that ask for plain host visible memory get the gpu's own where the
-- device has a big enough host visible heap of it, see FindFastHostMemoryType
local MIN_FAST_HEAP_SIZE = 2 ^ 30

local function is_plain_host_memory(properties)
	if not properties then return true end

	if type(properties) ~= "table" or #properties ~= 2 then return false end

	local visible, coherent

	for _, name in ipairs(properties) do
		visible = visible or name == "host_visible"
		coherent = coherent or name == "host_coherent"
	end

	return visible and coherent
end

function Buffer.New(config)
	local device = config.device
	local size = config.size
	assert(size > 0, "buffer size must be greater than 0")
	local usage = config.usage
	local properties = config.properties
	local ptr = VkBufferBox()
	vulkan.assert(
		vulkan.lib.vkCreateBuffer(
			device.ptr[0],
			vulkan.vk.s.BufferCreateInfo{
				flags = 0,
				size = size,
				usage = usage,
				sharingMode = "exclusive",
				queueFamilyIndexCount = 0,
				pQueueFamilyIndices = nil,
			},
			nil,
			ptr
		),
		"failed to create buffer"
	)
	local self = Buffer:CreateObject{
		ptr = ptr,
		size = size,
		device = device,
		mapped_data = nil,
	}
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

	local fast_type

	if is_plain_host_memory(properties) then
		fast_type = device.physical_device:FindFastHostMemoryType(requirements.memoryTypeBits, MIN_FAST_HEAP_SIZE)
	end

	if fast_type then
		local ok, memory = pcall(
			Memory.New,
			device,
			{size = requirements.size, type_index = fast_type, flags = allocate_flags}
		)

		if ok then self.memory = memory end
	end

	if not self.memory then
		self.memory = Memory.New(
			device,
			{
				size = requirements.size,
				type_index = device.physical_device:FindMemoryType(requirements.memoryTypeBits, properties or {"host_visible", "host_coherent"}),
				flags = allocate_flags,
			}
		)
	end

	self:BindMemory()
	return self
end

function Buffer:GetSize()
	return self.size
end

function Buffer:OnRemove()
	if self.device_address then
		Buffer.address_release_serial = Buffer.address_release_serial + 1
	end

	if
		self.mapped_data and
		self.device:IsValid() and
		self.memory and
		self.memory:IsValid()
	then
		vulkan.lib.vkUnmapMemory(self.device.ptr[0], self.memory.ptr[0])
		self.mapped_data = nil
	end

	if self.device:IsValid() then
		local device = self.device
		local device_ptr = device.ptr[0]
		local buffer_ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyBuffer(device_ptr, buffer_ptr, nil)
		end)
	end

	if self.memory and self.memory:IsValid() then
		self.memory:Remove()
		self.memory = nil
	end
end

function Buffer:BindMemory()
	vulkan.assert(
		vulkan.lib.vkBindBufferMemory(self.device.ptr[0], self.ptr[0], self.memory.ptr[0], 0),
		"failed to bind image memory"
	)
end

-- a buffer's address is fixed for its lifetime
function Buffer:GetDeviceAddress()
	local address = self.device_address

	if address then return address end

	if not vulkan.lib.vkGetBufferDeviceAddress then return 0 end

	local info = vulkan.vk.VkBufferDeviceAddressInfo{
		sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
		buffer = self.ptr[0],
	}
	address = vulkan.lib.vkGetBufferDeviceAddress(self.device.ptr[0], info)
	self.device_address = address
	return address
end

function Buffer:Map(offset, size)
	if not self.mapped_data then
		local data = ffi.new("void*[1]")
		vulkan.lib.vkMapMemory(self.device.ptr[0], self.memory.ptr[0], 0, self.size, 0, data)
		self.mapped_data = ffi.cast("uint8_t *", data[0])
	end

	if offset and offset ~= 0 then return self.mapped_data + offset end

	return self.mapped_data
end

function Buffer:Unmap()
	if self.mapped_data then
		vulkan.lib.vkUnmapMemory(self.device.ptr[0], self.memory.ptr[0])
		self.mapped_data = nil
	end
end

function Buffer:CopyData(src_data, size, offset)
	size = size or self.size
	local data = self:Map(offset or 0, size)
	ffi.copy(data, src_data, size)
	self:Unmap()

	if render.stats then render_stats.AddUploadedBytes(size) end
end

return Buffer:Register()
