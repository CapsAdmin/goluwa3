local vk = require("bindings.vk")
local has_rendering = false
if  pcall(vk.find_library) then
	has_rendering = true
end


do
	package.loaded["bindings.clipboard"] = {
		Get = function()
			return clipboard
		end,
		Set = function(text)
			clipboard = tostring(text)
		end,
	}
end

require("goluwa.global_environment")
local test_render = require("test.test_render")
local T = require("helpers.test")
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
