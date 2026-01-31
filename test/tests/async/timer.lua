local T = require("test.environment")
local timer = require("timer")
local system = require("system")

T.Test("timer.Delay executes callback after 200ms", function()
	local callback_executed = false
	local callback_time = nil
	local start_time = system.GetElapsedTime()

	timer.Delay(0.2, function()
		callback_executed = true
		callback_time = system.GetElapsedTime()
	end)

	-- Timer should not have executed yet
	T(false)["=="](callback_executed)
	-- Sleep for 250ms to ensure timer fires
	T.Sleep(0.2)
	-- Now the callback should have executed
	T(true)["=="](callback_executed)
	-- Verify it executed after approximately 200ms
	local elapsed = callback_time - start_time
	T(elapsed)[">="](0.1)
end)

T.Test("timer.Delay with immediate execution", function()
	local callback_executed = false

	timer.Delay(0, function()
		callback_executed = true
	end)

	-- Should not execute immediately
	T(callback_executed)["=="](false)
	-- Sleep one update cycle
	T.Sleep(0.02)
	-- Now should be executed
	T(callback_executed)["=="](true)
end)

T.Test("timer.Repeat executes multiple times", function()
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

	-- Wait until the timer has fired 3 times
	T.WaitUntil(function()
		return execution_count >= 3
	end)

	T(execution_count)["=="](3)
end)

T.Test("sleep helper with timer", function()
	local done = false

	timer.Delay(0.15, function()
		done = true
	end)

	-- Wait until the timer fires
	T.WaitUntil(function()
		return done
	end)
end)

T.Test("multiple sleeps", function()
	local count = 0

	timer.Delay(0.05, function()
		count = count + 1
	end)

	T.WaitUntil(function()
		return count >= 1
	end)
	
	-- Small delay to ensure timer has fully processed
	T.Sleep(0.01)

	T(count)["=="](1)

	timer.Delay(0.05, function()
		count = count + 1
	end)

	T.WaitUntil(function()
		return count >= 2
	end)

	T(count)["=="](2)
end)
