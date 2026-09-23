local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local AccelerationStructure = objects.CreateTemplate("vulkan_acceleration_structure")
local VkAccelerationStructureBox = ffi.typeof("$[1]", vulkan.vk.VkAccelerationStructureKHR)
local VkBuildRangeInfoArray = ffi.typeof("$[?]", vulkan.vk.VkAccelerationStructureBuildRangeInfoKHR)
local VkRangePointerArray = ffi.typeof("void*[?]")
local VkRangePointerPtr = ffi.typeof("const $**", vulkan.vk.VkAccelerationStructureBuildRangeInfoKHR)
local VkBuildInfoArray = ffi.typeof("$[1]", vulkan.vk.VkAccelerationStructureBuildGeometryInfoKHR)

local function devaddr(address)
	local u = ffi.new(vulkan.vk.VkDeviceOrHostAddressConstKHR)
	u.deviceAddress = address
	return u
end

local function scratchaddr(address)
	local u = ffi.new(vulkan.vk.VkDeviceOrHostAddressKHR)
	u.deviceAddress = address
	return u
end

local as_types = {top_level_khr = 0, bottom_level_khr = 1, generic_khr = 2}

local function as_type(type)
	return as_types[type]
end

function AccelerationStructure.QueryBuildSize(device, build_info)
	local build_sizes = device:TryGetExtension("vkGetAccelerationStructureBuildSizesKHR")
	local sizes = ffi.new(vulkan.vk.VkAccelerationStructureBuildSizesInfoKHR)
	sizes.sType = 1000150020
	local info = vulkan.vk.s.AccelerationStructureBuildGeometryInfoKHR{
		sType = 1000150000,
		pNext = nil,
		type = as_type(build_info.type),
		flags = build_info.flags or 0,
		mode = 0,
		srcAccelerationStructure = nil,
		dstAccelerationStructure = nil,
		geometryCount = build_info.geometryCount,
		pGeometries = build_info.pGeometries,
		ppGeometries = nil,
		scratchData = scratchaddr(0),
	}
	local max_prims = ffi.new("uint32_t[1]", build_info.maxPrimitiveCount or 1)
	build_sizes(device.ptr[0], 1, info, max_prims, sizes)
	return tonumber(sizes.accelerationStructureSize),
	tonumber(sizes.buildScratchSize)
end

function AccelerationStructure.New(device, type, buffer)
	local create_as = device:GetExtension("vkCreateAccelerationStructureKHR")
	local ptr = VkAccelerationStructureBox()
	vulkan.assert(
		create_as(
			device.ptr[0],
			vulkan.vk.s.AccelerationStructureCreateInfoKHR{
				sType = 1000150017,
				pNext = nil,
				createFlags = 0,
				buffer = buffer and buffer.ptr[0] or nil,
				offset = 0,
				size = buffer and buffer.size or 0,
				type = as_types[type],
				deviceAddress = 0,
			},
			nil,
			ptr
		),
		"failed to create acceleration structure"
	)
	return AccelerationStructure:CreateObject{
		ptr = ptr,
		device = device,
		type = as_types[type],
		buffer = buffer,
		size = buffer and buffer.size or 0,
		create_as = create_as,
		destroy_as = device:GetExtension("vkDestroyAccelerationStructureKHR"),
		get_as_address = device:TryGetExtension("vkGetAccelerationStructureDeviceAddressKHR"),
		cmd_build = device:TryGetExtension("vkCmdBuildAccelerationStructuresKHR"),
	}
end

function AccelerationStructure:Data()
	local get_address = self.get_as_address

	if get_address then
		local info = vulkan.vk.s.AccelerationStructureDeviceAddressInfoKHR()
		info.sType = 1000150002
		info.pNext = nil
		info.accelerationStructure = self.ptr[0]
		return get_address(self.device.ptr[0], info)
	end

	if self.buffer then return self.buffer:GetDeviceAddress() end

	return 0
end

function AccelerationStructure:Build(cmd, geometry_count, geometry_ptr, ranges, flags)
	local range_arrays = {}

	for i = 1, geometry_count do
		local arr = VkBuildRangeInfoArray(1)
		arr[0] = ranges[i - 1]
		range_arrays[i] = arr
	end

	local range_pointers = VkRangePointerArray(geometry_count)

	for i = 1, geometry_count do
		range_pointers[i - 1] = range_arrays[i]
	end

	local info = VkBuildInfoArray()
	info[0] = vulkan.vk.s.AccelerationStructureBuildGeometryInfoKHR{
		sType = 1000150000,
		pNext = nil,
		type = self.type,
		flags = flags or 0,
		mode = 0,
		srcAccelerationStructure = nil,
		dstAccelerationStructure = self.ptr[0],
		geometryCount = geometry_count,
		pGeometries = geometry_ptr,
		ppGeometries = nil,
		scratchData = scratchaddr(self.scratch_data),
	}
	self.cmd_build(cmd.ptr[0], 1, info[0], ffi.cast(VkRangePointerPtr, range_pointers))
end

function AccelerationStructure:EnsureScratch(size)
	if not size or size <= 0 then
		self.scratch = nil
		self.scratch_data = 0
		return 0
	end

	if self.scratch and self.scratch_size >= size then
		return self.scratch_data
	end

	if self.scratch then
		self.scratch:Remove()
		self.scratch = nil
	end

	self.scratch = Buffer.New{
		device = self.device,
		size = size,
		usage = {"shader_device_address", "storage_buffer"},
		properties = {"device_local"},
		label = "acceleration_structure_scratch_" .. self.type,
	}
	self.scratch_size = size
	self.scratch_data = self.scratch:GetDeviceAddress()
	return self.scratch_data
end

function AccelerationStructure:OnRemove()
	if self.scratch then
		self.scratch:Remove()
		self.scratch = nil
		self.scratch_data = 0
	end

	if self.ptr[0] and self.device:IsValid() then
		local device = self.device
		local ptr = self.ptr[0]
		local destroy_as = self.destroy_as
		self.ptr[0] = nil

		device:DeferRelease(function()
			destroy_as(device.ptr[0], ptr, nil)
		end)
	end
end

return AccelerationStructure:Register()
