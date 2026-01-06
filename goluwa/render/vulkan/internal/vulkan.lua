local ffi = require("ffi")
local vk = require("bindings.vk")
local vulkan = {}
vulkan.ext = {}
vulkan.vk = vk
vulkan.lib = vulkan.vk.find_library()
vulkan.T = {}

do
	local fixed_len_cache = {}
	local var_len_cache = {}

	local function array_type(t, len)
		local key = tonumber(t)

		if len then
			fixed_len_cache[key] = fixed_len_cache[key] or ffi.typeof("$[" .. len .. "]", t)
			return fixed_len_cache[key]
		end

		var_len_cache[key] = var_len_cache[key] or ffi.typeof("$[?]", t)
		return var_len_cache[key]
	end

	function vulkan.T.Array(t, len, ctor)
		if ctor then return array_type(t, len)(ctor) end

		return array_type(t, len)
	end

	function vulkan.T.Box(t, ctor)
		if ctor then return array_type(t, 1)({ctor}) end

		return array_type(t, 1)
	end
end

function vulkan.assert(result, msg)
	if result ~= 0 then
		msg = msg or "Vulkan error"
		local enum_str = vulkan.vk.str.VkResult(result) or
			vulkan.vk.str.VkResult(tonumber(ffi.cast("int32_t", result))) or
			(
				"error code - " .. tostring(result)
			)
		print(msg .. " : " .. enum_str)

		if enum_str ~= "error_device_lost" then debug.trace() end

		if enum_str == "error_device_lost" then os.realexit(1) end
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
