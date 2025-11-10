local ffi = require("ffi")
local vk = require("bindings.vk")
local ffi_helpers = require("helpers.ffi_helpers")
local shaderc = require("bindings.shaderc")
local lib = vk.find_library()
local vulkan = {}
vulkan.vk = vk
vulkan.lib = lib
local enum_to_string = ffi_helpers.enum_to_string
local T = {Box = ffi_helpers.Box, Array = ffi_helpers.Array}
local enums = ffi_helpers.translate_enums(
	{
		{vk.VkVertexInputRate, "VK_VERTEX_INPUT_RATE_"},
		{vk.VkPrimitiveTopology, "VK_PRIMITIVE_TOPOLOGY_"},
		{vk.VkColorComponentFlagBits, "VK_COLOR_COMPONENT_", "_BIT"},
		{vk.VkPolygonMode, "VK_POLYGON_MODE_"},
		{vk.VkCullModeFlagBits, "VK_CULL_MODE_", "_BIT"},
		{vk.VkFrontFace, "VK_FRONT_FACE_"},
		{vk.VkSampleCountFlagBits, "VK_SAMPLE_COUNT_", "_BIT"},
		{vk.VkLogicOp, "VK_LOGIC_OP_"},
		{vk.VkCompareOp, "VK_COMPARE_OP_"},
		{vk.VkFormat, "VK_FORMAT_"},
		{vk.VkPresentModeKHR, "VK_PRESENT_MODE_", "_KHR"},
		{vk.VkCompositeAlphaFlagBitsKHR, "VK_COMPOSITE_ALPHA_", "_BIT_KHR"},
		{vk.VkImageUsageFlagBits, "VK_IMAGE_USAGE_", "_BIT"},
		{vk.VkBufferUsageFlagBits, "VK_BUFFER_USAGE_", "_BIT"},
		{vk.VkMemoryPropertyFlagBits, "VK_MEMORY_PROPERTY_", "_BIT"},
		{vk.VkShaderStageFlagBits, "VK_SHADER_STAGE_", "_BIT"},
		{vk.VkDescriptorType, "VK_DESCRIPTOR_TYPE_"},
		{vk.VkColorSpaceKHR, "VK_COLOR_SPACE_"},
		{vk.VkImageAspectFlagBits, "VK_IMAGE_ASPECT_", "_BIT"},
		{vk.VkAccessFlagBits, "VK_ACCESS_", "_BIT"},
		{vk.VkImageLayout, "VK_IMAGE_LAYOUT_"},
		{vk.VkPipelineBindPoint, "VK_PIPELINE_BIND_POINT_"},
		{vk.VkDynamicState, "VK_DYNAMIC_STATE_"},
		{vk.VkImageViewType, "VK_IMAGE_VIEW_TYPE_"},
		{vk.VkFilter, "VK_FILTER_"},
		{vk.VkSamplerMipmapMode, "VK_SAMPLER_MIPMAP_MODE_"},
		{vk.VkSamplerAddressMode, "VK_SAMPLER_ADDRESS_MODE_"},
		{vk.VkIndexType, "VK_INDEX_TYPE_"},
		{vk.VkBlendFactor, "VK_BLEND_FACTOR_"},
		{vk.VkBlendOp, "VK_BLEND_OP_"},
	}
)
-- Export enums for use in applications
vulkan.enums = enums

local function vk_assert(result, msg)
	if result ~= 0 then
		msg = msg or "Vulkan error"
		local enum_str = enum_to_string(result) or ("error code - " .. tostring(result))
		error(msg .. " : " .. enum_str, 2)
	end
end

function vulkan.GetAvailableLayers()
	-- First, enumerate available layers
	local layerCount = ffi.new("uint32_t[1]", 0)
	lib.vkEnumerateInstanceLayerProperties(layerCount, nil)
	local out = {}

	if layerCount[0] > 0 then
		local availableLayers = T.Array(vk.VkLayerProperties)(layerCount[0])
		lib.vkEnumerateInstanceLayerProperties(layerCount, availableLayers)

		for i = 0, layerCount[0] - 1 do
			local layerName = ffi.string(availableLayers[i].layerName)
			table.insert(out, layerName)
		end
	end

	return out
end

function vulkan.GetAvailableExtensions()
	-- First, enumerate available extensions
	local extensionCount = ffi.new("uint32_t[1]", 0)
	lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, nil)
	local out = {}

	if extensionCount[0] > 0 then
		local availableExtensions = T.Array(vk.VkExtensionProperties)(extensionCount[0])
		lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, availableExtensions)

		for i = 0, extensionCount[0] - 1 do
			local extensionName = ffi.string(availableExtensions[i].extensionName)
			table.insert(out, extensionName)
		end
	end

	return out
end

do
	local function major(ver)
		return bit.rshift(ver, 22)
	end

	local function minor(ver)
		return bit.band(bit.rshift(ver, 12), 0x3FF)
	end

	local function patch(ver)
		return bit.band(ver, 0xFFF)
	end

	function vulkan.VersionToString(ver)
		return string.format("%d.%d.%d", major(ver), minor(ver), patch(ver))
	end

	function vulkan.GetVersion()
		local version = ffi.new("uint32_t[1]", 0)
		lib.vkEnumerateInstanceVersion(version)
		return vulkan.VersionToString(version[0])
	end
end

do -- instance
	local Instance = {}
	Instance.__index = Instance

	function vulkan.CreateInstance(extensions, layers)
		print("layers available:")

		for k, v in ipairs(vulkan.GetAvailableLayers()) do
			print("\t" .. v)
		end

		print("extensions available:")

		for k, v in ipairs(vulkan.GetAvailableExtensions()) do
			print("\t" .. v)
		end

		local version = vk.VK_API_VERSION_1_4
		print("requesting version: " .. vulkan.VersionToString(version))
		local appInfo = T.Box(
			vk.VkApplicationInfo,
			{
				sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
				pApplicationName = "MoltenVK LuaJIT Example",
				applicationVersion = 1,
				pEngineName = "No Engine",
				engineVersion = 1,
				apiVersion = version,
			}
		)
		print("version loaded: " .. vulkan.GetVersion())
		local extension_names = extensions and
			T.Array(ffi.typeof("const char*"), #extensions, extensions) or
			nil
		local layer_names = layers and T.Array(ffi.typeof("const char*"), #layers, layers) or nil
		local createInfo = T.Box(
			vk.VkInstanceCreateInfo,
			{
				sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
				pNext = nil,
				flags = vk.VkInstanceCreateFlagBits("VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR"),
				pApplicationInfo = appInfo,
				enabledLayerCount = layers and #layers or 0,
				ppEnabledLayerNames = layer_names,
				enabledExtensionCount = extensions and #extensions or 0,
				ppEnabledExtensionNames = extension_names,
			}
		)
		local ptr = T.Box(vk.VkInstance)()
		vk_assert(lib.vkCreateInstance(createInfo, nil, ptr), "failed to create vulkan instance")
		return setmetatable({ptr = ptr}, Instance)
	end

	function Instance:__gc()
		lib.vkDestroyInstance(self.ptr[0], nil)
	end

	do -- metal surface
		local Surface = {}
		Surface.__index = Surface

		function Instance:CreateMetalSurface(metal_layer)
			assert(metal_layer ~= nil, "metal_layer cannot be nil")
			local surfaceCreateInfo = vk.VkMetalSurfaceCreateInfoEXT(
				{
					sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
					pNext = nil,
					flags = 0,
					pLayer = ffi.cast("const void*", metal_layer),
				}
			)
			local ptr = T.Box(vk.VkSurfaceKHR)()
			local vkCreateMetalSurfaceEXT = vk.GetExtension(lib, self.ptr[0], "vkCreateMetalSurfaceEXT")
			vk_assert(
				vkCreateMetalSurfaceEXT(self.ptr[0], surfaceCreateInfo, nil, ptr),
				"failed to create metal surface"
			)
			return setmetatable({ptr = ptr, instance = self}, Surface)
		end

		function Instance:__gc()
			if self.instance then
				lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
			end
		end
	end

	do -- physicalDevice
		local PhysicalDevice = {}
		PhysicalDevice.__index = PhysicalDevice

		function Instance:GetPhysicalDevices()
			local deviceCount = ffi.new("uint32_t[1]", 0)
			vk_assert(
				lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, nil),
				"failed to enumerate physical devices"
			)

			if deviceCount[0] == 0 then error("no physical devices found") end

			local physicalDevices = T.Array(vk.VkPhysicalDevice)(deviceCount[0])
			vk_assert(
				lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, physicalDevices),
				"failed to enumerate physical devices"
			)
			local out = {}

			for i = 0, deviceCount[0] - 1 do
				out[i + 1] = setmetatable({ptr = physicalDevices[i]}, PhysicalDevice)
			end

			return out
		end

		function PhysicalDevice:FindGraphicsQueueFamily(surface)
			local graphicsQueueFamily = nil

			for i, queueFamily in ipairs(self:GetQueueFamilyProperties()) do
				local queueFlags = queueFamily.queueFlags
				local graphicsBit = vk.VkQueueFlagBits("VK_QUEUE_GRAPHICS_BIT")

				if bit.band(queueFlags, graphicsBit) ~= 0 then
					if not graphicsQueueFamily then graphicsQueueFamily = i - 1 end
				end

				local presentSupport = ffi.new("uint32_t[1]", 0)
				lib.vkGetPhysicalDeviceSurfaceSupportKHR(self.ptr, i - 1, surface.ptr[0], presentSupport)

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
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, nil)
			local count = formatCount[0]
			local formats = T.Array(vk.VkSurfaceFormatKHR)(count)
			lib.vkGetPhysicalDeviceSurfaceFormatsKHR(self.ptr, surface.ptr[0], formatCount, formats)
			-- Convert to Lua table
			local result = {}

			for i = 0, count - 1 do
				result[i + 1] = {
					format = enums.VK_FORMAT_.to_string(formats[i].format),
					color_space = enums.VK_COLOR_SPACE_.to_string(formats[i].colorSpace),
				}
			end

			return result
		end

		function PhysicalDevice:GetQueueFamilyProperties()
			local count = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, count, nil)
			local queue_family_count = count[0]
			local queue_families = T.Array(vk.VkQueueFamilyProperties)(queue_family_count)
			lib.vkGetPhysicalDeviceQueueFamilyProperties(self.ptr, count, queue_families)
			local result = {}

			for i = 0, queue_family_count - 1 do
				result[i + 1] = queue_families[i]
			end

			return result
		end

		function PhysicalDevice:GetSurfaceCapabilities(surface)
			local surfaceCapabilities = T.Box(vk.VkSurfaceCapabilitiesKHR)()
			vk_assert(
				lib.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.ptr, surface.ptr[0], surfaceCapabilities),
				"failed to get surface capabilities"
			)
			return surfaceCapabilities
		end

		function PhysicalDevice:GetPresentModes(surface)
			local presentModeCount = ffi.new("uint32_t[1]", 0)
			lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr, surface.ptr[0], presentModeCount, nil)
			local count = presentModeCount[0]
			local presentModes = T.Array(vk.VkPresentModeKHR)(count)
			lib.vkGetPhysicalDeviceSurfacePresentModesKHR(self.ptr, surface.ptr[0], presentModeCount, presentModes)
			-- Convert to Lua table
			local result = {}

			for i = 0, count - 1 do
				result[i + 1] = presentModes[i]
			end

			return result
		end

		do -- device
			local Device = {}
			Device.__index = Device

			function PhysicalDevice:CreateDevice(extensions, graphicsQueueFamily)
				-- Check if VK_KHR_portability_subset is supported and add it if needed
				local extensionCount = ffi.new("uint32_t[1]", 0)
				lib.vkEnumerateDeviceExtensionProperties(self.ptr, nil, extensionCount, nil)
				local availableExtensions = T.Array(vk.VkExtensionProperties)(extensionCount[0])
				lib.vkEnumerateDeviceExtensionProperties(self.ptr, nil, extensionCount, availableExtensions)
				local hasPortabilitySubset = false

				for i = 0, extensionCount[0] - 1 do
					local extName = ffi.string(availableExtensions[i].extensionName)

					if extName == "VK_KHR_portability_subset" then
						hasPortabilitySubset = true

						break
					end
				end

				-- Add portability subset and its dependency if supported
				local finalExtensions = {}

				for i, ext in ipairs(extensions) do
					finalExtensions[i] = ext
				end

				if hasPortabilitySubset then
					-- VK_KHR_portability_subset requires VK_KHR_get_physical_device_properties2
					-- but this extension is promoted to core in Vulkan 1.1, so it's likely already available
					table.insert(finalExtensions, "VK_KHR_portability_subset")
					-- Only add the dependency if not already present
					local hasGetProps2 = false

					for _, ext in ipairs(finalExtensions) do
						if ext == "VK_KHR_get_physical_device_properties2" then
							hasGetProps2 = true

							break
						end
					end

					if not hasGetProps2 then
						-- Check if this extension is available
						for i = 0, extensionCount[0] - 1 do
							local extName = ffi.string(availableExtensions[i].extensionName)

							if extName == "VK_KHR_get_physical_device_properties2" then
								table.insert(finalExtensions, "VK_KHR_get_physical_device_properties2")

								break
							end
						end
					end
				end

				local queuePriority = ffi.new("float[1]", 1.0)
				local queueCreateInfo = T.Box(
					vk.VkDeviceQueueCreateInfo,
					{
						sType = "VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO",
						queueFamilyIndex = graphicsQueueFamily,
						queueCount = 1,
						pQueuePriorities = queuePriority,
					}
				)
				local deviceExtensions = T.Array(ffi.typeof("const char*"), #finalExtensions, finalExtensions)
				local deviceCreateInfo = T.Box(
					vk.VkDeviceCreateInfo,
					{
						sType = "VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO",
						queueCreateInfoCount = 1,
						pQueueCreateInfos = queueCreateInfo,
						enabledExtensionCount = #finalExtensions,
						ppEnabledExtensionNames = deviceExtensions,
					}
				)
				local ptr = T.Box(vk.VkDevice)()
				vk_assert(
					lib.vkCreateDevice(self.ptr, deviceCreateInfo, nil, ptr),
					"failed to create device"
				)
				return setmetatable({ptr = ptr, physical_device = self}, Device)
			end

			function Device:WaitIdle()
				lib.vkDeviceWaitIdle(self.ptr[0])
			end

			function Device:__gc()
				lib.vkDestroyDevice(self.ptr[0], nil)
			end

			do -- shader
				local ShaderModule = {}
				ShaderModule.__index = ShaderModule

				function Device:CreateShaderModule(glsl, type)
					local spirv_data, spirv_size = shaderc.compile(glsl, type)
					local shaderModuleCreateInfo = T.Box(
						vk.VkShaderModuleCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO",
							codeSize = spirv_size,
							pCode = ffi.cast("const uint32_t*", spirv_data),
						}
					)
					local ptr = T.Box(vk.VkShaderModule)()
					vk_assert(
						lib.vkCreateShaderModule(self.ptr[0], shaderModuleCreateInfo, nil, ptr),
						"failed to create shader module"
					)
					return setmetatable({ptr = ptr, device = self}, ShaderModule)
				end

				function ShaderModule:__gc()
					lib.vkDestroyShaderModule(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- queue
				local Queue = {}
				Queue.__index = Queue

				function Device:GetQueue(graphicsQueueFamily)
					local deviceQueue = T.Box(vk.VkQueue)()
					lib.vkGetDeviceQueue(self.ptr[0], graphicsQueueFamily, 0, deviceQueue)
					return setmetatable({ptr = deviceQueue}, Queue)
				end

				function Queue:Submit(
					commandBuffer,
					imageAvailableSemaphore,
					renderFinishedSemaphore,
					inFlightFence
				)
					local waitStages = ffi.new(
						"uint32_t[1]",
						vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT")
					)
					local submitInfo = T.Box(
						vk.VkSubmitInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SUBMIT_INFO",
							waitSemaphoreCount = 1,
							pWaitSemaphores = imageAvailableSemaphore.ptr,
							pWaitDstStageMask = waitStages,
							commandBufferCount = 1,
							pCommandBuffers = commandBuffer.ptr,
							signalSemaphoreCount = 1,
							pSignalSemaphores = renderFinishedSemaphore.ptr,
						}
					)
					vk_assert(
						lib.vkQueueSubmit(self.ptr[0], 1, submitInfo, inFlightFence.ptr[0]),
						"failed to submit queue"
					)
				end

				function Queue:SubmitAndWait(device, commandBuffer, fence)
					lib.vkResetFences(device.ptr[0], 1, fence.ptr)
					local submitInfo = T.Box(
						vk.VkSubmitInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SUBMIT_INFO",
							commandBufferCount = 1,
							pCommandBuffers = commandBuffer.ptr,
						}
					)
					vk_assert(
						lib.vkQueueSubmit(self.ptr[0], 1, submitInfo, fence.ptr[0]),
						"failed to submit queue"
					)
					lib.vkWaitForFences(device.ptr[0], 1, fence.ptr, 1, ffi.cast("uint64_t", -1))
				end
			end

			do -- swapchain
				local Swapchain = {}
				Swapchain.__index = Swapchain

				-- config options:
				--   presentMode: VkPresentModeKHR (default: "VK_PRESENT_MODE_FIFO_KHR")
				--   imageCount: number of images in swapchain (default: surfaceCapabilities.minImageCount)
				--   compositeAlpha: VkCompositeAlphaFlagBitsKHR (default: "VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR")
				--   clipped: boolean (default: true)
				--   imageUsage: VkImageUsageFlags (default: COLOR_ATTACHMENT_BIT | TRANSFER_DST_BIT)
				--   preTransform: VkSurfaceTransformFlagBitsKHR (default: currentTransform)
				function Device:CreateSwapchain(surface, surfaceFormat, surfaceCapabilities, config, old_swapchain)
					config = config or {}
					local imageCount = config.imageCount or surfaceCapabilities[0].minImageCount
					local presentMode = enums.VK_PRESENT_MODE_(config.presentMode or "fifo")
					local compositeAlpha = enums.VK_COMPOSITE_ALPHA_(config.compositeAlpha or "opaque")
					local clipped = config.clipped ~= nil and (config.clipped and 1 or 0) or 1
					local preTransform = config.preTransform or surfaceCapabilities[0].currentTransform
					local imageUsage = enums.VK_IMAGE_USAGE_(config.imageUsage or {"color_attachment", "transfer_dst"})

					-- Clamp image count to valid range
					if imageCount < surfaceCapabilities[0].minImageCount then
						imageCount = surfaceCapabilities[0].minImageCount
					end

					if
						surfaceCapabilities[0].maxImageCount > 0 and
						imageCount > surfaceCapabilities[0].maxImageCount
					then
						imageCount = surfaceCapabilities[0].maxImageCount
					end

					local swapchainCreateInfo = T.Box(
						vk.VkSwapchainCreateInfoKHR,
						{
							sType = "VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR",
							surface = surface.ptr[0],
							minImageCount = imageCount,
							imageFormat = enums.VK_FORMAT_(surfaceFormat.format),
							imageColorSpace = enums.VK_COLOR_SPACE_(surfaceFormat.color_space),
							imageExtent = surfaceCapabilities[0].currentExtent,
							imageArrayLayers = 1,
							imageUsage = imageUsage,
							imageSharingMode = "VK_SHARING_MODE_EXCLUSIVE",
							preTransform = preTransform,
							compositeAlpha = vk.VkCompositeAlphaFlagBitsKHR(compositeAlpha),
							presentMode = presentMode,
							clipped = clipped,
							oldSwapchain = old_swapchain and old_swapchain.ptr[0],
						}
					)
					local ptr = T.Box(vk.VkSwapchainKHR)()
					vk_assert(
						lib.vkCreateSwapchainKHR(self.ptr[0], swapchainCreateInfo, nil, ptr),
						"failed to create swapchain"
					)
					return setmetatable({ptr = ptr, device = self}, Swapchain)
				end

				function Swapchain:__gc()
					lib.vkDestroySwapchainKHR(self.device.ptr[0], self.ptr[0], nil)
				end

				function Swapchain:GetImages()
					local imageCount = ffi.new("uint32_t[1]", 0)
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, nil)
					local swapchainImages = T.Array(vk.VkImage)(imageCount[0])
					lib.vkGetSwapchainImagesKHR(self.device.ptr[0], self.ptr[0], imageCount, swapchainImages)
					local out = {}

					for i = 0, imageCount[0] - 1 do
						out[i + 1] = swapchainImages[i]
					end

					return out
				end

				function Swapchain:GetNextImage(imageAvailableSemaphore)
					local imageIndex = ffi.new("uint32_t[1]", 0)
					local result = lib.vkAcquireNextImageKHR(
						self.device.ptr[0],
						self.ptr[0],
						ffi.cast("uint64_t", -1),
						imageAvailableSemaphore.ptr[0],
						nil,
						imageIndex
					)

					if result == vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
						return nil, "out_of_date"
					elseif result == vk.VkResult("VK_SUBOPTIMAL_KHR") then
						return imageIndex[0], "suboptimal"
					elseif result ~= 0 then
						error("failed to acquire next image: " .. enum_to_string(result))
					end

					return imageIndex[0], "ok"
				end

				function Swapchain:Present(renderFinishedSemaphore, deviceQueue, imageIndex)
					local presentInfo = T.Box(
						vk.VkPresentInfoKHR,
						{
							sType = "VK_STRUCTURE_TYPE_PRESENT_INFO_KHR",
							waitSemaphoreCount = 1,
							pWaitSemaphores = renderFinishedSemaphore.ptr,
							swapchainCount = 1,
							pSwapchains = self.ptr,
							pImageIndices = imageIndex,
						}
					)
					local result = lib.vkQueuePresentKHR(deviceQueue.ptr[0], presentInfo)

					if result == vk.VkResult("VK_ERROR_OUT_OF_DATE_KHR") then
						return false
					elseif result == vk.VkResult("VK_SUBOPTIMAL_KHR") then
						return false
					elseif result ~= vk.VkResult("VK_SUCCESS") then
						error("failed to present: " .. enum_to_string(result))
					end

					return true
				end
			end

			do -- commandPool
				local CommandPool = {}
				CommandPool.__index = CommandPool

				function Device:CreateCommandPool(graphicsQueueFamily)
					local commandPoolCreateInfo = T.Box(
						vk.VkCommandPoolCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO",
							queueFamilyIndex = graphicsQueueFamily,
							flags = vk.VkCommandPoolCreateFlagBits("VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT"),
						}
					)
					local ptr = T.Box(vk.VkCommandPool)()
					vk_assert(
						lib.vkCreateCommandPool(self.ptr[0], commandPoolCreateInfo, nil, ptr),
						"failed to create command pool"
					)
					return setmetatable({ptr = ptr, device = self}, CommandPool)
				end

				function CommandPool:__gc()
					lib.vkDestroyCommandPool(self.device.ptr[0], self.ptr[0], nil)
				end

				do -- commandBuffer
					local CommandBuffer = {}
					CommandBuffer.__index = CommandBuffer

					function CommandPool:CreateCommandBuffer()
						local commandBufferAllocInfo = T.Box(
							vk.VkCommandBufferAllocateInfo,
							{
								sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO",
								commandPool = self.ptr[0],
								level = "VK_COMMAND_BUFFER_LEVEL_PRIMARY",
								commandBufferCount = 1,
							}
						)
						local commandBuffer = T.Box(vk.VkCommandBuffer)()
						vk_assert(
							lib.vkAllocateCommandBuffers(self.device.ptr[0], commandBufferAllocInfo, commandBuffer),
							"failed to allocate command buffer"
						)
						return setmetatable({ptr = commandBuffer}, CommandBuffer)
					end

					function CommandBuffer:Begin()
						local beginInfo = T.Box(
							vk.VkCommandBufferBeginInfo,
							{
								sType = "VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO",
								flags = vk.VkCommandBufferUsageFlagBits("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT"),
							}
						)
						vk_assert(
							lib.vkBeginCommandBuffer(self.ptr[0], beginInfo),
							"failed to begin command buffer"
						)
					end

					function CommandBuffer:Reset()
						lib.vkResetCommandBuffer(self.ptr[0], 0)
					end

					function CommandBuffer:CreateImageMemoryBarrier(imageIndex, swapchainImages, isFirstFrame)
						-- For first frame, transition from UNDEFINED
						-- For subsequent frames, transition from PRESENT_SRC_KHR (what the render pass leaves it in)
						local oldLayout = isFirstFrame and "VK_IMAGE_LAYOUT_UNDEFINED" or "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
						local barrier = T.Box(
							vk.VkImageMemoryBarrier,
							{
								sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
								oldLayout = oldLayout,
								newLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
								srcQueueFamilyIndex = 0xFFFFFFFF,
								dstQueueFamilyIndex = 0xFFFFFFFF,
								image = swapchainImages[imageIndex],
								subresourceRange = {
									aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
									baseMipLevel = 0,
									levelCount = 1,
									baseArrayLayer = 0,
									layerCount = 1,
								},
								srcAccessMask = 0,
								dstAccessMask = vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
							}
						)
						return barrier
					end

					function CommandBuffer:StartPipelineBarrier(barrier)
						lib.vkCmdPipelineBarrier(
							self.ptr[0],
							vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT"),
							vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
							0,
							0,
							nil,
							0,
							nil,
							1,
							barrier
						)
					end

					function CommandBuffer:EndPipelineBarrier(barrier)
						barrier[0].oldLayout = "VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL"
						barrier[0].newLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR"
						barrier[0].srcAccessMask = vk.VkAccessFlagBits("VK_ACCESS_TRANSFER_WRITE_BIT")
						barrier[0].dstAccessMask = 0
						lib.vkCmdPipelineBarrier(
							self.ptr[0],
							vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
							vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT"),
							0,
							0,
							nil,
							0,
							nil,
							1,
							barrier
						)
					end

					function CommandBuffer:End()
						vk_assert(lib.vkEndCommandBuffer(self.ptr[0]), "failed to end command buffer")
					end

					function CommandBuffer:BeginRenderPass(renderPass, framebuffer, extent, clearColor, clearDepth)
						clearColor = clearColor or {0.0, 0.0, 0.0, 1.0}
						clearDepth = clearDepth or 1.0
						local clearValues
						local clearValueCount

						if renderPass.has_depth then
							-- Render pass has depth attachment, provide 2 clear values
							clearValues = T.Array(
								vk.VkClearValue,
								2,
								{
									{
										color = {
											float32 = clearColor,
										},
									},
									{
										depthStencil = {
											depth = clearDepth,
											stencil = 0,
										},
									},
								}
							)
							clearValueCount = 2
						else
							-- No depth attachment, only 1 clear value
							clearValues = T.Box(
								vk.VkClearValue,
								{
									color = {
										float32 = clearColor,
									},
								}
							)
							clearValueCount = 1
						end

						local renderPassInfo = T.Box(
							vk.VkRenderPassBeginInfo,
							{
								sType = "VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO",
								renderPass = renderPass.ptr[0],
								framebuffer = framebuffer.ptr[0],
								renderArea = {
									offset = {x = 0, y = 0},
									extent = extent,
								},
								clearValueCount = clearValueCount,
								pClearValues = clearValues,
							}
						)
						lib.vkCmdBeginRenderPass(
							self.ptr[0],
							renderPassInfo,
							vk.VkSubpassContents("VK_SUBPASS_CONTENTS_INLINE")
						)
					end

					function CommandBuffer:EndRenderPass()
						lib.vkCmdEndRenderPass(self.ptr[0])
					end

					function CommandBuffer:BindPipeline(pipeline, type)
						lib.vkCmdBindPipeline(self.ptr[0], enums.VK_PIPELINE_BIND_POINT_(type), pipeline.ptr[0])
					end

					function CommandBuffer:BindVertexBuffers(firstBinding, buffers, offsets)
						-- buffers is an array of Buffer objects
						-- offsets is optional array of offsets
						local bufferCount = #buffers
						local bufferArray = T.Array(vk.VkBuffer)(bufferCount)
						local offsetArray = T.Array(vk.VkDeviceSize)(bufferCount)

						for i, buffer in ipairs(buffers) do
							bufferArray[i - 1] = buffer.ptr[0]
							offsetArray[i - 1] = offsets and offsets[i] or 0
						end

						lib.vkCmdBindVertexBuffers(
							self.ptr[0],
							firstBinding or 0,
							bufferCount,
							bufferArray,
							offsetArray
						)
					end

					function CommandBuffer:BindVertexBuffer(buffer, binding, offset)
						self:BindVertexBuffers(binding, {buffer}, offset and {offset} or nil)
					end

					function CommandBuffer:BindDescriptorSets(type, pipelineLayout, descriptorSets, firstSet)
						-- descriptorSets is an array of descriptor set objects
						local setCount = #descriptorSets
						local setArray = T.Array(vk.VkDescriptorSet)(setCount)

						for i, ds in ipairs(descriptorSets) do
							setArray[i - 1] = ds.ptr[0]
						end

						lib.vkCmdBindDescriptorSets(
							self.ptr[0],
							enums.VK_PIPELINE_BIND_POINT_(type),
							pipelineLayout.ptr[0],
							firstSet or 0,
							setCount,
							setArray,
							0,
							nil
						)
					end

					function CommandBuffer:Draw(vertexCount, instanceCount, firstVertex, firstInstance)
						lib.vkCmdDraw(
							self.ptr[0],
							vertexCount or 3,
							instanceCount or 1,
							firstVertex or 0,
							firstInstance or 0
						)
					end

					function CommandBuffer:BindIndexBuffer(buffer, offset, indexType)
						indexType = indexType or "uint32"
						lib.vkCmdBindIndexBuffer(self.ptr[0], buffer.ptr[0], offset, enums.VK_INDEX_TYPE_(indexType))
					end

					function CommandBuffer:DrawIndexed(indexCount, instanceCount, firstIndex, vertexOffset, firstInstance)
						lib.vkCmdDrawIndexed(
							self.ptr[0],
							indexCount,
							instanceCount or 1,
							firstIndex or 0,
							vertexOffset or 0,
							firstInstance or 0
						)
					end

					function CommandBuffer:SetViewport(x, y, width, height, minDepth, maxDepth)
						local viewport = T.Box(
							vk.VkViewport,
							{
								x = x or 0.0,
								y = y or 0.0,
								width = width,
								height = height,
								minDepth = minDepth or 0.0,
								maxDepth = maxDepth or 1.0,
							}
						)
						lib.vkCmdSetViewport(self.ptr[0], 0, 1, viewport)
					end

					function CommandBuffer:SetScissor(x, y, width, height)
						local scissor = T.Box(
							vk.VkRect2D,
							{
								offset = {x = x or 0, y = y or 0},
								extent = {width = width, height = height},
							}
						)
						lib.vkCmdSetScissor(self.ptr[0], 0, 1, scissor)
					end

					function CommandBuffer:PushConstants(layout, stage, binding, data_size, data)
						lib.vkCmdPushConstants(self.ptr[0], layout.ptr[0], enums.VK_SHADER_STAGE_(stage), binding, data_size, data)
					end

					function CommandBuffer:ClearColorImage(config)
						local range = T.Box(
							vk.VkImageSubresourceRange,
							{
								aspectMask = enums.VK_IMAGE_ASPECT_(config.aspect_mask or "color"),
								baseMipLevel = config.base_mip_level or 0,
								levelCount = config.level_count or 1,
								baseArrayLayer = config.base_array_layer or 0,
								layerCount = config.layer_count or 1,
							}
						)
						lib.vkCmdClearColorImage(
							self.ptr[0],
							config.image,
							"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
							T.Box(
								vk.VkClearColorValue,
								{
									float32 = config.color or {0.0, 0.0, 0.0, 1.0},
								}
							),
							1,
							range
						)
					end

					function CommandBuffer:Dispatch(groupCountX, groupCountY, groupCountZ)
						lib.vkCmdDispatch(self.ptr[0], groupCountX or 1, groupCountY or 1, groupCountZ or 1)
					end

					function CommandBuffer:PipelineBarrier(config)
						-- Map stage names to pipeline stage flags
						local stage_map = {
							compute = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT"),
							fragment = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT"),
							transfer = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_TRANSFER_BIT"),
							vertex = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_VERTEX_SHADER_BIT"),
							all_commands = vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_ALL_COMMANDS_BIT"),
						}
						local srcStage = stage_map[config.srcStage or "compute"]
						local dstStage = stage_map[config.dstStage or "fragment"]
						local imageBarriers = nil
						local imageBarrierCount = 0

						if config.imageBarriers then
							imageBarrierCount = #config.imageBarriers
							imageBarriers = T.Array(vk.VkImageMemoryBarrier)(imageBarrierCount)

							for i, barrier in ipairs(config.imageBarriers) do
								imageBarriers[i - 1] = vk.VkImageMemoryBarrier(
									{
										sType = "VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER",
										srcAccessMask = vulkan.enums.VK_ACCESS_(barrier.srcAccessMask or "none"),
										dstAccessMask = vulkan.enums.VK_ACCESS_(barrier.dstAccessMask or "none"),
										oldLayout = enums.VK_IMAGE_LAYOUT_(barrier.oldLayout or "undefined"),
										newLayout = enums.VK_IMAGE_LAYOUT_(barrier.newLayout or "general"),
										srcQueueFamilyIndex = 0xFFFFFFFF,
										dstQueueFamilyIndex = 0xFFFFFFFF,
										image = barrier.image.ptr[0],
										subresourceRange = {
											aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
											baseMipLevel = 0,
											levelCount = 1,
											baseArrayLayer = 0,
											layerCount = 1,
										},
									}
								)
							end
						end

						lib.vkCmdPipelineBarrier(
							self.ptr[0],
							srcStage,
							dstStage,
							0,
							0,
							nil,
							0,
							nil,
							imageBarrierCount,
							imageBarriers
						)
					end

					function CommandBuffer:CopyImageToImage(srcImage, dstImage, width, height)
						local region = T.Box(
							vk.VkImageCopy,
							{
								srcSubresource = {
									aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
									mipLevel = 0,
									baseArrayLayer = 0,
									layerCount = 1,
								},
								srcOffset = {x = 0, y = 0, z = 0},
								dstSubresource = {
									aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
									mipLevel = 0,
									baseArrayLayer = 0,
									layerCount = 1,
								},
								dstOffset = {x = 0, y = 0, z = 0},
								extent = {width = width, height = height, depth = 1},
							}
						)
						lib.vkCmdCopyImage(
							self.ptr[0],
							srcImage,
							"VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL",
							dstImage,
							"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
							1,
							region
						)
					end

					function CommandBuffer:CopyBufferToImage(buffer, image, width, height)
						local region = T.Box(
							vk.VkBufferImageCopy,
							{
								bufferOffset = 0,
								bufferRowLength = 0,
								bufferImageHeight = 0,
								imageSubresource = {
									aspectMask = vk.VkImageAspectFlagBits("VK_IMAGE_ASPECT_COLOR_BIT"),
									mipLevel = 0,
									baseArrayLayer = 0,
									layerCount = 1,
								},
								imageOffset = {x = 0, y = 0, z = 0},
								imageExtent = {width = width, height = height, depth = 1},
							}
						)
						lib.vkCmdCopyBufferToImage(
							self.ptr[0],
							buffer.ptr[0],
							image.ptr[0],
							"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL",
							1,
							region
						)
					end
				end
			end

			do -- buffer
				local Buffer = {}
				Buffer.__index = Buffer

				function Device:FindMemoryType(typeFilter, properties)
					local memProperties = T.Box(vk.VkPhysicalDeviceMemoryProperties)()
					lib.vkGetPhysicalDeviceMemoryProperties(self.physical_device.ptr, memProperties)

					for i = 0, memProperties[0].memoryTypeCount - 1 do
						if
							bit.band(typeFilter, bit.lshift(1, i)) ~= 0 and
							bit.band(memProperties[0].memoryTypes[i].propertyFlags, properties) == properties
						then
							return i
						end
					end

					error("failed to find suitable memory type!")
				end

				function Device:CreateBuffer(size, usage, properties)
					usage = enums.VK_BUFFER_USAGE_(usage)
					properties = enums.VK_MEMORY_PROPERTY_(properties or {"host_visible", "host_coherent"})
					local bufferInfo = T.Box(
						vk.VkBufferCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO",
							size = size,
							usage = usage,
							sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
						}
					)
					local buffer_ptr = T.Box(vk.VkBuffer)()
					vk_assert(
						lib.vkCreateBuffer(self.ptr[0], bufferInfo, nil, buffer_ptr),
						"failed to create buffer"
					)
					local memRequirements = T.Box(vk.VkMemoryRequirements)()
					lib.vkGetBufferMemoryRequirements(self.ptr[0], buffer_ptr[0], memRequirements)
					local allocInfo = T.Box(
						vk.VkMemoryAllocateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO",
							allocationSize = memRequirements[0].size,
							memoryTypeIndex = self:FindMemoryType(memRequirements[0].memoryTypeBits, properties),
						}
					)
					local memory_ptr = T.Box(vk.VkDeviceMemory)()
					vk_assert(
						lib.vkAllocateMemory(self.ptr[0], allocInfo, nil, memory_ptr),
						"failed to allocate buffer memory"
					)
					lib.vkBindBufferMemory(self.ptr[0], buffer_ptr[0], memory_ptr[0], 0)
					return setmetatable(
						{
							ptr = buffer_ptr,
							memory = memory_ptr,
							size = size,
							device = self,
						},
						Buffer
					)
				end

				function Buffer:Map()
					local data = ffi.new("void*[1]")
					lib.vkMapMemory(self.device.ptr[0], self.memory[0], 0, self.size, 0, data)
					return data[0]
				end

				function Buffer:Unmap()
					lib.vkUnmapMemory(self.device.ptr[0], self.memory[0])
				end

				function Buffer:CopyData(src_data, size)
					local data = self:Map()
					ffi.copy(data, src_data, size or self.size)
					self:Unmap()
				end

				function Buffer:__gc()
					lib.vkDestroyBuffer(self.device.ptr[0], self.ptr[0], nil)
					lib.vkFreeMemory(self.device.ptr[0], self.memory[0], nil)
				end
			end

			do -- descriptor set layout
				local DescriptorSetLayout = {}
				DescriptorSetLayout.__index = DescriptorSetLayout

				function Device:CreateDescriptorSetLayout(bindings)
					-- bindings is an array of tables: {{binding, type, stageFlags, count}, ...}
					local bindingArray = T.Array(vk.VkDescriptorSetLayoutBinding)(#bindings)

					for i, b in ipairs(bindings) do
						bindingArray[i - 1].binding = assert(b.binding_index)
						bindingArray[i - 1].descriptorType = enums.VK_DESCRIPTOR_TYPE_(b.type)
						bindingArray[i - 1].descriptorCount = b.count or 1
						bindingArray[i - 1].stageFlags = enums.VK_SHADER_STAGE_(b.stageFlags)
						bindingArray[i - 1].pImmutableSamplers = nil
					end

					local layoutInfo = T.Box(
						vk.VkDescriptorSetLayoutCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO",
							bindingCount = #bindings,
							pBindings = bindingArray,
						}
					)
					local ptr = T.Box(vk.VkDescriptorSetLayout)()
					vk_assert(
						lib.vkCreateDescriptorSetLayout(self.ptr[0], layoutInfo, nil, ptr),
						"failed to create descriptor set layout"
					)
					return setmetatable({ptr = ptr, device = self, bindingArray = bindingArray}, DescriptorSetLayout)
				end

				function DescriptorSetLayout:__gc()
					lib.vkDestroyDescriptorSetLayout(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- descriptor pool
				local DescriptorPool = {}
				DescriptorPool.__index = DescriptorPool

				function Device:CreateDescriptorPool(poolSizes, maxSets)
					-- poolSizes is an array of tables: {{type, count}, ...}
					local poolSizeArray = T.Array(vk.VkDescriptorPoolSize)(#poolSizes)

					for i, ps in ipairs(poolSizes) do
						poolSizeArray[i - 1].type = enums.VK_DESCRIPTOR_TYPE_(ps.type)
						poolSizeArray[i - 1].descriptorCount = ps.count or 1
					end

					local poolInfo = T.Box(
						vk.VkDescriptorPoolCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO",
							poolSizeCount = #poolSizes,
							pPoolSizes = poolSizeArray,
							maxSets = maxSets or 1,
						}
					)
					local ptr = T.Box(vk.VkDescriptorPool)()
					vk_assert(
						lib.vkCreateDescriptorPool(self.ptr[0], poolInfo, nil, ptr),
						"failed to create descriptor pool"
					)
					return setmetatable({device = self, ptr = ptr, poolSizeArray = poolSizeArray}, DescriptorPool)
				end

				function DescriptorPool:AllocateDescriptorSet(layout)
					local allocInfo = T.Box(
						vk.VkDescriptorSetAllocateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO",
							descriptorPool = self.ptr[0],
							descriptorSetCount = 1,
							pSetLayouts = layout.ptr,
						}
					)
					local ptr = T.Box(vk.VkDescriptorSet)()
					vk_assert(
						lib.vkAllocateDescriptorSets(self.device.ptr[0], allocInfo, ptr),
						"failed to allocate descriptor set"
					)
					return {ptr = ptr, device = self.device}
				end

				function DescriptorPool:__gc()
					lib.vkDestroyDescriptorPool(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			function Device:UpdateDescriptorSet(type, descriptorSet, binding_index, ...)
				local descriptorWrite = T.Box(
					vk.VkWriteDescriptorSet,
					{
						sType = "VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET",
						dstSet = descriptorSet.ptr[0],
						dstBinding = binding_index,
						dstArrayElement = 0,
						descriptorType = enums.VK_DESCRIPTOR_TYPE_(type),
						descriptorCount = 1,
					}
				)
				local descriptor_info = nil

				if type == "uniform_buffer" then
					local buffer = assert(...)
					descriptor_info = T.Box(
						vk.VkDescriptorBufferInfo,
						{
							buffer = buffer.ptr[0],
							offset = 0,
							range = buffer.size,
						}
					)
					descriptorWrite[0].pBufferInfo = descriptor_info
				elseif type == "storage_image" then
					local imageView = assert(...)
					descriptor_info = T.Box(
						vk.VkDescriptorImageInfo,
						{
							sampler = nil,
							imageView = imageView.ptr[0],
							imageLayout = "VK_IMAGE_LAYOUT_GENERAL",
						}
					)
					descriptorWrite[0].pImageInfo = descriptor_info
				elseif type == "combined_image_sampler" then
					local imageView, sampler = assert(select(1, ...)), assert(select(2, ...))
					descriptor_info = T.Box(
						vk.VkDescriptorImageInfo,
						{
							sampler = sampler.ptr[0],
							imageView = imageView.ptr[0],
							imageLayout = "VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL",
						}
					)
					descriptorWrite[0].pImageInfo = descriptor_info
				else
					error("unsupported descriptor type: " .. tostring(type))
				end

				lib.vkUpdateDescriptorSets(self.ptr[0], 1, descriptorWrite, 0, nil)
			end

			do -- semaphore
				local Semaphore = {}
				Semaphore.__index = Semaphore

				function Device:CreateSemaphore()
					local semaphoreCreateInfo = T.Box(
						vk.VkSemaphoreCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO",
						}
					)
					local ptr = T.Box(vk.VkSemaphore)()
					vk_assert(
						lib.vkCreateSemaphore(self.ptr[0], semaphoreCreateInfo, nil, ptr),
						"failed to create semaphore"
					)
					return setmetatable({ptr = ptr, device = self}, Semaphore)
				end

				function Semaphore:__gc()
					lib.vkDestroySemaphore(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- fence
				local Fence = {}
				Fence.__index = Fence

				function Device:CreateFence()
					local fenceCreateInfo = T.Box(
						vk.VkFenceCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_FENCE_CREATE_INFO",
							flags = vk.VkFenceCreateFlagBits("VK_FENCE_CREATE_SIGNALED_BIT"),
						}
					)
					local ptr = T.Box(vk.VkFence)()
					vk_assert(lib.vkCreateFence(self.ptr[0], fenceCreateInfo, nil, ptr), "failed to create fence")
					return setmetatable({ptr = ptr, device = self}, Fence)
				end

				function Fence:__gc()
					lib.vkDestroyFence(self.device.ptr[0], self.ptr[0], nil)
				end

				function Fence:Wait()
					lib.vkWaitForFences(self.device.ptr[0], 1, self.ptr, 1, ffi.cast("uint64_t", -1))
					lib.vkResetFences(self.device.ptr[0], 1, self.ptr)
				end
			end

			do -- render pass
				local RenderPass = {}
				RenderPass.__index = RenderPass

				function Device:CreateRenderPass(surfaceFormat, samples, final_layout, depth_format)
					samples = samples or "1"
					final_layout = final_layout or "present_src_khr"
					local attachments
					local attachment_count
					local has_depth = depth_format ~= nil

					if samples == "1" then
						if has_depth then
							attachment_count = 2
							attachments = T.Array(
								vk.VkAttachmentDescription,
								2,
								{
									-- Attachment 0: Color
									{
										format = enums.VK_FORMAT_(surfaceFormat.format),
										samples = "VK_SAMPLE_COUNT_1_BIT",
										loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
										storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
										stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
										stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
										initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
										finalLayout = enums.VK_IMAGE_LAYOUT_(final_layout),
									},
									-- Attachment 1: Depth
									{
										format = enums.VK_FORMAT_(depth_format),
										samples = "VK_SAMPLE_COUNT_1_BIT",
										loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
										storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
										stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
										stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
										initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
										finalLayout = "VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL",
									},
								}
							)
						else
							attachment_count = 1
							attachments = T.Box(
								vk.VkAttachmentDescription,
								{
									format = enums.VK_FORMAT_(surfaceFormat.format),
									samples = "VK_SAMPLE_COUNT_1_BIT",
									loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
									storeOp = "VK_ATTACHMENT_STORE_OP_STORE",
									stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
									stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
									initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
									finalLayout = enums.VK_IMAGE_LAYOUT_(final_layout),
								}
							)
						end
					else
						attachment_count = 2
						attachments = T.Array(
							vk.VkAttachmentDescription,
							2,
							{
								-- Attachment 0: MSAA color attachment
								{
									format = enums.VK_FORMAT_(surfaceFormat.format),
									samples = "VK_SAMPLE_COUNT_" .. samples .. "_BIT",
									loadOp = "VK_ATTACHMENT_LOAD_OP_CLEAR",
									storeOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE", -- Don't need to store MSAA
									stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
									stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
									initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
									finalLayout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
								},
								-- Attachment 1: Resolve target (swapchain)
								{
									format = enums.VK_FORMAT_(surfaceFormat.format),
									samples = "VK_SAMPLE_COUNT_1_BIT",
									loadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE", -- Don't care about initial contents
									storeOp = "VK_ATTACHMENT_STORE_OP_STORE", -- Store resolved result
									stencilLoadOp = "VK_ATTACHMENT_LOAD_OP_DONT_CARE",
									stencilStoreOp = "VK_ATTACHMENT_STORE_OP_DONT_CARE",
									initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
									finalLayout = "VK_IMAGE_LAYOUT_PRESENT_SRC_KHR",
								},
							}
						)
					--attachments[0].samples = "VK_SAMPLE_COUNT_2_BIT"
					end

					local colorAttachmentRef = T.Box(
						vk.VkAttachmentReference,
						{
							attachment = 0,
							layout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
						}
					)
					local depthAttachmentRef = has_depth and
						T.Box(
							vk.VkAttachmentReference,
							{
								attachment = samples == "1" and 1 or 2,
								layout = "VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL",
							}
						) or
						nil
					local subpass = T.Box(
						vk.VkSubpassDescription,
						{
							pipelineBindPoint = "VK_PIPELINE_BIND_POINT_GRAPHICS",
							colorAttachmentCount = 1,
							pColorAttachments = colorAttachmentRef,
							pResolveAttachments = samples ~= "1" and
								T.Box(
									vk.VkAttachmentReference,
									{
										attachment = 1,
										layout = "VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL",
									}
								) or
								nil,
							pDepthStencilAttachment = depthAttachmentRef,
						}
					)
					local dependency = T.Box(
						vk.VkSubpassDependency,
						{
							srcSubpass = vk.VK_SUBPASS_EXTERNAL,
							dstSubpass = 0,
							srcStageMask = has_depth and
								bit.bor(
									vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
									vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT")
								) or
								vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
							srcAccessMask = 0,
							dstStageMask = has_depth and
								bit.bor(
									vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
									vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT")
								) or
								vk.VkPipelineStageFlagBits("VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT"),
							dstAccessMask = has_depth and
								bit.bor(
									vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
									vk.VkAccessFlagBits("VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT")
								) or
								vk.VkAccessFlagBits("VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT"),
						}
					)
					local renderPassInfo = T.Box(
						vk.VkRenderPassCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO",
							attachmentCount = attachment_count,
							pAttachments = attachments,
							subpassCount = 1,
							pSubpasses = subpass,
							dependencyCount = 1,
							pDependencies = dependency,
						}
					)
					local ptr = T.Box(vk.VkRenderPass)()
					vk_assert(
						lib.vkCreateRenderPass(self.ptr[0], renderPassInfo, nil, ptr),
						"failed to create render pass with MSAA"
					)
					return setmetatable({ptr = ptr, device = self, samples = samples, has_depth = has_depth}, RenderPass)
				end

				function RenderPass:__gc()
					lib.vkDestroyRenderPass(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- framebuffer
				local Framebuffer = {}
				Framebuffer.__index = Framebuffer

				function Device:CreateFramebuffer(renderPass, imageView, width, height, msaaImageView, depthImageView)
					local attachments
					local attachmentCount

					if msaaImageView then
						-- MSAA: first attachment is MSAA color, second is resolve target (swapchain)
						local attachment_array = T.Array(vk.VkImageView)(2)
						attachment_array[0] = msaaImageView
						attachment_array[1] = imageView
						attachments = attachment_array
						attachmentCount = 2
					elseif depthImageView then
						-- Non-MSAA with depth: color + depth
						local attachment_array = T.Array(vk.VkImageView)(2)
						attachment_array[0] = imageView
						attachment_array[1] = depthImageView
						attachments = attachment_array
						attachmentCount = 2
					else
						-- Non-MSAA: single attachment
						local attachment_array = T.Array(vk.VkImageView)(1)
						attachment_array[0] = imageView
						attachments = attachment_array
						attachmentCount = 1
					end

					local framebufferInfo = T.Box(
						vk.VkFramebufferCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO",
							renderPass = renderPass.ptr[0],
							attachmentCount = attachmentCount,
							pAttachments = attachments,
							width = width,
							height = height,
							layers = 1,
						}
					)
					local ptr = T.Box(vk.VkFramebuffer)()
					vk_assert(
						lib.vkCreateFramebuffer(self.ptr[0], framebufferInfo, nil, ptr),
						"failed to create framebuffer"
					)
					return setmetatable({ptr = ptr, device = self}, Framebuffer)
				end

				function Framebuffer:__gc()
					lib.vkDestroyFramebuffer(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- image view
				local ImageView = {}
				ImageView.__index = ImageView

				function Device:CreateImageView(image, format_or_config)
					local config

					if type(format_or_config) == "string" then
						-- Backwards compatibility: simple (image, format) call
						config = {format = format_or_config}
					else
						-- New style: (image, config_table)
						config = format_or_config or {}
					end

					local viewInfo = T.Box(
						vk.VkImageViewCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO",
							image = image,
							viewType = enums.VK_IMAGE_VIEW_TYPE_(config.view_type or "2d"),
							format = enums.VK_FORMAT_(config.format),
							subresourceRange = {
								aspectMask = enums.VK_IMAGE_ASPECT_(config.aspect or "color"),
								baseMipLevel = config.base_mip_level or 0,
								levelCount = config.level_count or 1,
								baseArrayLayer = config.base_array_layer or 0,
								layerCount = config.layer_count or 1,
							},
						}
					)
					local ptr = T.Box(vk.VkImageView)()
					vk_assert(
						lib.vkCreateImageView(self.ptr[0], viewInfo, nil, ptr),
						"failed to create image view"
					)
					return setmetatable({ptr = ptr, device = self}, ImageView)
				end

				function ImageView:__gc()
					lib.vkDestroyImageView(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- image
				local Image = {}
				Image.__index = Image

				function Device:CreateImage(width, height, format, usage, properties, samples)
					samples = samples or "1"
					local imageInfo = T.Box(
						vk.VkImageCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO",
							imageType = "VK_IMAGE_TYPE_2D",
							format = enums.VK_FORMAT_(format),
							extent = {
								width = width,
								height = height,
								depth = 1,
							},
							mipLevels = 1,
							arrayLayers = 1,
							samples = "VK_SAMPLE_COUNT_" .. samples .. "_BIT",
							tiling = "VK_IMAGE_TILING_OPTIMAL",
							usage = enums.VK_IMAGE_USAGE_(usage),
							sharingMode = "VK_SHARING_MODE_EXCLUSIVE",
							initialLayout = "VK_IMAGE_LAYOUT_UNDEFINED",
						}
					)
					local image_ptr = T.Box(vk.VkImage)()
					vk_assert(
						lib.vkCreateImage(self.ptr[0], imageInfo, nil, image_ptr),
						"failed to create image"
					)
					local memRequirements = T.Box(vk.VkMemoryRequirements)()
					lib.vkGetImageMemoryRequirements(self.ptr[0], image_ptr[0], memRequirements)
					properties = enums.VK_MEMORY_PROPERTY_(properties or "device_local")
					local allocInfo = T.Box(
						vk.VkMemoryAllocateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO",
							allocationSize = memRequirements[0].size,
							memoryTypeIndex = self:FindMemoryType(memRequirements[0].memoryTypeBits, properties),
						}
					)
					local memory_ptr = T.Box(vk.VkDeviceMemory)()
					vk_assert(
						lib.vkAllocateMemory(self.ptr[0], allocInfo, nil, memory_ptr),
						"failed to allocate image memory"
					)
					lib.vkBindImageMemory(self.ptr[0], image_ptr[0], memory_ptr[0], 0)
					return setmetatable(
						{
							ptr = image_ptr,
							memory = memory_ptr,
							device = self,
							width = width,
							height = height,
							format = format,
							usage = usage,
						},
						Image
					)
				end

				function Image:GetWidth()
					return self.width
				end

				function Image:GetHeight()
					return self.height
				end

				function Image:CreateView()
					return self.device:CreateImageView(self.ptr[0], self.format)
				end

				function Image:__gc()
					lib.vkDestroyImage(self.device.ptr[0], self.ptr[0], nil)
					lib.vkFreeMemory(self.device.ptr[0], self.memory[0], nil)
				end
			end

			do -- sampler
				local Sampler = {}
				Sampler.__index = Sampler

				function Device:CreateSampler(config)
					config = config or {}
					-- Default values
					local min_filter = config.min_filter or "linear"
					local mag_filter = config.mag_filter or "linear"
					local mipmap_mode = config.mipmap_mode or "linear"
					local wrap_s = config.wrap_s or "repeat"
					local wrap_t = config.wrap_t or "repeat"
					local wrap_r = config.wrap_r or "repeat"
					local anisotropy = config.anisotropy or 1.0
					local max_lod = config.max_lod or 1000.0
					local samplerInfo = T.Box(
						vk.VkSamplerCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO",
							magFilter = enums.VK_FILTER_(mag_filter),
							minFilter = enums.VK_FILTER_(min_filter),
							mipmapMode = enums.VK_SAMPLER_MIPMAP_MODE_(mipmap_mode),
							addressModeU = enums.VK_SAMPLER_ADDRESS_MODE_(wrap_s),
							addressModeV = enums.VK_SAMPLER_ADDRESS_MODE_(wrap_t),
							addressModeW = enums.VK_SAMPLER_ADDRESS_MODE_(wrap_r),
							anisotropyEnable = anisotropy > 1.0 and 1 or 0,
							maxAnisotropy = anisotropy,
							borderColor = "VK_BORDER_COLOR_INT_OPAQUE_BLACK",
							unnormalizedCoordinates = 0,
							compareEnable = 0,
							compareOp = "VK_COMPARE_OP_ALWAYS",
							mipLodBias = 0.0,
							minLod = 0.0,
							maxLod = max_lod,
						}
					)
					local ptr = T.Box(vk.VkSampler)()
					vk_assert(
						lib.vkCreateSampler(self.ptr[0], samplerInfo, nil, ptr),
						"failed to create sampler"
					)
					return setmetatable(
						{
							ptr = ptr,
							device = self,
							min_filter = min_filter,
							mag_filter = mag_filter,
							mipmap_mode = mipmap_mode,
							wrap_s = wrap_s,
							wrap_t = wrap_t,
							wrap_r = wrap_r,
							anisotropy = anisotropy,
						},
						Sampler
					)
				end

				function Sampler:__gc()
					lib.vkDestroySampler(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- pipeline layout
				local PipelineLayout = {}
				PipelineLayout.__index = PipelineLayout

				-- used to pass data to shaders
				function Device:CreatePipelineLayout(descriptorSetLayouts, pushConstantRanges)
					-- descriptorSetLayouts is an optional array of DescriptorSetLayout objects
					-- pushConstantRanges is an optional array of {stage, offset, size}
					local setLayoutArray = nil
					local setLayoutCount = 0

					if descriptorSetLayouts and #descriptorSetLayouts > 0 then
						setLayoutCount = #descriptorSetLayouts
						setLayoutArray = T.Array(vk.VkDescriptorSetLayout)(setLayoutCount)

						for i, layout in ipairs(descriptorSetLayouts) do
							setLayoutArray[i - 1] = layout.ptr[0]
						end
					end

					local pushConstantArray = nil
					local pushConstantCount = 0

					if pushConstantRanges and #pushConstantRanges > 0 then
						pushConstantCount = #pushConstantRanges
						pushConstantArray = T.Array(vk.VkPushConstantRange)(pushConstantCount)

						for i, range in ipairs(pushConstantRanges) do
							pushConstantArray[i - 1] = {
								stageFlags = enums.VK_SHADER_STAGE_(range.stage),
								offset = range.offset,
								size = range.size,
							}
						end
					end

					local pipelineLayoutInfo = T.Box(
						vk.VkPipelineLayoutCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO",
							setLayoutCount = setLayoutCount,
							pSetLayouts = setLayoutArray,
							pushConstantRangeCount = pushConstantCount,
							pPushConstantRanges = pushConstantArray,
						}
					)
					local ptr = T.Box(vk.VkPipelineLayout)()
					vk_assert(
						lib.vkCreatePipelineLayout(self.ptr[0], pipelineLayoutInfo, nil, ptr),
						"failed to create pipeline layout"
					)
					return setmetatable({device = self, ptr = ptr}, PipelineLayout)
				end

				function PipelineLayout:__gc()
					lib.vkDestroyPipelineLayout(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- compute pipeline
				local ComputePipeline = {}
				ComputePipeline.__index = ComputePipeline

				function Device:CreateComputePipeline(shaderModule, pipelineLayout)
					local computeShaderStageInfo = T.Box(
						vk.VkPipelineShaderStageCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO",
							stage = enums.VK_SHADER_STAGE_("compute"),
							module = shaderModule.ptr[0],
							pName = "main",
						}
					)
					local computePipelineCreateInfo = T.Box(
						vk.VkComputePipelineCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO",
							stage = computeShaderStageInfo[0],
							layout = pipelineLayout.ptr[0],
							basePipelineHandle = nil,
							basePipelineIndex = -1,
						}
					)
					local ptr = T.Box(vk.VkPipeline)()
					vk_assert(
						lib.vkCreateComputePipelines(self.ptr[0], nil, 1, computePipelineCreateInfo, nil, ptr),
						"failed to create compute pipeline"
					)
					return setmetatable({device = self, ptr = ptr}, ComputePipeline)
				end

				function ComputePipeline:__gc()
					lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
				end
			end

			do -- graphics pipeline
				local Pipeline = {}
				Pipeline.__index = Pipeline

				function Device:CreateGraphicsPipeline(config, render_passes, pipelineLayout)
					local stageArrayType = ffi.typeof("$ [" .. #config.shaderModules .. "]", vk.VkPipelineShaderStageCreateInfo)
					local shaderStagesArray = ffi.new(stageArrayType)

					for i, stage in ipairs(config.shaderModules) do
						shaderStagesArray[i - 1] = vk.VkPipelineShaderStageCreateInfo(
							{
								sType = "VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO",
								stage = enums.VK_SHADER_STAGE_(stage.type),
								module = stage.module.ptr[0],
								pName = "main",
							}
						)
					end

					-- Vertex input state
					local bindingArray = nil
					local attributeArray = nil
					local bindingCount = 0
					local attributeCount = 0

					if config.vertexBindings then
						bindingCount = #config.vertexBindings
						bindingArray = T.Array(vk.VkVertexInputBindingDescription)(bindingCount)

						for i, binding in ipairs(config.vertexBindings) do
							bindingArray[i - 1].binding = binding.binding
							bindingArray[i - 1].stride = binding.stride
							bindingArray[i - 1].inputRate = enums.VK_VERTEX_INPUT_RATE_(binding.input_rate or "vertex")
						end
					end

					if config.vertexAttributes then
						attributeCount = #config.vertexAttributes
						attributeArray = T.Array(vk.VkVertexInputAttributeDescription)(attributeCount)

						for i, attr in ipairs(config.vertexAttributes) do
							attributeArray[i - 1].location = attr.location
							attributeArray[i - 1].binding = attr.binding
							attributeArray[i - 1].format = enums.VK_FORMAT_(attr.format)
							attributeArray[i - 1].offset = attr.offset
						end
					end

					local vertexInputInfo = T.Box(
						vk.VkPipelineVertexInputStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO",
							vertexBindingDescriptionCount = bindingCount,
							pVertexBindingDescriptions = bindingArray,
							vertexAttributeDescriptionCount = attributeCount,
							pVertexAttributeDescriptions = attributeArray,
						}
					)
					config.input_assembly = config.input_assembly or {}
					local inputAssembly = T.Box(
						vk.VkPipelineInputAssemblyStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO",
							topology = enums.VK_PRIMITIVE_TOPOLOGY_(config.input_assembly.topology or "triangle_list"),
							primitiveRestartEnable = config.input_assembly.primitive_restart or 0,
						}
					)
					config.viewport = config.viewport or {}
					local viewport = T.Box(
						vk.VkViewport,
						{
							x = config.viewport.x or 0.0,
							y = config.viewport.y or 0.0,
							width = config.viewport.w or 800,
							height = config.viewport.h or 600,
							minDepth = config.viewport.min_depth or 0.0,
							maxDepth = config.viewport.max_depth or 1.0,
						}
					)
					config.scissor = config.scissor or {}
					local scissor = T.Box(
						vk.VkRect2D,
						{
							offset = {x = config.scissor.x or 0, y = config.scissor.y or 0},
							extent = {
								width = config.scissor.w or 800,
								height = config.scissor.h or 600,
							},
						}
					)
					-- TODO: support more than one viewport/scissor
					local viewportState = T.Box(
						vk.VkPipelineViewportStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO",
							viewportCount = 1,
							pViewports = viewport,
							scissorCount = 1,
							pScissors = scissor,
						}
					)
					config.rasterizer = config.rasterizer or {}
					local rasterizer = T.Box(
						vk.VkPipelineRasterizationStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO",
							depthClampEnable = config.rasterizer.depth_clamp or 0,
							rasterizerDiscardEnable = config.rasterizer.discard or 0,
							polygonMode = enums.VK_POLYGON_MODE_(config.rasterizer.polygon_mode or "fill"),
							lineWidth = config.rasterizer.line_width or 1.0,
							cullMode = enums.VK_CULL_MODE_(config.rasterizer.cull_mode or "back"),
							frontFace = enums.VK_FRONT_FACE_(config.rasterizer.front_face or "clockwise"),
							depthBiasEnable = config.rasterizer.depth_bias or 0,
						}
					)
					config.multisampling = config.multisampling or {}
					local multisampling = T.Box(
						vk.VkPipelineMultisampleStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO",
							sampleShadingEnable = config.multisampling.sample_shading or 0,
							rasterizationSamples = enums.VK_SAMPLE_COUNT_(config.multisampling.rasterization_samples or "1"),
						}
					)
					config.color_blend = config.color_blend or {}
					config.color_blend.attachments = config.color_blend.attachments or {}
					local colorBlendAttachments = {}

					for i, color_blend_attachment in ipairs(config.color_blend.attachments) do
						colorBlendAttachments[i] = vk.VkPipelineColorBlendAttachmentState(
							{
								colorWriteMask = enums.VK_COLOR_COMPONENT_(color_blend_attachment.color_write_mask or {"R", "G", "B", "A"}),
								blendEnable = color_blend_attachment.blend or 0,
								srcColorBlendFactor = color_blend_attachment.src_color_blend_factor and
									enums.VK_BLEND_FACTOR_(color_blend_attachment.src_color_blend_factor) or
									enums.VK_BLEND_FACTOR_("one"),
								dstColorBlendFactor = color_blend_attachment.dst_color_blend_factor and
									enums.VK_BLEND_FACTOR_(color_blend_attachment.dst_color_blend_factor) or
									enums.VK_BLEND_FACTOR_("zero"),
								colorBlendOp = color_blend_attachment.color_blend_op and
									enums.VK_BLEND_OP_(color_blend_attachment.color_blend_op) or
									enums.VK_BLEND_OP_("add"),
								srcAlphaBlendFactor = color_blend_attachment.src_alpha_blend_factor and
									enums.VK_BLEND_FACTOR_(color_blend_attachment.src_alpha_blend_factor) or
									enums.VK_BLEND_FACTOR_("one"),
								dstAlphaBlendFactor = color_blend_attachment.dst_alpha_blend_factor and
									enums.VK_BLEND_FACTOR_(color_blend_attachment.dst_alpha_blend_factor) or
									enums.VK_BLEND_FACTOR_("zero"),
								alphaBlendOp = color_blend_attachment.alpha_blend_op and
									enums.VK_BLEND_OP_(color_blend_attachment.alpha_blend_op) or
									enums.VK_BLEND_OP_("add"),
							}
						)
					end

					local colorBlendAttachment = T.Array(vk.VkPipelineColorBlendAttachmentState)(#colorBlendAttachments)

					-- Copy attachments to array
					for i = 1, #colorBlendAttachments do
						colorBlendAttachment[i - 1] = colorBlendAttachments[i]
					end

					local colorBlending = T.Box(
						vk.VkPipelineColorBlendStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO",
							logicOpEnable = config.color_blend.logic_op_enabled or 0,
							logicOp = enums.VK_LOGIC_OP_(config.color_blend.logic_op or "copy"),
							attachmentCount = #colorBlendAttachments,
							pAttachments = colorBlendAttachment,
							blendConstants = config.color_blend.constants or {0.0, 0.0, 0.0, 0.0},
						}
					)
					config.depth_stencil = config.depth_stencil or {}
					local depthStencilState = T.Box(
						vk.VkPipelineDepthStencilStateCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO",
							depthTestEnable = config.depth_stencil.depth_test or 0,
							depthWriteEnable = config.depth_stencil.depth_write or 0,
							depthCompareOp = enums.VK_COMPARE_OP_(config.depth_stencil.depth_compare_op or "less"),
							depthBoundsTestEnable = config.depth_stencil.depth_bounds_test or 0,
							stencilTestEnable = config.depth_stencil.stencil_test or 0,
						}
					)
					-- Dynamic state configuration
					local dynamicStateInfo = nil

					if config.dynamic_states then
						local dynamicStateCount = #config.dynamic_states
						local dynamicStateArray = T.Array(vk.VkDynamicState)(dynamicStateCount)

						for i, state in ipairs(config.dynamic_states) do
							dynamicStateArray[i - 1] = enums.VK_DYNAMIC_STATE_(state)
						end

						dynamicStateInfo = T.Box(
							vk.VkPipelineDynamicStateCreateInfo,
							{
								sType = "VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO",
								dynamicStateCount = dynamicStateCount,
								pDynamicStates = dynamicStateArray,
							}
						)
					end

					if render_passes[2] or (config.subpass and config.subpass ~= 0) then
						error("multiple render passes not supported yet")
					end

					local pipelineInfo = T.Box(
						vk.VkGraphicsPipelineCreateInfo,
						{
							sType = "VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO",
							stageCount = #config.shaderModules,
							pStages = shaderStagesArray,
							pVertexInputState = vertexInputInfo,
							pInputAssemblyState = inputAssembly,
							pViewportState = viewportState,
							pRasterizationState = rasterizer,
							pMultisampleState = multisampling,
							pDepthStencilState = depthStencilState,
							pColorBlendState = colorBlending,
							pDynamicState = dynamicStateInfo,
							layout = pipelineLayout.ptr[0],
							renderPass = render_passes[1].ptr[0],
							subpass = config.subpass or 0,
							basePipelineHandle = nil,
							basePipelineIndex = -1,
						}
					)
					local ptr = T.Box(vk.VkPipeline)()
					vk_assert(
						lib.vkCreateGraphicsPipelines(self.ptr[0], nil, 1, pipelineInfo, nil, ptr),
						"failed to create graphics pipeline"
					)
					return setmetatable({device = self, ptr = ptr, config = config}, Pipeline)
				end

				function Pipeline:__gc()
					lib.vkDestroyPipeline(self.device.ptr[0], self.ptr[0], nil)
				end
			end
		end
	end
end

return vulkan
