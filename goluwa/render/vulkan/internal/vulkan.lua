local ffi = require("ffi")
local vk = import("goluwa/bindings/vk.lua")
local vulkan = {}
vulkan.ext = {}
vulkan.vk = vk
vulkan.lib = vulkan.vk.find_library()
local VkLayerPropertiesArray = ffi.typeof("$[?]", vulkan.vk.VkLayerProperties)
local VkExtensionPropertiesArray = ffi.typeof("$[?]", vulkan.vk.VkExtensionProperties)

function vulkan.assert(result, msg)
	if result ~= 0 then
		msg = msg or "Vulkan error"
		local enum_str = vulkan.vk.str.VkResult(result) or
			vulkan.vk.str.VkResult(tonumber(ffi.cast("int32_t", result))) or
			(
				"error code - " .. tostring(result)
			)
		local full_msg = msg .. " : " .. enum_str

		if enum_str == "error_out_of_device_memory" then
			full_msg = full_msg .. " (out of device memory / VRAM)"
		elseif enum_str == "error_out_of_host_memory" then
			full_msg = full_msg .. " (out of host memory)"
		end

		if enum_str == "error_device_lost" then
			print(full_msg)
			os.realexit(1)
		end

		error(full_msg, 2)
	end
end

function vulkan.SetupDebugFunctions(meta, object_type, options)
	options = options or {}

	function meta:SetDebugName(name)
		self.debug_name = name
		self.device:SetObjectName(self.ptr[0], object_type, name)

		if options.onSetDebugName then options.onSetDebugName(self, name) end

		return self
	end

	function meta:SetObjectTag(key, value)
		self.object_tags = self.object_tags or {}
		self.object_tags[key] = value
		self.device:SetObjectStringTag(self.ptr[0], object_type, key, value)

		if options.onSetObjectTag then options.onSetObjectTag(self, key, value) end

		return self
	end

	return meta
end

function vulkan.ApplyObjectTags(obj, tags)
	if not tags then return obj end

	for key, value in pairs(tags) do
		obj:SetObjectTag(key, value)
	end

	return obj
end

function vulkan.GetAvailableLayers()
	-- First, enumerate available layers
	local layerCount = ffi.new("uint32_t[1]", 0)
	vulkan.lib.vkEnumerateInstanceLayerProperties(layerCount, nil)
	local out = {}

	if layerCount[0] > 0 then
		local availableLayers = VkLayerPropertiesArray(layerCount[0])
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
		local availableExtensions = VkExtensionPropertiesArray(extensionCount[0])
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
