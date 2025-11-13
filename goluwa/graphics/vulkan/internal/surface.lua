local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Surface = {}
Surface.__index = Surface

function Surface.New(instance, metal_layer)
	assert(metal_layer ~= nil, "metal_layer cannot be nil")
	local info = vulkan.vk.VkMetalSurfaceCreateInfoEXT(
		{
			sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
			pNext = nil,
			flags = 0,
			pLayer = ffi.cast("const void*", metal_layer),
		}
	)
	local ptr = vulkan.T.Box(vulkan.vk.VkSurfaceKHR)()
	local vkCreateMetalSurfaceEXT = instance:GetExtension("vkCreateMetalSurfaceEXT")
	vulkan.assert(
		vkCreateMetalSurfaceEXT(instance.ptr[0], info, nil, ptr),
		"failed to create metal surface"
	)
	return setmetatable({ptr = ptr, instance = instance}, Surface)
end

function Surface:__gc()
	vulkan.lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
end

return Surface
