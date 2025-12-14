require("test.environment")
local timer = require("timer")
local system = require("system")

test("timer.Delay executes callback after 200ms", function()
	local callback_executed = false
	local callback_time = nil
	local start_time = system.GetElapsedTime()

	timer.Delay(0.2, function()
		callback_executed = true
		callback_time = system.GetElapsedTime()
	end)

	-- Timer should not have executed yet
	attest.equal(callback_executed, false)
	-- Run event loop for 250ms to ensure timer fires
	run_for(0.25)
	-- Now the callback should have executed
	attest.equal(callback_executed, true)
	-- Verify it executed after approximately 200ms
	local elapsed = callback_time - start_time
	attest.ok(
		elapsed >= 0.2,
		"Timer should execute after at least 200ms, got " .. tostring(elapsed)
	)
	attest.ok(elapsed < 0.3, "Timer should execute before 300ms, got " .. tostring(elapsed))
end)

test("timer.Delay with immediate execution", function()
	local callback_executed = false

	timer.Delay(0, function()
		callback_executed = true
	end)

	-- Should not execute immediately
	attest.equal(callback_executed, false)
	-- Run one update cycle
	run_for(0.02)
	-- Now should be executed
	attest.equal(callback_executed, true)
end)

test("timer.Repeat executes multiple times", function()
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
	attest.equal(execution_count, 0)
	-- Run for enough time to execute all 3 times
	run_for(0.35)
	-- Should have executed 3 times
	attest.equal(execution_count, 3)

	-- Verify timing between executions
	if #times >= 2 then
		local interval = times[2] - times[1]
		attest.ok(interval >= 0.09, "Interval should be at least 90ms, got " .. tostring(interval))
		attest.ok(interval <= 0.15, "Interval should be at most 150ms, got " .. tostring(interval))
	end
end)

test("run_until helper with timer", function()
	local done = false

	timer.Delay(0.15, function()
		done = true
	end)

	local success = run_until(function()
		return done
	end, 1.0)
	attest.equal(success, true, "Should complete before timeout")
	attest.equal(done, true, "Callback should have executed")
end)

test("run_until timeout", function()
	local never_true = false
	local success = run_until(function()
		return never_true
	end, 0.1)
	attest.equal(success, false, "Should timeout")
end)
