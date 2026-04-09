local T = import("test/environment.lua")
local threads = import("goluwa/bindings/threads.lua")

T.Test("thread returns incremented value", function()
	local thread = threads.new([[ 
		local input = ...
		assert(input == 1)
		return input + 1
	]])
	thread:run(1)
	local ret = thread:join()
	T(ret)["=="](2)
end)

T.Test("thread handles errors", function()
	local thread = threads.new([[ 
		local input = ...
		error("Intentional Error")
	]])
	thread:run(1)
	local ret, err = thread:join()
	T(err)["~="](nil)
	T(err:find("Intentional Error"))["~="](nil)
end)

T.Test("thread worker source can require dependencies inside the thread", function()
	local thread = threads.new([[
		local input = ...
		local io = require("io") -- safe: required fresh in the new state
		assert(type(io.write) == "function")
		return "ok"
	]])
	thread:run(true)
	local ret, err = thread:join()

	if err then error(err) end

	T(ret)["=="]("ok")
end)

T.Test("thread worker rejects non-string source", function()
	local ok, err = pcall(function()
		threads.new(function() end)
	end)
	T(ok)["=="](false)
	T(tostring(err):find("source string", 1, true))["~="](nil)
end)

T.Test("thread worker source cannot capture outer locals", function()
	local thread = threads.new([[
		local ok, err = pcall(function()
			return io_outer.write
		end)
		assert(not ok)
		return true
	]])
	thread:run(true)
	local ret, err = thread:join()

	if err then error(err) end

	T(ret)["=="](true)
end)
