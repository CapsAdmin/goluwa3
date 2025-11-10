local ffi = require("ffi")
local vk = require("vk")
local T = require("helpers.ffi_types")
local enum_to_string = require("helpers.enum_translator").enum_to_string
local lib = vk.find_library()
local appInfo = T.Box(
	vk.VkApplicationInfo,
	{
		sType = "VK_STRUCTURE_TYPE_APPLICATION_INFO",
		pApplicationName = "NattLua Vulkan Test",
		applicationVersion = 1,
		pEngineName = "No Engine",
		engineVersion = 1,
		apiVersion = vk.VK_API_VERSION_1_0,
	}
)
local createInfo = T.Box(
	vk.VkInstanceCreateInfo,
	{
		sType = "VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO",
		pNext = nil,
		flags = 0,
		pApplicationInfo = appInfo,
		enabledLayerCount = 0,
		ppEnabledLayerNames = nil,
		enabledExtensionCount = 0,
		ppEnabledExtensionNames = nil,
	}
)
local instance = T.Box(vk.VkInstance)()
local result = lib.vkCreateInstance(createInfo, nil, instance)

if result ~= 0 then
	error("failed to create vulkan instance: " .. enum_to_string(result))
end

print("vulkan instance created successfully: " .. enum_to_string(result))
local deviceCount = ffi.new("uint32_t[1]", 0)
result = lib.vkEnumeratePhysicalDevices(instance[0], deviceCount, nil)

if result ~= 0 or deviceCount[0] == 0 then error("devices found") end

print(string.format("found %d physical device(s)", deviceCount[0]))
local devices = T.Array(vk.VkPhysicalDevice)(deviceCount[0])
result = lib.vkEnumeratePhysicalDevices(instance[0], deviceCount, devices)

for i = 0, deviceCount[0] - 1 do
	local properties = T.Box(vk.VkPhysicalDeviceProperties)()
	lib.vkGetPhysicalDeviceProperties(devices[i], properties)
	local props = properties[0]
	-- Decode API version (major.minor.patch)
	print(string.format("device %d:", i))
	print(string.format("  name: %s", ffi.string(props.deviceName)))
	local apiVersion = props.apiVersion
	print(
		string.format(
			"  api version: %d.%d.%d",
			bit.rshift(apiVersion, 22),
			bit.band(bit.rshift(apiVersion, 12), 0x3FF),
			bit.band(apiVersion, 0xFFF)
		)
	)
	print(string.format("  driver version: 0x%08X", props.driverVersion))
	print(string.format("  vendor id: 0x%04X", props.vendorID))
	print(string.format("  device id: 0x%04X", props.deviceID))
	print(string.format("  device type: %s", enum_to_string(props.deviceType)))
	-- Print some limits
	local limits = props.limits
	print(string.format("  max image dimension 2D: %d", tonumber(limits.maxImageDimension2D)))
	print(
		string.format(
			"  max compute shared memory size: %d bytes",
			tonumber(limits.maxComputeSharedMemorySize)
		)
	)
	print(
		string.format(
			"  max compute work group count: [%d, %d, %d]",
			tonumber(limits.maxComputeWorkGroupCount[0]),
			tonumber(limits.maxComputeWorkGroupCount[1]),
			tonumber(limits.maxComputeWorkGroupCount[2])
		)
	)
end
