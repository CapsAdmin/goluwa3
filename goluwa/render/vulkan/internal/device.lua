local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Device = prototype.CreateTemplate("vulkan_device")
Device.GetQueue = require("render.vulkan.internal.queue").New

function Device.New(physical_device, extensions, graphicsQueueFamily)
	local available_extensions = physical_device:GetAvailableDeviceExtensions()
	-- Add portability subset and its dependency if supported
	local finalExtensions = {}

	for i, ext in ipairs(extensions) do
		finalExtensions[i] = ext
	end

	if table.has_value(available_extensions, "VK_KHR_portability_subset") then
		-- VK_KHR_portability_subset requires VK_KHR_get_physical_device_properties2
		-- but this extension is promoted to core in Vulkan 1.1, so it's likely already available
		table.insert(finalExtensions, "VK_KHR_portability_subset")

		-- Only add the dependency if not already present
		if not table.has_value(finalExtensions, "VK_KHR_get_physical_device_properties2") then
			-- Check if this extension is available
			if table.has_value(available_extensions, "VK_KHR_get_physical_device_properties2") then
				table.insert(finalExtensions, "VK_KHR_get_physical_device_properties2")
			end
		end
	end

	if table.has_value(available_extensions, "VK_KHR_dynamic_rendering") then
		table.insert(finalExtensions, "VK_KHR_dynamic_rendering")
	end

	if table.has_value(available_extensions, "VK_EXT_extended_dynamic_state3") then
		table.insert(finalExtensions, "VK_EXT_extended_dynamic_state3")
	end

	if table.has_value(available_extensions, "VK_EXT_scalar_block_layout") then
		table.insert(finalExtensions, "VK_EXT_scalar_block_layout")
	end

	if table.has_value(available_extensions, "VK_EXT_mesh_shader") then
		table.insert(finalExtensions, "VK_EXT_mesh_shader")
	end

	if table.has_value(available_extensions, "VK_EXT_conditional_rendering") then
		table.insert(finalExtensions, "VK_EXT_conditional_rendering")
	end

	-- Query available features if extension is present
	local pNextChain = nil
	-- Maintenance4 features
	local maintenance4Features = vulkan.vk.VkPhysicalDeviceMaintenance4Features()
	maintenance4Features.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_4_FEATURES
	maintenance4Features.pNext = pNextChain
	maintenance4Features.maintenance4 = 1
	pNextChain = maintenance4Features
	local vulkan11Features = vulkan.vk.VkPhysicalDeviceVulkan11Features()
	vulkan11Features.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
	vulkan11Features.pNext = pNextChain
	vulkan11Features.storageBuffer16BitAccess = 1
	vulkan11Features.uniformAndStorageBuffer16BitAccess = 1
	pNextChain = vulkan11Features
	local demoteFeatures = vulkan.vk.VkPhysicalDeviceShaderDemoteToHelperInvocationFeaturesEXT()
	demoteFeatures.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DEMOTE_TO_HELPER_INVOCATION_FEATURES_EXT
	demoteFeatures.pNext = pNextChain
	demoteFeatures.shaderDemoteToHelperInvocation = 1
	pNextChain = demoteFeatures
	local hasDynamicRenderingFeatures = physical_device:GetDynamicRenderingFeatures()
	-- Extended dynamic state features
	local has_extended_dynamic_state = table.has_value(available_extensions, "VK_EXT_extended_dynamic_state")
	local has_extended_dynamic_state3 = table.has_value(available_extensions, "VK_EXT_extended_dynamic_state3")
	local has_mesh_shader = table.has_value(available_extensions, "VK_EXT_mesh_shader")
	local has_polygon_mode_dynamic_state = false -- Set to true to enable wireframe support (requires VK_EXT_extended_dynamic_state3)
	if has_mesh_shader then
		local meshShaderFeatures = vulkan.vk.VkPhysicalDeviceMeshShaderFeaturesEXT(
			{
				sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
				pNext = pNextChain,
				taskShader = 1,
				meshShader = 1,
				multiviewMeshShader = 0,
				primitiveFragmentShadingRateMeshShader = 0,
				meshShaderQueries = 0,
			}
		)
		pNextChain = meshShaderFeatures
	end

	if has_extended_dynamic_state then
		local extendedDynamicStateFeatures = vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT(
			{
				sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
				pNext = pNextChain,
				extendedDynamicState = 1,
			}
		)
		pNextChain = extendedDynamicStateFeatures
	end

	if has_extended_dynamic_state3 then
		local extendedDynamicState3Features = vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT(
			{
				sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
				pNext = pNextChain,
				extendedDynamicState3ColorBlendEnable = 1,
				extendedDynamicState3ColorBlendEquation = 1,
				extendedDynamicState3TessellationDomainOrigin = 0,
				extendedDynamicState3DepthClampEnable = 0,
				extendedDynamicState3PolygonMode = has_polygon_mode_dynamic_state and 1 or 0,
				extendedDynamicState3RasterizationSamples = 0,
				extendedDynamicState3SampleMask = 0,
				extendedDynamicState3AlphaToCoverageEnable = 0,
				extendedDynamicState3AlphaToOneEnable = 0,
				extendedDynamicState3LogicOpEnable = 0,
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
			}
		)
		pNextChain = extendedDynamicState3Features
	end

	-- Enable dynamic rendering if supported
	if hasDynamicRenderingFeatures then
		local dynamicRenderingFeatures = vulkan.vk.VkPhysicalDeviceDynamicRenderingFeatures(
			{
				sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
				pNext = pNextChain,
				dynamicRendering = 1,
			}
		)
		pNextChain = dynamicRenderingFeatures
	end

	local physical_features = physical_device:GetFeatures()
	local enabled_features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceFeatures)()

	if physical_features.samplerAnisotropy == 1 then
		enabled_features[0].samplerAnisotropy = 1
	end

	if physical_features.shaderInt64 == 1 then
		enabled_features[0].shaderInt64 = 1
	end

	if physical_features.depthClamp == 1 then
		enabled_features[0].depthClamp = 1
	end

	-- Enable scalar block layout feature for push constants
	-- and descriptor indexing features for bindless textures
	local vulkan12Features = vulkan.vk.VkPhysicalDeviceVulkan12Features(
		{
			sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			pNext = pNextChain,
			scalarBlockLayout = 1,
			-- Descriptor indexing features for bindless rendering
			descriptorIndexing = 1,
			shaderSampledImageArrayNonUniformIndexing = 1,
			descriptorBindingPartiallyBound = 1,
			runtimeDescriptorArray = 1,
			descriptorBindingSampledImageUpdateAfterBind = 1,
			--
			samplerMirrorClampToEdge = 0,
			drawIndirectCount = 0,
			storageBuffer8BitAccess = 0,
			uniformAndStorageBuffer8BitAccess = 0,
			storagePushConstant8 = 0,
			shaderBufferInt64Atomics = 0,
			shaderSharedInt64Atomics = 0,
			shaderFloat16 = 0,
			shaderInt8 = 0,
			shaderInputAttachmentArrayDynamicIndexing = 0,
			shaderUniformTexelBufferArrayDynamicIndexing = 0,
			shaderStorageTexelBufferArrayDynamicIndexing = 0,
			shaderUniformBufferArrayNonUniformIndexing = 0,
			shaderStorageBufferArrayNonUniformIndexing = 0,
			shaderStorageImageArrayNonUniformIndexing = 0,
			shaderInputAttachmentArrayNonUniformIndexing = 0,
			shaderUniformTexelBufferArrayNonUniformIndexing = 0,
			shaderStorageTexelBufferArrayNonUniformIndexing = 0,
			descriptorBindingUniformBufferUpdateAfterBind = 0,
			descriptorBindingStorageImageUpdateAfterBind = 0,
			descriptorBindingStorageBufferUpdateAfterBind = 0,
			descriptorBindingUniformTexelBufferUpdateAfterBind = 0,
			descriptorBindingStorageTexelBufferUpdateAfterBind = 0,
			descriptorBindingUpdateUnusedWhilePending = 0,
			descriptorBindingVariableDescriptorCount = 0,
			samplerFilterMinmax = 0,
			imagelessFramebuffer = 0,
			uniformBufferStandardLayout = 0,
			shaderSubgroupExtendedTypes = 0,
			separateDepthStencilLayouts = 0,
			hostQueryReset = 0,
			timelineSemaphore = 0,
			bufferDeviceAddress = 1,
			bufferDeviceAddressCaptureReplay = 0,
			bufferDeviceAddressMultiDevice = 0,
			vulkanMemoryModel = 0,
			vulkanMemoryModelDeviceScope = 0,
			vulkanMemoryModelAvailabilityVisibilityChains = 0,
			shaderOutputViewportIndex = 0,
			shaderOutputLayer = 0,
			subgroupBroadcastDynamicId = 0,
		}
	)
	local queuePriority = ffi.new("float[1]", 1.0)
	local queueCreateInfo = vulkan.vk.s.DeviceQueueCreateInfo(
		{
			queueFamilyIndex = graphicsQueueFamily,
			queueCount = 1,
			pQueuePriorities = queuePriority,
			flags = 0,
		}
	)
	local deviceExtensions = vulkan.T.Array(ffi.typeof("const char*"))(#finalExtensions)

	for i, ext in ipairs(finalExtensions) do
		deviceExtensions[i - 1] = ext
	end

	local deviceCreateInfo = vulkan.vk.s.DeviceCreateInfo(
		{
			pNext = vulkan12Features,
			queueCreateInfoCount = 1,
			pQueueCreateInfos = queueCreateInfo,
			enabledExtensionCount = #finalExtensions,
			ppEnabledExtensionNames = deviceExtensions,
			flags = 0,
			enabledLayerCount = 0,
			ppEnabledLayerNames = nil,
			pEnabledFeatures = enabled_features,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkDevice)()
	vulkan.assert(
		vulkan.lib.vkCreateDevice(physical_device.ptr[0], deviceCreateInfo, nil, ptr),
		"failed to create device"
	)
	local device = Device:CreateObject(
		{
			ptr = ptr,
			has_extended_dynamic_state = has_extended_dynamic_state,
			has_extended_dynamic_state3 = has_extended_dynamic_state3,
			has_polygon_mode_dynamic_state = has_polygon_mode_dynamic_state,
			physical_device = physical_device,
			extensions = finalExtensions,
		}
	)

	if has_extended_dynamic_state then
		vulkan.ext.vkCmdSetPrimitiveTopologyEXT = device:TryGetExtension("vkCmdSetPrimitiveTopologyEXT")
		vulkan.ext.vkCmdSetCullModeEXT = device:TryGetExtension("vkCmdSetCullModeEXT")
		vulkan.ext.vkCmdSetFrontFaceEXT = device:TryGetExtension("vkCmdSetFrontFaceEXT")
		vulkan.ext.vkCmdSetDepthTestEnableEXT = device:TryGetExtension("vkCmdSetDepthTestEnableEXT")
		vulkan.ext.vkCmdSetDepthWriteEnableEXT = device:TryGetExtension("vkCmdSetDepthWriteEnableEXT")
		vulkan.ext.vkCmdSetDepthCompareOpEXT = device:TryGetExtension("vkCmdSetDepthCompareOpEXT")
	end

	-- Load extension functions if dynamic blend features are supported
	if has_extended_dynamic_state3 then
		vulkan.ext.vkCmdSetColorBlendEnableEXT = device:TryGetExtension("vkCmdSetColorBlendEnableEXT")
		vulkan.ext.vkCmdSetColorBlendEquationEXT = device:TryGetExtension("vkCmdSetColorBlendEquationEXT")

		if has_polygon_mode_dynamic_state then
			vulkan.ext.vkCmdSetPolygonModeEXT = device:TryGetExtension("vkCmdSetPolygonModeEXT")
		end
	end

	-- Load conditional rendering extension functions only if requested
	if table.has_value(finalExtensions, "VK_EXT_conditional_rendering") then
		vulkan.ext.vkCmdBeginConditionalRenderingEXT = device:TryGetExtension("vkCmdBeginConditionalRenderingEXT")
		vulkan.ext.vkCmdEndConditionalRenderingEXT = device:TryGetExtension("vkCmdEndConditionalRenderingEXT")
	end

	if has_mesh_shader then
		vulkan.ext.vkCmdDrawMeshTasksEXT = device:TryGetExtension("vkCmdDrawMeshTasksEXT")
		vulkan.ext.vkCmdDrawMeshTasksIndirectEXT = device:TryGetExtension("vkCmdDrawMeshTasksIndirectEXT")
		vulkan.ext.vkCmdDrawMeshTasksIndirectCountEXT = device:TryGetExtension("vkCmdDrawMeshTasksIndirectCountEXT")
	end

	return device
end

function Device:OnRemove()
	vulkan.lib.vkDeviceWaitIdle(self.ptr[0])
	vulkan.lib.vkDestroyDevice(self.ptr[0], nil)
end

function Device:TryGetExtension(name)
	local func_ptr = vulkan.lib.vkGetDeviceProcAddr(self.ptr[0], name)

	if func_ptr == nil then return nil end

	return ffi.cast(vulkan.vk["PFN_" .. name], func_ptr)
end

function Device:GetExtension(name)
	local func_ptr = self:TryGetExtension(name)

	if func_ptr == nil then
		error("device extension function not found: " .. name, 2)
	end

	return func_ptr
end

function Device:WaitIdle()
	vulkan.lib.vkDeviceWaitIdle(self.ptr[0])
end

function Device:UpdateDescriptorSet(type, descriptorSet, binding_index, ...)
	local descriptorWrite = vulkan.vk.s.WriteDescriptorSet(
		{
			dstSet = descriptorSet.ptr[0],
			dstBinding = binding_index,
			dstArrayElement = 0,
			descriptorType = type,
			descriptorCount = 1,
		}
	)
	local descriptor_info = nil

	if type == "uniform_buffer" then
		local buffer = assert(...)
		descriptor_info = vulkan.vk.VkDescriptorBufferInfo({
			buffer = buffer.ptr[0],
			offset = 0,
			range = buffer.size,
		})
		descriptorWrite.pBufferInfo = descriptor_info
	elseif type == "storage_image" then
		local imageView = assert(...)
		descriptor_info = vulkan.vk.VkDescriptorImageInfo(
			{
				sampler = nil,
				imageView = imageView.ptr[0],
				imageLayout = "general",
			}
		)
		descriptorWrite.pImageInfo = descriptor_info
	elseif type == "combined_image_sampler" then
		local imageView, sampler = assert(select(1, ...)), assert(select(2, ...))
		descriptor_info = vulkan.vk.s.DescriptorImageInfo(
			{
				sampler = sampler.ptr[0],
				imageView = imageView.ptr[0],
				imageLayout = "read_only_optimal",
			}
		)
		descriptorWrite.pImageInfo = descriptor_info
	else
		error("unsupported descriptor type: " .. tostring(type))
	end

	vulkan.lib.vkUpdateDescriptorSets(self.ptr[0], 1, descriptorWrite, 0, nil)
end

function Device:UpdateDescriptorSetArray(descriptorSet, binding_index, texture_array)
	-- texture_array is an array of {view, sampler} tables
	local count = #texture_array

	if count == 0 then return end

	-- Create array of VkDescriptorImageInfo
	local imageInfoArray = vulkan.T.Array(vulkan.vk.VkDescriptorImageInfo)(count)

	for i, tex in ipairs(texture_array) do
		imageInfoArray[i - 1].sampler = tex.sampler and tex.sampler.ptr[0] or nil
		imageInfoArray[i - 1].imageView = tex.view.ptr[0]
		imageInfoArray[i - 1].imageLayout = vulkan.vk.VkImageLayout.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
	end

	local descriptorWrite = vulkan.T.Array(vulkan.vk.VkWriteDescriptorSet)(1)
	descriptorWrite[0].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
	descriptorWrite[0].dstSet = descriptorSet.ptr[0]
	descriptorWrite[0].dstBinding = binding_index
	descriptorWrite[0].dstArrayElement = 0
	descriptorWrite[0].descriptorType = vulkan.vk.VkDescriptorType.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
	descriptorWrite[0].descriptorCount = count
	descriptorWrite[0].pImageInfo = imageInfoArray
	vulkan.lib.vkUpdateDescriptorSets(self.ptr[0], 1, descriptorWrite, 0, nil)
end

function Device:GetImageMemoryRequirements(image)
	local memRequirements = vulkan.vk.VkMemoryRequirements()
	vulkan.lib.vkGetImageMemoryRequirements(self.ptr[0], image.ptr[0], memRequirements)
	return memRequirements
end

function Device:GetBufferMemoryRequirements(buffer)
	local memRequirements = vulkan.vk.VkMemoryRequirements()
	vulkan.lib.vkGetBufferMemoryRequirements(self.ptr[0], buffer.ptr[0], memRequirements)
	return memRequirements
end

return Device:Register()
