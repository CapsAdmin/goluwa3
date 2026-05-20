local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Memory = import("goluwa/render/vulkan/internal/memory.lua")
local Buffer = prototype.CreateTemplate("vulkan_buffer")

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

function Buffer:GetDeviceAddress()
	if not vulkan.lib.vkGetBufferDeviceAddress then return 0 end

	local info = vulkan.vk.VkBufferDeviceAddressInfo{
		sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
		buffer = self.ptr[0],
	}
	return vulkan.lib.vkGetBufferDeviceAddress(self.device.ptr[0], info)
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
	return
end

function Buffer:CopyData(src_data, size, offset)
	size = size or self.size
	local data = self:Map(offset or 0, size)
	ffi.copy(data, src_data, size)
	self:Unmap()

	if render.stats then render_stats.AddUploadedBytes(size) end
end

return Buffer:Register()
