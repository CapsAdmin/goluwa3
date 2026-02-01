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

function PhysicalDevice:GetFormatProperties(format)
	local format_enum = vulkan.vk.e.VkFormat(format)
	local props = vulkan.vk.VkFormatProperties()
	vulkan.lib.vkGetPhysicalDeviceFormatProperties(self.ptr[0], format_enum, props)
	return props
end

function PhysicalDevice:GetFeatures()
	local features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceFeatures)()
	vulkan.lib.vkGetPhysicalDeviceFeatures(self.ptr[0], features)
	return features[0]
end

function PhysicalDevice:GetVulkan11Features()
	local vulkan11Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceVulkan11Features)(vulkan.vk.s.PhysicalDeviceVulkan11Features({
		sType = "physical_device_vulkan_1_1_features",
		pNext = nil,
		storageBuffer16BitAccess = 0,
		uniformAndStorageBuffer16BitAccess = 0,
		storagePushConstant16 = 0,
		storageInputOutput16 = 0,
		multiview = 0,
		multiviewGeometryShader = 0,
		multiviewTessellationShader = 0,
		variablePointersStorageBuffer = 0,
		variablePointers = 0,
		protectedMemory = 0,
		samplerYcbcrConversion = 0,
		shaderDrawParameters = 0,
	}))
	local queryDeviceFeatures = vulkan.vk.s.PhysicalDeviceFeatures2({
		sType = "physical_device_features_2",
		pNext = vulkan11Features,
		features = vulkan.vk.VkPhysicalDeviceFeatures(),
	})
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return vulkan11Features[0]
end

function PhysicalDevice:GetVulkan12Features()
	local vulkan12Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceVulkan12Features)(vulkan.vk.s.PhysicalDeviceVulkan12Features({
		sType = "physical_device_vulkan_1_2_features",
		pNext = nil,
		samplerMirrorClampToEdge = 0,
		drawIndirectCount = 0,
		storageBuffer8BitAccess = 0,
		uniformAndStorageBuffer8BitAccess = 0,
		storagePushConstant8 = 0,
		shaderBufferInt64Atomics = 0,
		shaderSharedInt64Atomics = 0,
		shaderFloat16 = 0,
		shaderInt8 = 0,
		descriptorIndexing = 0,
		shaderInputAttachmentArrayDynamicIndexing = 0,
		shaderUniformTexelBufferArrayDynamicIndexing = 0,
		shaderStorageTexelBufferArrayDynamicIndexing = 0,
		shaderUniformBufferArrayNonUniformIndexing = 0,
		shaderSampledImageArrayNonUniformIndexing = 0,
		shaderStorageBufferArrayNonUniformIndexing = 0,
		shaderStorageImageArrayNonUniformIndexing = 0,
		shaderInputAttachmentArrayNonUniformIndexing = 0,
		shaderUniformTexelBufferArrayNonUniformIndexing = 0,
		shaderStorageTexelBufferArrayNonUniformIndexing = 0,
		descriptorBindingUniformBufferUpdateAfterBind = 0,
		descriptorBindingSampledImageUpdateAfterBind = 0,
		descriptorBindingStorageImageUpdateAfterBind = 0,
		descriptorBindingStorageBufferUpdateAfterBind = 0,
		descriptorBindingUniformTexelBufferUpdateAfterBind = 0,
		descriptorBindingStorageTexelBufferUpdateAfterBind = 0,
		descriptorBindingUpdateUnusedWhilePending = 0,
		descriptorBindingPartiallyBound = 0,
		descriptorBindingVariableDescriptorCount = 0,
		runtimeDescriptorArray = 0,
		samplerFilterMinmax = 0,
		scalarBlockLayout = 0,
		imagelessFramebuffer = 0,
		uniformBufferStandardLayout = 0,
		shaderSubgroupExtendedTypes = 0,
		separateDepthStencilLayouts = 0,
		hostQueryReset = 0,
		timelineSemaphore = 0,
		bufferDeviceAddress = 0,
		bufferDeviceAddressCaptureReplay = 0,
		bufferDeviceAddressMultiDevice = 0,
		vulkanMemoryModel = 0,
		vulkanMemoryModelDeviceScope = 0,
		vulkanMemoryModelAvailabilityVisibilityChains = 0,
		shaderOutputViewportIndex = 0,
		shaderOutputLayer = 0,
		subgroupBroadcastDynamicId = 0,
	}))
	local queryDeviceFeatures = vulkan.vk.s.PhysicalDeviceFeatures2({
		sType = "physical_device_features_2",
		pNext = vulkan12Features,
		features = vulkan.vk.VkPhysicalDeviceFeatures(),
	})
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return vulkan12Features[0]
end

function PhysicalDevice:GetRobustness2Features()
	local robustness2Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceRobustness2FeaturesEXT)({
		sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
		pNext = nil,
		robustBufferAccess2 = 0,
		robustImageAccess2 = 0,
		nullDescriptor = 0,
	})
	local queryDeviceFeatures = vulkan.vk.s.PhysicalDeviceFeatures2({
		sType = "physical_device_features_2",
		pNext = robustness2Features,
		features = vulkan.vk.VkPhysicalDeviceFeatures(),
	})
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return robustness2Features[0]
end

function PhysicalDevice:GetExtendedDynamicStateFeatures()
	-- Chain v1, v2, and v3 feature queries together
	local queryFeaturesV3 = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicState3FeaturesEXT({
		sType = "physical_device_extended_dynamic_state_3_features_ext",
		pNext = nil,
		extendedDynamicState3TessellationDomainOrigin = 0,
		extendedDynamicState3DepthClampEnable = 0,
		extendedDynamicState3PolygonMode = 0,
		extendedDynamicState3RasterizationSamples = 0,
		extendedDynamicState3SampleMask = 0,
		extendedDynamicState3AlphaToCoverageEnable = 0,
		extendedDynamicState3AlphaToOneEnable = 0,
		extendedDynamicState3LogicOpEnable = 0,
		extendedDynamicState3ColorBlendEnable = 0,
		extendedDynamicState3ColorBlendEquation = 0,
		extendedDynamicState3ColorWriteMask = 0,
		extendedDynamicState3RasterizationStream = 0,
		extendedDynamicState3ConservativeRasterizationMode = 0,
		extendedDynamicState3ExtraPrimitiveOverestimationSize = 0,
		extendedDynamicState3DepthClipEnable = 0,
		extendedDynamicState3SampleLocationsEnable = 0,
		extendedDynamicState3ColorBlendAdvanced = 0,
		extendedDynamicState3ProvokingVertexMode = 0,
		extendedDynamicState3LineRasterizationMode = 0,
		extendedDynamicState3LineStippleEnable = 0,
		extendedDynamicState3DepthClipNegativeOneToOne = 0,
		extendedDynamicState3ViewportWScalingEnable = 0,
		extendedDynamicState3ViewportSwizzle = 0,
		extendedDynamicState3CoverageToColorEnable = 0,
		extendedDynamicState3CoverageToColorLocation = 0,
		extendedDynamicState3CoverageModulationMode = 0,
		extendedDynamicState3CoverageModulationTableEnable = 0,
		extendedDynamicState3CoverageModulationTable = 0,
		extendedDynamicState3CoverageReductionMode = 0,
		extendedDynamicState3RepresentativeFragmentTestEnable = 0,
		extendedDynamicState3ShadingRateImageEnable = 0,
	}))
	local queryFeaturesV2 = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicState2FeaturesEXT({
		sType = "physical_device_extended_dynamic_state_2_features_ext",
		pNext = queryFeaturesV3,
		extendedDynamicState2 = 0,
		extendedDynamicState2LogicOp = 0,
		extendedDynamicState2PatchControlPoints = 0,
	}))
	local queryFeaturesV1 = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicStateFeaturesEXT({
		sType = "physical_device_extended_dynamic_state_features_ext",
		pNext = queryFeaturesV2,
		extendedDynamicState = 0,
	}))
	local queryDeviceFeatures = vulkan.vk.s.PhysicalDeviceFeatures2({
		sType = "physical_device_features_2",
		pNext = queryFeaturesV1,
		features = vulkan.vk.VkPhysicalDeviceFeatures(),
	})
	-- Query all features at once
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	local reflect = require("helpers.ffi_reflect")
	local tbl = {}
	-- Extract v1 features
	local featuresV1 = queryFeaturesV1[0]

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT):members() do
		local key = t.name

		if key == "extendedDynamicState" then

		-- skip
		elseif key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState", "")] = featuresV1[key] == 1
		end
	end

	-- Extract v2 features
	local featuresV2 = queryFeaturesV2[0]

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT):members() do
		local key = t.name

		if key == "extendedDynamicState2" then

		-- skip
		elseif key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState2", "")] = featuresV2[key] == 1
		end
	end

	-- Extract v3 features
	local featuresV3 = queryFeaturesV3[0]

	for t in reflect.typeof(vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT):members() do
		local key = t.name

		if key:find("extendedDynamicState") then
			tbl[key:replace("extendedDynamicState3", "")] = featuresV3[key] == 1
		end
	end

	return tbl
end

function PhysicalDevice:GetDynamicRenderingFeatures()
	local queryDynamicRenderingFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceDynamicRenderingFeatures)(vulkan.vk.s.PhysicalDeviceDynamicRenderingFeatures({
		sType = "physical_device_dynamic_rendering_features",
		pNext = nil,
		dynamicRendering = 0,
	}))
	local queryDeviceFeatures = vulkan.vk.s.PhysicalDeviceFeatures2({
		sType = "physical_device_features_2",
		pNext = queryDynamicRenderingFeatures,
		features = vulkan.vk.VkPhysicalDeviceFeatures(),
	})
	vulkan.lib.vkGetPhysicalDeviceFeatures2(self.ptr[0], queryDeviceFeatures)
	return queryDynamicRenderingFeatures[0].dynamicRendering == 1
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
