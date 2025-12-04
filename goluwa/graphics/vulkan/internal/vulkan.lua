local ffi = require("ffi")
local vk = require("bindings.vk")
local ffi_helpers = require("helpers.ffi_helpers")
local vulkan = {}
vulkan.ext = {}
vulkan.vk = vk
vulkan.lib = vulkan.vk.find_library()
vulkan.T = {Box = ffi_helpers.Box, Array = ffi_helpers.Array}
vulkan.enum_to_string = ffi_helpers.enum_to_string
vulkan.enums = ffi_helpers.translate_enums(
	{
		{vulkan.vk.VkVertexInputRate, "VK_VERTEX_INPUT_RATE_"},
		{vulkan.vk.VkPrimitiveTopology, "VK_PRIMITIVE_TOPOLOGY_"},
		{vulkan.vk.VkColorComponentFlagBits, "VK_COLOR_COMPONENT_", "_BIT"},
		{vulkan.vk.VkPolygonMode, "VK_POLYGON_MODE_"},
		{vulkan.vk.VkCullModeFlagBits, "VK_CULL_MODE_", "_BIT"},
		{vulkan.vk.VkFrontFace, "VK_FRONT_FACE_"},
		{vulkan.vk.VkSampleCountFlagBits, "VK_SAMPLE_COUNT_", "_BIT"},
		{vulkan.vk.VkLogicOp, "VK_LOGIC_OP_"},
		{vulkan.vk.VkCompareOp, "VK_COMPARE_OP_"},
		{vulkan.vk.VkFormat, "VK_FORMAT_"},
		{vulkan.vk.VkPresentModeKHR, "VK_PRESENT_MODE_", "_KHR"},
		{vulkan.vk.VkCompositeAlphaFlagBitsKHR, "VK_COMPOSITE_ALPHA_", "_BIT_KHR"},
		{vulkan.vk.VkImageUsageFlagBits, "VK_IMAGE_USAGE_", "_BIT"},
		{vulkan.vk.VkBufferUsageFlagBits, "VK_BUFFER_USAGE_", "_BIT"},
		{vulkan.vk.VkMemoryPropertyFlagBits, "VK_MEMORY_PROPERTY_", "_BIT"},
		{vulkan.vk.VkShaderStageFlagBits, "VK_SHADER_STAGE_", "_BIT"},
		{vulkan.vk.VkDescriptorType, "VK_DESCRIPTOR_TYPE_"},
		{vulkan.vk.VkColorSpaceKHR, "VK_COLOR_SPACE_"},
		{vulkan.vk.VkImageAspectFlagBits, "VK_IMAGE_ASPECT_", "_BIT"},
		{vulkan.vk.VkAccessFlagBits, "VK_ACCESS_", "_BIT"},
		{vulkan.vk.VkImageLayout, "VK_IMAGE_LAYOUT_"},
		{vulkan.vk.VkPipelineBindPoint, "VK_PIPELINE_BIND_POINT_"},
		{vulkan.vk.VkDynamicState, "VK_DYNAMIC_STATE_"},
		{vulkan.vk.VkImageViewType, "VK_IMAGE_VIEW_TYPE_"},
		{vulkan.vk.VkFilter, "VK_FILTER_"},
		{vulkan.vk.VkSamplerMipmapMode, "VK_SAMPLER_MIPMAP_MODE_"},
		{vulkan.vk.VkSamplerAddressMode, "VK_SAMPLER_ADDRESS_MODE_"},
		{vulkan.vk.VkIndexType, "VK_INDEX_TYPE_"},
		{vulkan.vk.VkBlendFactor, "VK_BLEND_FACTOR_"},
		{vulkan.vk.VkBlendOp, "VK_BLEND_OP_"},
		{vulkan.vk.VkStencilOp, "VK_STENCIL_OP_"},
		{vulkan.vk.VkResult, "VK_"},
	}
)

function vulkan.assert(result, msg)
	if result ~= 0 then
		msg = msg or "Vulkan error"
		local enum_str = vulkan.enum_to_string(result) or ("error code - " .. tostring(result))
		error(msg .. " : " .. enum_str, 2)
	end
end

function vulkan.GetAvailableLayers()
	-- First, enumerate available layers
	local layerCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkEnumerateInstanceLayerProperties(layerCount, nil)
	local out = {}

	if layerCount[0] > 0 then
		local availableLayers = vulkan.T.Array(vulkan.vk.VkLayerProperties)(layerCount[0])
		vulkan.lib.vkEnumerateInstanceLayerProperties(layerCount, availableLayers)

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
	vulkan.lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, nil)
	local out = {}

	if extensionCount[0] > 0 then
		local availableExtensions = vulkan.T.Array(vulkan.vk.VkExtensionProperties)(extensionCount[0])
		vulkan.lib.vkEnumerateInstanceExtensionProperties(nil, extensionCount, availableExtensions)

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
		vulkan.lib.vkEnumerateInstanceVersion(version)
		return vulkan.VersionToString(version[0])
	end
end

--dprint("Vulkan bindings loaded. Vulkan version: " .. vulkan.GetVersion())
--dprint("Available Instance Layers: " .. table.concat(vulkan.GetAvailableLayers(), ", "))
--dprint("Available Instance Extensions: " .. table.concat(vulkan.GetAvailableExtensions(), ", "))
return vulkan
