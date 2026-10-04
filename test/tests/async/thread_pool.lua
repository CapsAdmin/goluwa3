local T = import("test/environment.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ffi = require("ffi")
local scenarios = {}

local function scenario(name, fn)
	scenarios[#scenarios + 1] = {name = name, fn = fn}
end

local function with_threads(count, fn)
	local previous = pvars.Get("r_codec_threads")
	pvars.SetSession("r_codec_threads", count)
	thread_pool.Shutdown()
	local ok, err = pcall(fn)
	thread_pool.Shutdown()
	pvars.SetSession("r_codec_threads", previous)

	if not ok then error(err, 0) end
end

local sum_job = [[
	local input = ...
	local sum = 0

	for i = 1, input.n do
		sum = (sum + i) % 1000003
	end

	return {id = input.id, sum = sum}
]]
local blob_job = [[
	local ffi = require("ffi")
	local input = ...
	local out = ffi.new("uint8_t[?]", input.n)

	for i = 0, input.n - 1 do
		out[i] = (i * input.mul) % 251
	end

	return {n = input.n}, out
]]

scenario("thread_pool runs small jobs inline", function()
	with_threads(4, function()
		local job = thread_pool.Run(sum_job, {id = 1, n = 100}, 10)
		T(job:IsDone())["=="](true)
		local meta = job:Await()
		T(meta.id)["=="](1)
		T(thread_pool.pool)["=="](nil)
	end)
end)

scenario("thread_pool runs big jobs on workers and keeps results in order", function()
	with_threads(4, function()
		local jobs = {}

		for i = 1, 24 do
			jobs[i] = thread_pool.Run(sum_job, {id = i, n = 200000 + i}, 1e9)
		end

		T(thread_pool.pool ~= nil)["=="](true)

		for i = 1, 24 do
			local meta = jobs[i]:Await()
			T(meta.id)["=="](i)
			local inline = thread_pool.Run(sum_job, {id = i, n = 200000 + i}, 0):Await()
			T(meta.sum)["=="](inline.sum)
		end
	end)
end)

scenario("thread_pool carries blobs as raw bytes and matches the inline result", function()
	with_threads(4, function()
		local meta, blob = thread_pool.Run(blob_job, {n = 100000, mul = 7}, 1e9):Await()
		local inline_meta, inline_blob = thread_pool.Run(blob_job, {n = 100000, mul = 7}, 0):Await()
		T(meta.n)["=="](100000)
		T(blob.len)["=="](100000)
		T(inline_blob.len)["=="](100000)
		T(ffi.string(blob.ptr, blob.len) == ffi.string(inline_blob.ptr, inline_blob.len))["=="](true)
	end)
end)

scenario("thread_pool surfaces worker errors with a traceback", function()
	with_threads(2, function()
		local job = thread_pool.Run(
			[[
			local function boom() error("Intentional Error") end
			boom()
		]],
			{},
			1e9
		)
		local ok, err = pcall(job.Await, job)
		T(ok)["=="](false)
		T(err:find("Intentional Error", 1, true) ~= nil)["=="](true)
		T(err:find("traceback", 1, true) ~= nil)["=="](true)
		local meta = thread_pool.Run(sum_job, {id = 5, n = 10}, 1e9):Await()
		T(meta.id)["=="](5)
	end)
end)

scenario("thread_pool inline errors also throw", function()
	with_threads(0, function()
		local job = thread_pool.Run("error('inline boom')", {}, 1e9)
		local ok, err = pcall(job.Await, job)
		T(ok)["=="](false)
		T(err:find("inline boom", 1, true) ~= nil)["=="](true)
	end)
end)

scenario("thread_pool fills 8 workers and drains a longer queue", function()
	with_threads(8, function()
		local jobs = {}

		for i = 1, 40 do
			jobs[i] = thread_pool.Run(sum_job, {id = i, n = 50000}, 1e9)
		end

		for i = 1, 40 do
			T(jobs[i]:Await().id)["=="](i)
		end

		local spawned = 0

		for i = 1, 8 do
			if thread_pool.pool:is_spawned(i) then spawned = spawned + 1 end
		end

		T(spawned)["=="](8)
	end)
end)

scenario("thread_pool OnDone callbacks fire", function()
	with_threads(2, function()
		local got
		local job = thread_pool.Run(sum_job, {id = 9, n = 1000}, 1e9)

		job:OnDone(function(j)
			got = j.meta.id
		end)

		job:Await()
		T(got)["=="](9)
	end)
end)

T.Test("thread_pool", function()
	for _, entry in ipairs(scenarios) do
		local ok, err = pcall(entry.fn)

		if not ok then error(entry.name .. ": " .. tostring(err), 0) end
	end
end)
