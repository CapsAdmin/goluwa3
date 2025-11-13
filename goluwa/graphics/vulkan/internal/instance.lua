local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local PhysicalDevice = require("graphics.vulkan.internal.physical_device")
local Instance = {}
Instance.__index = Instance

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
	local extension_names = extensions and
		vulkan.T.Array(ffi.typeof("const char*"), #extensions, extensions) or
		nil
	local layer_names = layers and vulkan.T.Array(ffi.typeof("const char*"), #layers, layers) or nil
	local createInfo = vulkan.vk.VkInstanceCreateInfo(
		{
			sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
			pNext = nil,
			flags = vulkan.vk.VkInstanceCreateFlagBits("VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR"),
			pApplicationInfo = appInfo,
			enabledLayerCount = layers and #layers or 0,
			ppEnabledLayerNames = layer_names,
			enabledExtensionCount = extensions and #extensions or 0,
			ppEnabledExtensionNames = extension_names,
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkInstance)()
	vulkan.assert(vulkan.lib.vkCreateInstance(createInfo, nil, ptr), "failed to create vulkan instance")
	return setmetatable({ptr = ptr}, Instance)
end

function Instance:__gc()
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
