require("goluwa.global_environment")
local test2d = require("test.test2d")
local T = require("helpers.test")

if test2d then
	T.Test2D = function(name, cb)
		return T.Test(name, function()
			test2d.draw(cb)
		end)
	end
end

return T
