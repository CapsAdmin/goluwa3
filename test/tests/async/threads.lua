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

T.Test("pool runs workers in parallel threads", function()
	local worker_source = [[
		local input = ...
		local sum = 0

		for i = 1, input.n do
			sum = (sum + i) % 1000003
		end

		return {id = input.id, sum = sum}
	]]
	local pool = threads.new_pool(worker_source, 4)

	for round = 1, 20 do
		local items = {}

		for i = 1, 4 do
			items[i] = {id = round * 100 + i, n = 50 + i * 17}
		end

		pool:submit_all(items)
		local results, errs = pool:wait_all()

		if errs then error(table.concat(errs, " | ")) end

		for i = 1, 4 do
			local expected = 0

			for k = 1, items[i].n do
				expected = (expected + k) % 1000003
			end

			if results[i].id ~= items[i].id then
				error("pool result id mismatch: " .. tostring(results[i].id))
			end

			if results[i].sum ~= expected then
				error("pool result sum mismatch: " .. tostring(results[i].sum))
			end
		end
	end

	pool:shutdown()
end)

T.Test("pool rejects non-string worker source", function()
	local ok, err = pcall(function()
		threads.new_pool(function() end, 2)
	end)

	T(ok)["=="](false)
	T(tostring(err):find("worker source string", 1, true))["~="](nil)
end)

T.Test("pool surfaces worker errors", function()
	local pool = threads.new_pool([[
		local input = ...
		error("boom " .. input.id)
	]], 2)
	pool:submit(1, {id = 7})
	local result, err = pool:wait(1)

	T(result)["=="](nil)
	T(err:find("boom 7", 1, true))["~="](nil)

	-- pool thread survives a failed task and can take more work
	pool:submit(1, {id = 8})

	local result2, err2 = pool:wait(1)

	T(result2)["=="](nil)
	T(err2:find("boom 8", 1, true))["~="](nil)
	pool:shutdown()
end)
