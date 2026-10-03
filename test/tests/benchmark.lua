local T = import("test/environment.lua")
local benchmark = import("goluwa/benchmark.lua")
local QUICK = {time = 0.05, warmup = 0.01, max_time = 1}
local sink = 0

local function work(count)
	return function()
		local sum = 0

		for i = 1, count do
			sum = sum + i * 0.5
		end

		sink = sum
	end
end

T.Test("benchmark run reports what a call costs", function()
	local fast = benchmark.Run("test fast", work(100), QUICK)
	local slow = benchmark.Run("test slow", work(10000), QUICK)
	T(fast.samples)[">="](20)
	T(fast.min <= fast.median and fast.median <= fast.p95)["=="](true)
	-- 100 times the work is about 100 times the time, the loop is far from free of overhead so be generous
	T(slow.median / fast.median)[">"](20)
	T(slow.median / fast.median)["<"](500)
end)

T.Test("benchmark compare tells a slower variant from the first", function()
	local results = benchmark.Compare("test compare", {
		{name = "a", func = work(1000)},
		{name = "same", func = work(1000)},
		{name = "four times", func = work(4000)},
	}, QUICK)
	T(results[2].ratio)[">"](0.7)
	T(results[2].ratio)["<"](1.4)
	T(results[3].ratio)[">"](2.5)
	T(results[3].ratio)["<"](6)
end)
