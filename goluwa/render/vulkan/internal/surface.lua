local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Surface = prototype.CreateTemplate("vulkan_surface")
local WIN32_SURFACE_CREATE_INFO_T = ffi.typeof([[struct {
	uint32_t sType;
	const void *pNext;
	uint32_t flags;
	void *hinstance;
	void *hwnd;
}]])
local PFN_vkCreateWin32SurfaceKHR = ffi.typeof("int (*)(void *, const $ *, const void *, void *)", WIN32_SURFACE_CREATE_INFO_T)
local VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR = 1000009000

function Surface.New(instance, surface_handle, display_handle)
	local info
	local vkCreateSurface

	if jit.os == "OSX" then
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		info = vulkan.vk.s.MetalSurfaceCreateInfoEXT{
			flags = 0,
			pLayer = ffi.cast("const void*", surface_handle),
		}
		vkCreateSurface = instance:GetExtension("vkCreateMetalSurfaceEXT")
	elseif jit.os == "Windows" then
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		assert(display_handle ~= nil, "display_handle cannot be nil")
		info = ffi.new(
			WIN32_SURFACE_CREATE_INFO_T,
			{
				sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
				pNext = nil,
				flags = 0,
				hinstance = ffi.cast("void*", display_handle),
				hwnd = ffi.cast("void*", surface_handle),
			}
		)
		local proc = vulkan.lib.vkGetInstanceProcAddr(instance.ptr[0], "vkCreateWin32SurfaceKHR")
		assert(proc ~= nil, "vkCreateWin32SurfaceKHR not found")
		vkCreateSurface = ffi.cast(PFN_vkCreateWin32SurfaceKHR, proc)
	else
		-- wayland 
		assert(surface_handle ~= nil, "surface_handle cannot be nil")
		assert(display_handle ~= nil, "display_handle cannot be nil")
		info = vulkan.vk.s.WaylandSurfaceCreateInfoKHR{
			flags = 0,
			display = ffi.cast("struct wl_display*", display_handle),
			surface = ffi.cast("struct wl_surface*", surface_handle),
		}
		vkCreateSurface = instance:GetExtension("vkCreateWaylandSurfaceKHR")
	end

	local ptr = vulkan.T.Box(vulkan.vk.VkSurfaceKHR)()
	local result = vkCreateSurface(instance.ptr[0], info, nil, ptr)
	vulkan.assert(result, "failed to create surface")
	return Surface:CreateObject{
		ptr = ptr,
		instance = instance,
		info = info,
		surface_handle = surface_handle,
		display_handle = display_handle,
	}
end

function Surface:OnRemove()
	if self.instance:IsValid() then
		vulkan.lib.vkDestroySurfaceKHR(self.instance.ptr[0], self.ptr[0], nil)
	end
end

return Surface:Register()
