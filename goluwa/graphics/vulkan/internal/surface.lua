local ffi = require("ffi")
local vulkan = require("graphics.vulkan.internal.vulkan")
local Surface = {}
Surface.__index = Surface

function Surface.New(instance, surface_handle, display_handle)
	local info
	local vkCreateSurface

	if jit.os == "OSX" then
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		info = vulkan.vk.VkMetalSurfaceCreateInfoEXT(
			{
				sType = "VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT",
				pNext = nil,
				flags = 0,
				pLayer = ffi.cast("const void*", surface_handle),
			}
		)
		vkCreateSurface = instance:GetExtension("vkCreateMetalSurfaceEXT")
	elseif jit.os == "Windows" then
		error("Windows surface creation not implemented")
	else
		-- wayland 
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		assert(display_handle ~= nil, "display_handle cannot be nil")
		local display_ptr = ffi.cast("struct wl_display*", display_handle)
		local surface_ptr = ffi.cast("struct wl_surface*", surface_handle)
		info = vulkan.vk.VkWaylandSurfaceCreateInfoKHR(
			{
				sType = "VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR",
				pNext = nil,
				flags = 0,
				display = display_ptr,
				surface = surface_ptr,
			}
		)
		vkCreateSurface = instance:GetExtension("vkCreateWaylandSurfaceKHR")
	end

	local ptr = vulkan.T.Box(vulkan.vk.VkSurfaceKHR)()
	local result = vkCreateSurface(instance.ptr[0], info, nil, ptr)
	vulkan.assert(result, "failed to create surface")
	return setmetatable(
		{
			ptr = ptr,
			instance = instance,
			info = info,
			surface_handle = surface_handle,
			display_handle = display_handle,
		},
		Surface
	)
end

function Surface:__gc()
	vulkan.lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
end

return Surface
