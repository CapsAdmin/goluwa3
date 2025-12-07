_G.PROFILE = false
require("goluwa.global_environment")

if ... then
	local path = ... and (...):ends_with(".lua") and ...

	if path then
		dofile(path)
		return
	end
end

require("main")
