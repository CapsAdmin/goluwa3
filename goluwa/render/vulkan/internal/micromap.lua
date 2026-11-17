local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local vk = vulkan.vk
local Micromap = objects.CreateTemplate("vulkan_micromap")
local MicromapBox = ffi.typeof("$[1]", vk.VkMicromapEXT)
local BuildInfoBox = ffi.typeof("$[1]", vk.VkMicromapBuildInfoEXT)
local UsageBox = ffi.typeof("$[1]", vk.VkMicromapUsageEXT)
local TYPE_OPACITY = 0
local BUILD_TYPE_DEVICE = 1
Micromap.FORMAT_2_STATE = 1
Micromap.FORMAT_4_STATE = 2
Micromap.STATE_TRANSPARENT = 0
Micromap.STATE_OPAQUE = 1
Micromap.STATE_UNKNOWN_TRANSPARENT = 2
Micromap.STATE_UNKNOWN_OPAQUE = 3

local function get_build_info(micromap, usage, scratch_address, data_address, triangle_address)
	local info = BuildInfoBox()
	info[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_MICROMAP_BUILD_INFO_EXT
	info[0].pNext = nil
	info[0].type = TYPE_OPACITY
	info[0].flags = 0
	info[0].mode = 0
	info[0].dstMicromap = micromap
	info[0].usageCountsCount = 1
	info[0].pUsageCounts = usage
	info[0].ppUsageCounts = nil
	info[0].data.deviceAddress = data_address or 0
	info[0].scratchData.deviceAddress = scratch_address or 0
	info[0].triangleArray.deviceAddress = triangle_address or 0
	info[0].triangleArrayStride = 8
	return info
end

function Micromap.GetUsage(triangle_count, subdivision_level, format)
	local usage = UsageBox()
	usage[0].count = triangle_count
	usage[0].subdivisionLevel = subdivision_level
	usage[0].format = format
	return usage
end

function Micromap.QueryBuildSize(device, usage)
	local sizes = ffi.new(vk.VkMicromapBuildSizesInfoEXT)
	sizes.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_MICROMAP_BUILD_SIZES_INFO_EXT
	local info = get_build_info(nil, usage)
	device:GetExtension("vkGetMicromapBuildSizesEXT")(device.ptr[0], BUILD_TYPE_DEVICE, info, sizes)
	return tonumber(sizes.micromapSize), tonumber(sizes.buildScratchSize)
end

function Micromap.New(device, buffer, size)
	local ptr = MicromapBox()
	vulkan.assert(
		device:GetExtension("vkCreateMicromapEXT")(
			device.ptr[0],
			vk.s.MicromapCreateInfoEXT{
				sType = vk.VkStructureType.VK_STRUCTURE_TYPE_MICROMAP_CREATE_INFO_EXT,
				pNext = nil,
				createFlags = 0,
				buffer = buffer.ptr[0],
				offset = 0,
				size = size,
				type = TYPE_OPACITY,
				deviceAddress = 0,
			},
			nil,
			ptr
		),
		"failed to create micromap"
	)
	return Micromap:CreateObject{
		ptr = ptr,
		device = device,
		buffer = buffer,
	}
end

function Micromap:Build(cmd, usage, scratch_address, data_address, triangle_address)
	self.device:GetExtension("vkCmdBuildMicromapsEXT")(
		cmd.ptr[0],
		1,
		get_build_info(self.ptr[0], usage, scratch_address, data_address, triangle_address)
	)
end

function Micromap:OnRemove()
	if self.ptr[0] and self.device:IsValid() then
		local device = self.device
		local ptr = self.ptr[0]
		self.ptr[0] = nil

		device:DeferRelease(function()
			device:GetExtension("vkDestroyMicromapEXT")(device.ptr[0], ptr, nil)
		end)
	end

	self.buffer:Remove()
end

return Micromap:Register()
