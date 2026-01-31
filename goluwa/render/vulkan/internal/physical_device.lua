local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local PhysicalDevice = prototype.CreateTemplate("vulkan_physical_device")

function PhysicalDevice.New(ptr)
	assert(type(ptr) == "cdata", "ptr must be a cdata VkPhysicalDevice")
	local ptr_boxed = vulkan.T.Box(vulkan.vk.VkPhysicalDevice)()
	ptr_boxed[0] = ptr
	return PhysicalDevice:CreateObject({ptr = ptr_boxed})
end

function PhysicalDevice:SupportsSurface(surface)
	-- Check if any queue family supports presentation to this surface
	local queue_families = self:GetQueueFamilyProperties()

	for i, queueFamily in ipairs(queue_families) do
		local presentSupport = ffi.new("uint32_t[1]")
		local result = vulkan.lib.vkGetPhysicalDeviceSurfaceSupportKHR(self.ptr[0], i - 1, surface.ptr[0], presentSupport)

		if result == 0 and presentSupport[0] ~= 0 then return true end
	end

	return false
end

function PhysicalDevice:FindMemoryType(typeFilter, properties)
	local memProperties = vulkan.vk.VkPhysicalDeviceMemoryProperties()
	vulkan.lib.vkGetPhysicalDeviceMemoryProperties(self.ptr[0], memProperties)
	local e = vulkan.vk.e.VkMemoryPropertyFlagBits(properties)

	for i = 0, memProperties.memoryTypeCount - 1 do
		if
			bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and
			bit.band(memProperties.memoryTypes[i].propertyFlags, e) == e
		then
			return i
		end
	end

	error("failed to find suitable memory type!")
end

function PhysicalDevice:FindGraphicsQueueFamily(surface)
	if not surface then
		local graphicsQueueFamily = nil

		for i, queueFamily in ipairs(self:GetQueueFamilyProperties()) do
			local queueFlags = queueFamily.queueFlags
			local graphicsBit = vulkan.vk.VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT

			if bit.band(queueFlags, graphicsBit) ~= 0 then
				graphicsQueueFamily = i - 1

				break
			end
		end

		if not graphicsQueueFamily then error("no graphics queue family found") end

		return graphicsQueueFamily
	end

	local graphicsQueueFamily = nil

	for i, queueFamily in ipairs(self:GetQueueFamilyProperties()) do
		local queueFlags = queueFamily.queueFlags
		local graphicsBit = vulkan.vk.VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT

		if bit.band(queueFlags, graphicsBit) ~= 0 then
			if not graphicsQueueFamily then graphicsQueueFamily = i - 1 end
		end

		local presentSupport = ffi.new("uint32_t[1]")
		vulkan.lib.vkGetPhysicalDeviceSurfaceSupportKHR(self.ptr[0], i - 1, surface.ptr[0], presentSupport)

		if bit.band(queueFlags, graphicsBit) ~= 0 and presentSupport[0] ~= 0 then
			graphicsQueueFamily = i - 1

			break
		end
	end

	if not graphicsQueueFamily then error("no graphics queue family found") end

	return graphicsQueueFamily
end

function PhysicalDevice:GetSurfaceFormats(surface)
	local formatCount = ffi.new("uint32_t[1]", 0)
	local result_code = vulkan.lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr[0], surface.ptr[0], formatCount, nil)
	local count = formatCount[0]

	if count == 0 then
		print("WARNING: No surface formats returned!")
		return {}
	end

	local formats = vulkan.T.Array(vulkan.vk.VkSurfaceFormatKHR)(count)
	result_code = vulkan.lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr[0], surface.ptr[0], formatCount, formats)
	local result = {}

	for i = 0, count - 1 do
		result[i + 1] = {
			format = vulkan.vk.str.VkFormat(formats[i].format),
			color_space = vulkan.vk.str.VkColorSpaceKHR(formats[i].colorSpace),
		}
	end

	return result
end

function PhysicalDevice:GetQueueFamilyProperties()
	local count = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr[0], count, nil)
	local queue_family_count = count[0]
	local queue_families = vulkan.T.Array(vulkan.vk.VkQueueFamilyProperties)(queue_family_count)
	vulkan.lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr[0], count, queue_families)
	local result = {}

	for i = 0, queue_family_count - 1 do
		result[i + 1] = queue_families[i]
	end

	return result
end

function PhysicalDevice:GetSurfaceCapabilities(surface)
	local surfaceCapabilities = vulkan.vk.VkSurfaceCapabilitiesKHR()
	vulkan.assert(
		vulkan.lib.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.ptr[0], surface.ptr[0], surfaceCapabilities),
		"failed to get surface capabilities"
	)
	return surfaceCapabilities
end

function PhysicalDevice:GetPresentModes(surface)
	local presentModeCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr[0], surface.ptr[0], presentModeCount, nil)
	local count = presentModeCount[0]
	local presentModes = vulkan.T.Array(vulkan.vk.VkPresentModeKHR)(count)
	vulkan.lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr[0], surface.ptr[0], presentModeCount, presentModes)
	-- Convert to Lua table
	local result = {}

	for i = 0, count - 1 do
		result[i + 1] = presentModes[i]
	end

	return result
end

function PhysicalDevice:GetAvailableDeviceExtensions()
	local extensionCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkEnumerateDeviceExtensionProperties(self.ptr[0], nil, extensionCount, nil)
	local availableExtensions = vulkan.T.Array(vulkan.vk.VkExtensionProperties)(extensionCount[0])
	vulkan.lib.vkEnumerateDeviceExtensionProperties(self.ptr[0], nil, extensionCount, availableExtensions)
	local out = {}

	for i = 0, extensionCount[0] - 1 do
		table.insert(out, ffi.string(availableExtensions[i].extensionName))
	end

	return out
end

function PhysicalDevice:GetProperties()
	local properties = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceProperties)()
	vulkan.lib.vkGetPhysicalDeviceProperties(self.ptr[0], properties)
	return properties[0]
end

function PhysicalDevice:GetFeatures()
	local features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceFeatures)()
	vulkan.lib.vkGetPhysicalDeviceFeatures(self.ptr[0], features)
	return features[0]
end

function PhysicalDevice:GetVulkan11Features()
	local vulkan11Features = vulkan.vk.VkPhysicalDeviceVulkan11Features()
	vulkan11Features.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
	vulkan11Features.pNext = nil
	
	local queryDeviceFeatures = vulkan.vk.VkPhysicalDeviceFeatures2()
	queryDeviceFeatures.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
	queryDeviceFeatures.pNext = vulkan11Features
	
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return vulkan11Features
end

function PhysicalDevice:GetExtendedDynamicStateFeatures()
	-- Chain v1, v2, and v3 feature queries together
	local queryFeaturesV3 = vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
			pNext = nil,
		}
	)
	local queryFeaturesV2 = vulkan.vk.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
			pNext = queryFeaturesV3,
		}
	)
	local queryFeaturesV1 = vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
			pNext = queryFeaturesV2,
		}
	)
	local queryDeviceFeatures = vulkan.vk.VkPhysicalDeviceFeatures2(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
			pNext = queryFeaturesV1,
		}
	)
	-- Query all features at once
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	local reflect = require("helpers.ffi_reflect")
	local tbl = {}
	-- Extract v1 features
	local featuresV1 = queryFeaturesV1

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT):members() do
		local key = t.name

		if key == "extendedDynamicState" then

		-- skip
		elseif key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState", "")] = featuresV1[key] == 1
		end
	end

	-- Extract v2 features
	local featuresV2 = queryFeaturesV2

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT):members() do
		local key = t.name

		if key == "extendedDynamicState2" then

		-- skip
		elseif key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState2", "")] = featuresV2[key] == 1
		end
	end

	-- Extract v3 features
	local featuresV3 = queryFeaturesV3

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT):members() do
		local key = t.name

		if key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState3", "")] = featuresV3[key] == 1
		end
	end

	return tbl
end

function PhysicalDevice:GetDynamicRenderingFeatures()
	local queryDynamicRenderingFeatures = vulkan.vk.VkPhysicalDeviceDynamicRenderingFeatures(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
			pNext = nil,
			dynamicRendering = 0,
		}
	)
	local queryDeviceFeatures = vulkan.vk.VkPhysicalDeviceFeatures2(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
			pNext = queryDynamicRenderingFeatures,
			features = vulkan.vk.VkPhysicalDeviceFeatures(),
		}
	)
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return queryDynamicRenderingFeatures.dynamicRendering == 1
end

function PhysicalDevice:GetMaxSampleCount()
	local props = self:GetProperties()
	local counts = bit.band(
		tonumber(props.limits.framebufferColorSampleCounts),
		tonumber(props.limits.framebufferDepthSampleCounts)
	)

	if bit.band(counts, 64) ~= 0 then return "64" end

	if bit.band(counts, 32) ~= 0 then return "32" end

	if bit.band(counts, 16) ~= 0 then return "16" end

	if bit.band(counts, 8) ~= 0 then return "8" end

	if bit.band(counts, 4) ~= 0 then return "4" end

	if bit.band(counts, 2) ~= 0 then return "2" end

	return "1"
end

return PhysicalDevice:Register()
