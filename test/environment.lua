require("goluwa.global_environment")
local test_render = require("test.test_render")
local T = require("helpers.test")
T.Test2D = function(name, cb)
	return T.Test(name, function()
		test_render.Draw2D(cb)
	end)
end
T.Test3D = function(name, cb)
	return T.Test(name, function()
		test_render.Draw3D(cb)
	end)
end
return T
