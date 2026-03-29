require("goluwa.global_environment")
local vfs = import("goluwa/vfs.lua")
vfs.Mount("os:" .. vfs.GetStorageDirectory("working_directory"))
vfs.MountStorageDirectories()
local vk = import("goluwa/bindings/vk.lua")
local has_rendering = false

if pcall(vk.find_library) then has_rendering = true end

do
	import.loaded["goluwa/bindings/clipboard.lua"] = {
		Get = function()
			return clipboard
		end,
		Set = function(text)
			clipboard = tostring(text)
		end,
	}
end

local test_render = import("test/test_render.lua")
local T = import("goluwa/helpers/test.lua")
T.Test2D = function(name, cb)
	if not has_rendering then
		return T.Unavailable("Vulkan library not available, skipping render2d tests.")
	end

	return T.Test(name, function()
		test_render.Draw2D(cb)
	end)
end
T.Test3D = function(name, cb)
	if not has_rendering then
		return T.Unavailable("Vulkan library not available, skipping render3d tests.")
	end

	return T.Test(name, function()
		test_render.Draw3D(cb)
	end)
end
return T
