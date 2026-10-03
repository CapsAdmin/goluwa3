local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local PipelineCache = objects.CreateTemplate("vulkan_pipeline_cache")
local VkPipelineCacheBox = ffi.typeof("$[1]", vulkan.vk.VkPipelineCache)
local SizeBox = ffi.typeof("size_t[1]")
local ByteArray = ffi.typeof("uint8_t[?]")
local HeaderPtr = ffi.typeof("const $*", vulkan.vk.VkPipelineCacheHeaderVersionOne)

local function is_compatible(device, data)
	if #data < ffi.sizeof(vulkan.vk.VkPipelineCacheHeaderVersionOne) then
		return false
	end

	local header = ffi.cast(HeaderPtr, data)
	local properties = device.physical_device:GetProperties()
	return header.headerVersion == vulkan.vk.VkPipelineCacheHeaderVersion.VK_PIPELINE_CACHE_HEADER_VERSION_ONE and
		header.vendorID == properties.vendorID and
		header.deviceID == properties.deviceID and
		ffi.string(header.pipelineCacheUUID, 16) == ffi.string(properties.pipelineCacheUUID, 16)
end

function PipelineCache.New(device, initial_data)
	if initial_data and not is_compatible(device, initial_data) then
		logn("[vulkan] ignoring pipeline cache from another device or driver")
		initial_data = nil
	end

	local ptr = VkPipelineCacheBox()
	vulkan.assert(
		vulkan.lib.vkCreatePipelineCache(
			device.ptr[0],
			vulkan.vk.s.PipelineCacheCreateInfo{
				initialDataSize = initial_data and #initial_data or 0,
				pInitialData = initial_data and ffi.cast("const void*", initial_data) or nil,
			},
			nil,
			ptr
		),
		"failed to create pipeline cache"
	)
	return PipelineCache:CreateObject{
		device = device,
		ptr = ptr,
		initial_data = initial_data,
		generation = 0,
	}
end

function PipelineCache:GetData()
	local size = SizeBox()
	vulkan.assert(
		vulkan.lib.vkGetPipelineCacheData(self.device.ptr[0], self.ptr[0], size, nil),
		"failed to get pipeline cache size"
	)
	local data = ByteArray(size[0])
	vulkan.assert(
		vulkan.lib.vkGetPipelineCacheData(self.device.ptr[0], self.ptr[0], size, data),
		"failed to get pipeline cache data"
	)
	return ffi.string(data, size[0])
end

function PipelineCache:OnRemove()
	if self.device:IsValid() then
		vulkan.lib.vkDestroyPipelineCache(self.device.ptr[0], self.ptr[0], nil)
	end
end

return PipelineCache:Register()
