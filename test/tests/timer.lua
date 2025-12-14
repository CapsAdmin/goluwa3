local T = require("test.t")
local timer = require("timer")
local system = require("system")

T.test("timer.Delay executes callback after 200ms", function()
	local callback_executed = false
	local callback_time = nil
	local start_time = system.GetElapsedTime()

	timer.Delay(0.2, function()
		callback_executed = true
		callback_time = system.GetElapsedTime()
	end)

	-- Timer should not have executed yet
	T(false)["=="](callback_executed)
	-- Run event loop for 250ms to ensure timer fires
	T.run_for(0.25)
	-- Now the callback should have executed
	T(true)["=="](callback_executed)
	-- Verify it executed after approximately 200ms
	local elapsed = callback_time - start_time
	T(elapsed)[">="](0.2)
	T(elapsed)["<"](0.3)
end)

T.test("timer.Delay with immediate execution", function()
	local callback_executed = false

	timer.Delay(0, function()
		callback_executed = true
	end)

	-- Should not execute immediately
	T(callback_executed)["=="](false)
	-- Run one update cycle
	T.run_for(0.02)
	-- Now should be executed
	T(callback_executed)["=="](true)
end)

T.test("timer.Repeat executes multiple times", function()
	local execution_count = 0
	local times = {}

	timer.Repeat(
		"test_repeat",
		0.1,
		3,
		function()
			execution_count = execution_count + 1
			table.insert(times, system.GetElapsedTime())
		end
	)

	-- Should not have executed yet
	T(execution_count)["=="](0)
	-- Run for enough time to execute all 3 times
	T.run_for(0.35)
	-- Should have executed 3 times
	T(execution_count)["=="](3)

	-- Verify timing between executions
	if #times >= 2 then
		local interval = times[2] - times[1]
		T(interval)[">="](0.09)
		T(interval)["<="](0.15)
	end
end)

T.test("run_until helper with timer", function()
	local done = false

	timer.Delay(0.15, function()
		done = true
	end)

	local success = T.run_until(function()
		return done
	end, 1.0)
	T(success)["=="](true)
	T(done)["=="](true)
end)

T.test("run_until timeout", function()
	local never_true = false
	local success = T.run_until(function()
		return never_true
	end, 0.1)
	T(success)["=="](false)
end)
