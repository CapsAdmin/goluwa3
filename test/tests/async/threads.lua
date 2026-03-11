local T = require("test.environment")
local threads = require("bindings.threads")

T.Test("thread returns incremented value", function()
	local thread = threads.new(function(input)
		assert(input == 1)
		return input + 1
	end)
	thread:run(1)
	local ret = thread:join()
	T(ret)["=="](2)
end)

T.Test("thread handles errors", function()
	local thread = threads.new(function(input)
		error("Intentional Error")
	end)
	thread:run(1)
	local ret, err = thread:join()
	T(err)["~="](nil)
	T(err:find("Intentional Error"))["~="](nil)
end)

T.Test("thread function upvalues are nil after serialization", function()
	-- Reproduces the bug: a function that closes over a module via an outer
	-- `local x = require(...)` will have x=nil in the new Lua state because
	-- string.dump does not preserve upvalue values.
	local io_outer = require("io") -- captured as upvalue
	local thread = threads.new(function(input)
		-- io_outer is nil in this new Lua state
		return io_outer == nil
	end)
	thread:run(true)
	local ret, err = thread:join()

	if err then error(err) end

	T(ret)["=="](true) -- confirms upvalue is nil
end)

T.Test("thread source string avoids upvalue problem", function()
	-- Passing source code as a string instead of a function sidesteps the
	-- upvalue-serialization issue entirely: no upvalues to lose.
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

T.Test("thread worker cannot use outer upvalues (they are nil after serialization)", function()
	-- This reproduces the bug where a function captures a module as an upvalue
	-- via `local io = require("io")` in the outer scope. When string.dump'd into
	-- the thread's new Lua state the upvalue is nil, causing errors like:
	-- "attempt to index upvalue 'io' (a nil value)"
	-- The fix is to re-require inside the thread function body.
	local io_outer = require("io") -- captured as upvalue
	local thread = threads.new(function(input)
		-- io_outer is nil here in the new Lua state
		local ok, err = pcall(function()
			return io_outer.write
		end)
		assert(not ok, "expected upvalue to be nil in new Lua state")
		-- but re-requiring works fine
		local io_inner = require("io")
		assert(io_inner ~= nil)
		assert(type(io_inner.write) == "function")
		return "ok"
	end)
	thread:run(true)
	local ret, err = thread:join()

	if err then error(err) end

	T(ret)["=="]("ok")
end)
