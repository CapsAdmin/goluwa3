local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local PhysicalDevice = require("render.vulkan.internal.physical_device")
local Instance = prototype.CreateTemplate("vulkan_instance")

function Instance:CreateDebugCallback()
	local VkDebugUtilsMessageTypeFlagBitsEXT = vulkan.vk.str.VkDebugUtilsMessageTypeFlagBitsEXT
	local VkDebugUtilsMessageSeverityFlagBitsEXT = vulkan.vk.str.VkDebugUtilsMessageSeverityFlagBitsEXT
	local ffi_string = ffi.string
	local VK_FALSE = vulkan.vk.VK_FALSE
	local io_write = io.write
	local io_flush = io.flush
	local traceback = debug.traceback
	local table_concat = table.concat
	local ipairs = ipairs

	local function debug_callback(messageSeverity, messageType, pCallbackData, pUserData)
		local suppressed_warnings = {
			"vk_loader_settings.json",
			"Path to given binary", -- NVIDIA symlink mismatch on NixOS
			"terminator_CreateInstance", -- Mesa DZN driver incompatible on Linux
		}
		local data = pCallbackData[0]
		local type_flags = table_concat(VkDebugUtilsMessageTypeFlagBitsEXT(messageType), "|")
		local severity_flags = table_concat(VkDebugUtilsMessageSeverityFlagBitsEXT(messageSeverity), "|")
		local msg = ffi_string(data.pMessage)

		for _, pattern in ipairs(suppressed_warnings) do
			if msg:find(pattern, nil, true) then return VK_FALSE end
		end

		io_write(
			traceback("\n[" .. severity_flags .. "] [" .. type_flags .. "]\n" .. msg, 2) .. "\n"
		)
		io_flush()
		return VK_FALSE
	end

	jit.off(debug_callback)
	local debug_callback_ptr = ffi.cast(vulkan.vk.PFN_vkDebugUtilsMessengerCallbackEXT, debug_callback)
	self.debug_callback_refs = {debug_callback, debug_callback_ptr}
	return debug_callback_ptr
end

function Instance.New(extensions, layers)
	local self = Instance:CreateObject({})
	local version = vulkan.vk.VK_API_VERSION_1_4
	local appInfo = vulkan.vk.s.ApplicationInfo(
		{
			pApplicationName = "MoltenVK LuaJIT Example",
			applicationVersion = 1,
			pEngineName = "No Engine",
			engineVersion = 1,
			apiVersion = version,
		}
	)
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
		debug_create_info = vulkan.vk.s.DebugUtilsMessengerCreateInfoEXT(
			{
				flags = 0,
				messageSeverity = {"warning_ext", "error_ext"},
				messageType = {"general_ext", "validation_ext", "performance_ext"},
				pfnUserCallback = self:CreateDebugCallback(),
				pUserData = nil,
			}
		)
		self.debug_create_info_ref = debug_create_info
	end

	-- Only use portability enumeration on macOS
	local instance_flags = 0

	if jit.os == "OSX" then instance_flags = "enumerate_portability_khr" end

	local ptr = vulkan.T.Box(vulkan.vk.VkInstance)()
	vulkan.assert(
		vulkan.lib.vkCreateInstance(
			vulkan.vk.s.InstanceCreateInfo(
				{
					pNext = has_validation and debug_create_info or nil,
					flags = instance_flags,
					pApplicationInfo = appInfo,
					enabledLayerCount = layers and #layers or 0,
					ppEnabledLayerNames = layer_names,
					enabledExtensionCount = extensions and #extensions or 0,
					ppEnabledExtensionNames = extension_names,
				}
			),
			nil,
			ptr
		),
		"failed to create vulkan instance"
	)
	self.ptr = ptr

	-- Create debug messenger
	if has_validation and self:HasExtension("vkCreateDebugUtilsMessengerEXT") then
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

function Instance:OnRemove()
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

function Instance:HasExtension(name)
	local func_ptr = vulkan.lib.vkGetInstanceProcAddr(self.ptr[0], name)
	return func_ptr ~= nil
end

function Instance:GetExtension(name)
	local func_ptr = vulkan.lib.vkGetInstanceProcAddr(self.ptr[0], name)

	if func_ptr == nil then error("extension function not found", 2) end

	return ffi.cast(vulkan.vk["PFN_" .. name], func_ptr)
end

return Instance:Register()
