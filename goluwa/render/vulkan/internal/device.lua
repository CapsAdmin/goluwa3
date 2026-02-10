local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Device = prototype.CreateTemplate("vulkan_device")
Device.GetQueue = require("render.vulkan.internal.queue").New

function Device.New(physical_device, extensions, graphicsQueueFamily)
	local available_extensions = physical_device:GetAvailableDeviceExtensions()
	-- Add portability subset and its dependency if supported
	local finalExtensions = {}

	-- Only add requested extensions if they're actually available
	for _, ext in ipairs(extensions) do
		if table.has_value(available_extensions, ext) then
			table.insert(finalExtensions, ext)
		end
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
	local maintenance4Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceMaintenance4Features)(vulkan.vk.s.PhysicalDeviceMaintenance4Features({
		sType = "physical_device_maintenance_4_features",
		pNext = nil,
		maintenance4 = 1,
	}))
	pNextChain = maintenance4Features
	
	-- Query available Vulkan 1.1 features
	local availableVulkan11Features = physical_device:GetVulkan11Features()
	local vulkan11Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceVulkan11Features)(vulkan.vk.s.PhysicalDeviceVulkan11Features({
		sType = "physical_device_vulkan_1_1_features",
		pNext = pNextChain,
		-- Only enable 16-bit features if they're actually supported
		storageBuffer16BitAccess = availableVulkan11Features.storageBuffer16BitAccess,
		uniformAndStorageBuffer16BitAccess = availableVulkan11Features.uniformAndStorageBuffer16BitAccess,
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
	pNextChain = vulkan11Features

	-- Shader demote features
	local demoteFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceShaderDemoteToHelperInvocationFeaturesEXT)(vulkan.vk.s.PhysicalDeviceShaderDemoteToHelperInvocationFeatures({
		sType = "physical_device_shader_demote_to_helper_invocation_features",
		pNext = pNextChain,
		shaderDemoteToHelperInvocation = 1,
	}))
	pNextChain = demoteFeatures

	local hasDynamicRenderingFeatures = physical_device:GetDynamicRenderingFeatures()
	-- Extended dynamic state features
	local dynamicStateFeatures = physical_device:GetExtendedDynamicStateFeatures()
	local has_extended_dynamic_state = table.has_value(available_extensions, "VK_EXT_extended_dynamic_state") and dynamicStateFeatures.extendedDynamicState
	local has_extended_dynamic_state2 = table.has_value(available_extensions, "VK_EXT_extended_dynamic_state2") and dynamicStateFeatures.extendedDynamicState2
	local has_extended_dynamic_state3 = table.has_value(available_extensions, "VK_EXT_extended_dynamic_state3")
	local has_mesh_shader = table.has_value(available_extensions, "VK_EXT_mesh_shader")
	local has_polygon_mode_dynamic_state = has_extended_dynamic_state3 and dynamicStateFeatures.extendedDynamicState3PolygonMode -- Set to true to enable wireframe support (requires VK_EXT_extended_dynamic_state3)
	
	if has_mesh_shader then
		local meshShaderFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceMeshShaderFeaturesEXT)(vulkan.vk.s.PhysicalDeviceMeshShaderFeaturesEXT({
			sType = "physical_device_mesh_shader_features_ext",
			pNext = pNextChain,
			taskShader = 1,
			meshShader = 1,
			multiviewMeshShader = 0,
			primitiveFragmentShadingRateMeshShader = 0,
			meshShaderQueries = 0,
		}))
		pNextChain = meshShaderFeatures
	end

	if has_extended_dynamic_state then
		local extendedDynamicStateFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicStateFeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicStateFeaturesEXT({
			sType = "physical_device_extended_dynamic_state_features_ext",
			pNext = pNextChain,
			extendedDynamicState = 1,
		}))
		pNextChain = extendedDynamicStateFeatures
	end

	if has_extended_dynamic_state2 then
		local extendedDynamicState2Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicState2FeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicState2FeaturesEXT({
			sType = "physical_device_extended_dynamic_state_2_features_ext",
			pNext = pNextChain,
			extendedDynamicState2 = 1,
			extendedDynamicState2LogicOp = 0,
			extendedDynamicState2PatchControlPoints = 0,
		}))
		pNextChain = extendedDynamicState2Features
	end

	if has_extended_dynamic_state3 then
		local extendedDynamicState3Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceExtendedDynamicState3FeaturesEXT)(vulkan.vk.s.PhysicalDeviceExtendedDynamicState3FeaturesEXT({
			sType = "physical_device_extended_dynamic_state_3_features_ext",
			pNext = pNextChain,
			extendedDynamicState3TessellationDomainOrigin = 0,
			extendedDynamicState3DepthClampEnable = 0,
			extendedDynamicState3PolygonMode = has_polygon_mode_dynamic_state and 1 or 0,
			extendedDynamicState3RasterizationSamples = 0,
			extendedDynamicState3SampleMask = 0,
			extendedDynamicState3AlphaToCoverageEnable = 0,
			extendedDynamicState3AlphaToOneEnable = 0,
			extendedDynamicState3LogicOpEnable = 0,
			extendedDynamicState3ColorBlendEnable = dynamicStateFeatures.extendedDynamicState3ColorBlendEnable and 1 or 0,
			extendedDynamicState3ColorBlendEquation = dynamicStateFeatures.extendedDynamicState3ColorBlendEquation and 1 or 0,
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
		pNextChain = extendedDynamicState3Features
	end

	if hasDynamicRenderingFeatures then
		local dynamicRenderingFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceDynamicRenderingFeatures)(vulkan.vk.s.PhysicalDeviceDynamicRenderingFeatures({
			sType = "physical_device_dynamic_rendering_features",
			pNext = pNextChain,
			dynamicRendering = 1,
		}))
		pNextChain = dynamicRenderingFeatures
	end

	if table.has_value(available_extensions, "VK_EXT_conditional_rendering") then
		local conditionalRenderingFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceConditionalRenderingFeaturesEXT)(vulkan.vk.s.PhysicalDeviceConditionalRenderingFeaturesEXT({
			sType = "physical_device_conditional_rendering_features_ext",
			pNext = pNextChain,
			conditionalRendering = 1,
			inheritedConditionalRendering = 0,
		}))
		pNextChain = conditionalRenderingFeatures
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
	local availableVulkan12Features = physical_device:GetVulkan12Features()
	local vulkan12Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceVulkan12Features)(vulkan.vk.s.PhysicalDeviceVulkan12Features({
		sType = "physical_device_vulkan_1_2_features",
		pNext = pNextChain,
		scalarBlockLayout = 1,
		-- Descriptor indexing features for bindless rendering
		descriptorIndexing = 1,
		shaderSampledImageArrayNonUniformIndexing = 1,
		descriptorBindingPartiallyBound = 1,
		runtimeDescriptorArray = 1,
		descriptorBindingSampledImageUpdateAfterBind = 1,
		bufferDeviceAddress = 1,

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
		bufferDeviceAddressCaptureReplay = 0,
		bufferDeviceAddressMultiDevice = 0,
		vulkanMemoryModel = 0,
		vulkanMemoryModelDeviceScope = 0,
		vulkanMemoryModelAvailabilityVisibilityChains = 0,
		shaderOutputViewportIndex = 0,
		shaderOutputLayer = 0,
		subgroupBroadcastDynamicId = 0,
	}))
	pNextChain = vulkan12Features

	local has_null_descriptor = false
	if table.has_value(available_extensions, "VK_EXT_robustness2") then
		table.insert(finalExtensions, "VK_EXT_robustness2")
		local robustness2Features = physical_device:GetRobustness2Features()
		if robustness2Features.nullDescriptor == 1 then
			has_null_descriptor = true
			local enabledRobustness2Features = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceRobustness2FeaturesEXT)(vulkan.vk.s.PhysicalDeviceRobustness2FeaturesEXT({
				sType = "physical_device_robustness_2_features_ext",
				pNext = pNextChain,
				nullDescriptor = 1,
				robustBufferAccess2 = 0,
				robustImageAccess2 = 0,
			}))
			pNextChain = enabledRobustness2Features
		end
	end
	
	local queuePriority = ffi.new("float[1]", 1.0)
	local queueCreateInfo = vulkan.T.Box(vulkan.vk.VkDeviceQueueCreateInfo)(vulkan.vk.s.DeviceQueueCreateInfo(
		{
			queueFamilyIndex = graphicsQueueFamily,
			queueCount = 1,
			pQueuePriorities = queuePriority,
			flags = 0,
		}
	))

	if table.has_value(available_extensions, "VK_KHR_shader_demote_to_helper_invocation") then
		table.insert(finalExtensions, "VK_KHR_shader_demote_to_helper_invocation")
		local demoteFeatures = vulkan.T.Box(vulkan.vk.VkPhysicalDeviceShaderDemoteToHelperInvocationFeatures)(vulkan.vk.s.PhysicalDeviceShaderDemoteToHelperInvocationFeatures({
			sType = "physical_device_shader_demote_to_helper_invocation_features",
			pNext = pNextChain,
			shaderDemoteToHelperInvocation = 1,
		}))
		pNextChain = demoteFeatures
	end

	local deviceExtensions = vulkan.T.Array(ffi.typeof("const char*"))(#finalExtensions)

	for i, ext in ipairs(finalExtensions) do
		deviceExtensions[i - 1] = ext
	end

	local deviceCreateInfo = vulkan.vk.s.DeviceCreateInfo(
		{
			pNext = pNextChain,
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
			nullDescriptorEnabled = has_null_descriptor,
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
		vulkan.ext.vkCmdSetStencilTestEnableEXT = device:TryGetExtension("vkCmdSetStencilTestEnableEXT")
		vulkan.ext.vkCmdSetStencilOpEXT = device:TryGetExtension("vkCmdSetStencilOpEXT")
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
	local descriptor_info = nil
	local pBufferInfo = nil
	local pImageInfo = nil

	if type == "uniform_buffer" then
		local buffer = assert(...)
		-- Note: vulkan.vk.s.DescriptorBufferInfo is missing, use raw constructor via T.Array to get a pointer
		local info = vulkan.T.Array(vulkan.vk.VkDescriptorBufferInfo)(1)
		info[0].buffer = buffer.ptr[0]
		info[0].offset = 0
		info[0].range = buffer.size
		descriptor_info = info
		pBufferInfo = info
	elseif type == "storage_image" or type == "combined_image_sampler" then
		local info = vulkan.T.Array(vulkan.vk.VkDescriptorImageInfo)(1)
		
		if type == "storage_image" then
			local imageView = assert(...)
			local view_handle = (not imageView.__removed and imageView.ptr) and imageView.ptr[0] or nil
			
			info[0] = vulkan.vk.s.DescriptorImageInfo(
				{
					sampler = nil,
					imageView = view_handle,
					imageLayout = "general",
				}
			)
		else -- combined_image_sampler
			local imageView, sampler, fallback_view, fallback_sampler = select(1, ...)
			
			local view_handle = (not imageView.__removed and imageView.ptr) and imageView.ptr[0] or nil
			local sampler_handle = (not sampler.__removed and sampler.ptr) and sampler.ptr[0] or nil
			
			if (view_handle == nil or sampler_handle == nil) and not self.nullDescriptorEnabled and fallback_view then
				view_handle = view_handle or (fallback_view.ptr and fallback_view.ptr[0])
				sampler_handle = sampler_handle or (fallback_sampler and fallback_sampler.ptr and fallback_sampler.ptr[0])
			end

			info[0] = vulkan.vk.s.DescriptorImageInfo(
				{
					sampler = sampler_handle,
					imageView = view_handle,
					imageLayout = "shader_read_only_optimal",
				}
			)
		end
		descriptor_info = info
		pImageInfo = info
	else
		error("unsupported descriptor type: " .. tostring(type))
	end

	local descriptorWrite = vulkan.vk.s.WriteDescriptorSet(
		{
			dstSet = descriptorSet.ptr[0],
			dstBinding = binding_index,
			dstArrayElement = 0,
			descriptorType = type,
			descriptorCount = 1,
			pBufferInfo = pBufferInfo,
			pImageInfo = pImageInfo,
		}
	)

	vulkan.lib.vkUpdateDescriptorSets(self.ptr[0], 1, descriptorWrite, 0, nil)
end

function Device:UpdateDescriptorSetArray(descriptorSet, binding_index, texture_array, fallback_view, fallback_sampler)
	-- texture_array is an array of {view, sampler} tables
	local count = #texture_array

	if count == 0 then return end

	-- Create array of VkDescriptorImageInfo
	-- Note: Luajit VLAs (via ffi.new("Type[?]", count)) are NOT zero-initialized
	local imageInfoArray = vulkan.T.Array(vulkan.vk.VkDescriptorImageInfo)(count)
	ffi.fill(imageInfoArray, ffi.sizeof(imageInfoArray), 0)

	local fallback_view_handle = fallback_view and fallback_view.ptr and fallback_view.ptr[0]
	local fallback_sampler_handle = fallback_sampler and fallback_sampler.ptr and fallback_sampler.ptr[0]

	for i = 1, count do
		local tex = texture_array[i]
		
		local view_handle = nil
		local sampler_handle = nil

		if type(tex) == "table" and tex.view and type(tex.view.ptr) == "cdata" then
			-- Ensure we are not using a view that has been destroyed in Vulkan
			if not tex.view.__removed then
				local view_ptr = tex.view.ptr
				local sampler_ptr = tex.sampler and tex.sampler.ptr
				
				if view_ptr ~= nil and view_ptr[0] ~= nil then
					view_handle = view_ptr[0]
				end
				
				if type(sampler_ptr) == "cdata" and sampler_ptr ~= nil and sampler_ptr[0] ~= nil then
					sampler_handle = sampler_ptr[0]
				end
			end
		end

		if view_handle == nil and not self.nullDescriptorEnabled then
			view_handle = fallback_view_handle
			sampler_handle = fallback_sampler_handle or sampler_handle
		end

		imageInfoArray[i - 1] = vulkan.vk.s.DescriptorImageInfo(
			{
				sampler = sampler_handle,
				imageView = view_handle,
				imageLayout = "shader_read_only_optimal",
			}
		)
	end

	local descriptorWrite = vulkan.vk.s.WriteDescriptorSet(
		{
			dstSet = descriptorSet.ptr[0],
			dstBinding = binding_index,
			dstArrayElement = 0,
			descriptorType = "combined_image_sampler",
			descriptorCount = count,
			pImageInfo = imageInfoArray,
		}
	)
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
