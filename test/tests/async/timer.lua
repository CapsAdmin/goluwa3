local T = import("test/environment.lua")
local timer = import("goluwa/timer.lua")
local system = import("goluwa/system.lua")

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

T.Test("timer.Repeat replacing an existing id does not duplicate callbacks", function()
	local old_count = 0
	local new_count = 0
	local id = "test_repeat_replace"

	timer.Repeat(id, 0.05, 3, function()
		old_count = old_count + 1
	end)

	timer.Repeat(id, 0.05, 3, function()
		new_count = new_count + 1
	end)

	local matches = 0

	for _, data in ipairs(timer.timers) do
		if data.key == id then matches = matches + 1 end
	end

	T(matches)["=="](1)

	T.WaitUntil(function()
		return new_count >= 3
	end)

	T.Sleep(0.1)

	T.WaitUntil(function()
		return not (timer.IsTimer(id) or false)
	end, 1)

	T(old_count)["=="](0)
	T(new_count)["=="](3)
	T(timer.IsTimer(id) or false)["=="](false)
end)

T.Test("timer.Thinker preserves explicit ids for removal", function()
	local count = 0
	local id = "test_thinker_remove_by_id"

	timer.Thinker(function()
		count = count + 1
	end, false, 30, true, id)

	T(timer.IsTimer(id))["=="](true)
	T(timer.RemoveTimer(id))["=="](true)
	T(timer.IsTimer(id) or false)["=="](false)
	T.Sleep(0.05)
	T(count)["=="](0)
end)

T.Test("nested timer updates do not lose pending repeat timers", function()
	local id = "test_repeat_nested_update"
	local repeat_count = 0
	local nested_updates = 0
	local reentered = false

	timer.Repeat(id, 0.05, 3, function()
		repeat_count = repeat_count + 1
	end)

	timer.Delay(0.01, function()
		if reentered then return end

		reentered = true
		nested_updates = nested_updates + 1
		system.SetElapsedTime(system.GetElapsedTime() + 0.016)
		timer.UpdateTimers()
	end)

	T.WaitUntil(function()
		return repeat_count >= 3
	end)

	T.WaitUntil(function()
		return not (timer.IsTimer(id) or false)
	end, 1)

	T(nested_updates)["=="](1)
	T(repeat_count)["=="](3)
	T(timer.IsTimer(id) or false)["=="](false)
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
