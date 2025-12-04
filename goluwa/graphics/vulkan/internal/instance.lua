local ffi = require("ffi")
local ffi_helpers = require("helpers.ffi_helpers")
local vulkan = require("graphics.vulkan.internal.vulkan")
local PhysicalDevice = require("graphics.vulkan.internal.physical_device")
local Instance = {}
Instance.__index = Instance

local function friendly_flags(type, flags, prefix)
	local flags = ffi_helpers.bit_enums_to_table(type, flags)

	for i, str in ipairs(flags) do
		if str:find("MAX_ENUM") then
			table.remove(flags, i)

			break
		end
	end

	for i, str in ipairs(flags) do
		flags[i] = str:gsub(prefix, ""):gsub("_BIT_EXT", "")
	end

	return flags
end

local function debug_callback(messageSeverity, messageType, pCallbackData, pUserData)
	local data = pCallbackData[0]
	local severity_flags = friendly_flags(
		vulkan.vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
		messageSeverity,
		"VK_DEBUG_UTILS_MESSAGE_SEVERITY_"
	)
	local type_flags = friendly_flags(vulkan.vk.VkDebugUtilsMessageTypeFlagBitsEXT, messageType, "VK_DEBUG_UTILS_MESSAGE_TYPE_")
	local msg = ffi.string(data.pMessage)

	if msg:find("vk_loader_settings.json", nil, true) then
		return vulkan.vk.VK_FALSE
	end

	print(
		debug.traceback(
				"\n[" .. table.concat(severity_flags, "|") .. "] [" .. table.concat(type_flags, "|") .. "]\n" .. msg,
				2
			) .. "\n"
	)
	return vulkan.vk.VK_FALSE
end

function Instance.New(extensions, layers)
	local version = vulkan.vk.VK_API_VERSION_1_4
	llog("requesting version: " .. vulkan.VersionToString(version))
	local appInfo = vulkan.vk.VkApplicationInfo(
		{
			sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
			pApplicationName = "MoltenVK LuaJIT Example",
			applicationVersion = 1,
			pEngineName = "No Engine",
			engineVersion = 1,
			apiVersion = version,
		}
	)
	llog("version loaded: " .. vulkan.GetVersion())
	-- Add debug utils extension if validation layers are enabled
	local has_validation = layers and #layers > 0

	if has_validation then
		extensions = extensions or {}
		local has_debug_utils = false

		for _, ext in ipairs(extensions) do
			if ext == "VK_EXT_debug_utils" then
				has_debug_utils = true

				break
			end
		end

		if not has_debug_utils then
			local new_extensions = {}

			for i, ext in ipairs(extensions) do
				new_extensions[i] = ext
			end

			table.insert(new_extensions, "VK_EXT_debug_utils")
			extensions = new_extensions
		end
	end

	local extension_names = extensions and
		vulkan.T.Array(ffi.typeof("const char*"), #extensions, extensions) or
		nil
	local layer_names = layers and vulkan.T.Array(ffi.typeof("const char*"), #layers, layers) or nil
	-- Create debug messenger create info
	local debug_create_info

	if has_validation then
		debug_create_info = vulkan.vk.VkDebugUtilsMessengerCreateInfoEXT(
			{
				sType = "VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT",
				flags = 0,
				messageSeverity = bit.bor(
					--vulkan.vk.VkDebugUtilsMessageSeverityFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT"),
					--vulkan.vk.VkDebugUtilsMessageSeverityFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT"),
					vulkan.vk.VkDebugUtilsMessageSeverityFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT"),
					vulkan.vk.VkDebugUtilsMessageSeverityFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT")
				),
				messageType = bit.bor(
					vulkan.vk.VkDebugUtilsMessageTypeFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT"),
					vulkan.vk.VkDebugUtilsMessageTypeFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT"),
					vulkan.vk.VkDebugUtilsMessageTypeFlagBitsEXT("VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT")
				),
				pfnUserCallback = ffi.cast(vulkan.vk.PFN_vkDebugUtilsMessengerCallbackEXT, debug_callback),
				pUserData = nil,
			}
		)
	end

	-- Only use portability enumeration on macOS
	local instance_flags = 0

	if jit.os == "OSX" then
		instance_flags = vulkan.vk.VkInstanceCreateFlagBits("VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR")
	end

	local createInfo = vulkan.vk.VkInstanceCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
			pNext = has_validation and debug_create_info or nil,
			flags = instance_flags,
			pApplicationInfo = appInfo,
			enabledLayerCount = layers and #layers or 0,
			ppEnabledLayerNames = layer_names,
			enabledExtensionCount = extensions and #extensions or 0,
			ppEnabledExtensionNames = extension_names,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkInstance)()
	vulkan.assert(vulkan.lib.vkCreateInstance(createInfo, nil, ptr), "failed to create vulkan instance")
	local self = setmetatable({ptr = ptr, debug_messenger = nil}, Instance)

	-- Create debug messenger
	if has_validation then
		local vkCreateDebugUtilsMessengerEXT = self:GetExtension("vkCreateDebugUtilsMessengerEXT")
		local messenger_ptr = vulkan.T.Box(vulkan.vk.VkDebugUtilsMessengerEXT)()
		vulkan.assert(
			vkCreateDebugUtilsMessengerEXT(ptr[0], debug_create_info, nil, messenger_ptr),
			"failed to create debug messenger"
		)
		self.debug_messenger = messenger_ptr
		self.vkDestroyDebugUtilsMessengerEXT = self:GetExtension("vkDestroyDebugUtilsMessengerEXT")
	end

	return self
end

function Instance:__gc()
	if self.debug_messenger then
		self.vkDestroyDebugUtilsMessengerEXT(self.ptr[0], self.debug_messenger[0], nil)
	end

	vulkan.lib.vkDestroyInstance(self.ptr[0], nil)
end

function Instance:GetPhysicalDevices()
	local deviceCount = ffi.new("uint32_t[1]", 0)
	vulkan.assert(
		vulkan.lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, nil),
		"failed to enumerate physical devices"
	)

	if deviceCount[0] == 0 then error("no physical devices found") end

	local physicalDevices = vulkan.T.Array(vulkan.vk.VkPhysicalDevice)(deviceCount[0])
	vulkan.assert(
		vulkan.lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, physicalDevices),
		"failed to enumerate physical devices"
	)
	local out = {}

	for i = 0, deviceCount[0] - 1 do
		out[i + 1] = PhysicalDevice.New(physicalDevices[i])
	end

	return out
end

function Instance:GetExtension(name)
	local func_ptr = vulkan.lib.vkGetInstanceProcAddr(self.ptr[0], name)

	if func_ptr == nil then error("extension function not found", 2) end

	return ffi.cast(vulkan.vk["PFN_" .. name], func_ptr)
end

return Instance
