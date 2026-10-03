local T = import("test/environment.lua")
local utility = import("goluwa/utility.lua")

T.Test("CreateLoadCache calls every caller of a load in progress without chaining", function()
	local loads = utility.CreateLoadCache({})
	local count = 20000
	local done, meshes = 0, 0
	local on_done = function()
		done = done + 1
	end
	local on_mesh = function()
		meshes = meshes + 1
	end
	loads:Begin("a", on_done, {mesh = on_mesh})

	for _ = 2, count do
		T(loads:Join("a", on_done, {mesh = on_mesh}))["=="](true)
	end

	loads:Emit("a", "mesh", {})
	loads:Finish("a", {"result"})
	T(meshes)["=="](count)
	T(done)["=="](count)
	T(loads:Join("a", on_done, {}))["=="](nil)
	T(loads:Get("a")[1])["=="]("result")
end)

T.Test("CreateLoadCache reports a failure to callers that joined later", function()
	local loads = utility.CreateLoadCache({})
	local failures = 0
	local on_fail = function()
		failures = failures + 1
	end

	loads:Begin("b", function() end, {})

	for _ = 1, 20000 do
		loads:Join("b", function() end, {on_fail = on_fail})
	end

	loads:Emit("b", "on_fail", "reason")
	loads:Forget("b")
	T(failures)["=="](20000)
	T(loads:Get("b"))["=="](nil)
end)
