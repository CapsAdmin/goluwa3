local ffi = require("ffi")
local prototype = require("prototype")
local vulkan = require("render.vulkan.internal.vulkan")
local Surface = prototype.CreateTemplate("vulkan", "surface")

function Surface.New(instance, surface_handle, display_handle)
	local info
	local vkCreateSurface

	if jit.os == "OSX" then
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		info = vulkan.vk.s.MetalSurfaceCreateInfoEXT({
			flags = 0,
			pLayer = ffi.cast("const void*", surface_handle),
		})
		vkCreateSurface = instance:GetExtension("vkCreateMetalSurfaceEXT")
	elseif jit.os == "Windows" then
		error("Windows surface creation not implemented")
	else
		-- wayland 
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		assert(display_handle ~= nil, "display_handle cannot be nil")
		info = vulkan.vk.s.WaylandSurfaceCreateInfoKHR(
			{
				flags = 0,
				display = ffi.cast("struct wl_display*", display_handle),
				surface = ffi.cast("struct wl_surface*", surface_handle),
			}
		)
		vkCreateSurface = instance:GetExtension("vkCreateWaylandSurfaceKHR")
	end

	local ptr = vulkan.T.Box(vulkan.vk.VkSurfaceKHR)()
	local result = vkCreateSurface(instance.ptr[0], info, nil, ptr)
	vulkan.assert(result, "failed to create surface")
	return Surface:CreateObject(
		{
			ptr = ptr,
			instance = instance,
			info = info,
			surface_handle = surface_handle,
			display_handle = display_handle,
		}
	)
end

function Surface:__gc()
	vulkan.lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
end

return Surface:Register()
