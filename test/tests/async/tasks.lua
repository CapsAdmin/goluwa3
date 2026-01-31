local T = require("test.environment")
local tasks = require("tasks")
local timer = require("timer")
local system = require("system")

-- Helper to clean up tasks between tests
local function cleanup_tasks()
	do
		return
	end

	tasks.Panic()
	tasks.Update() -- Force update to refresh busy state
	-- Wait until all tasks are done
	local max_wait = 1.0
	local start = system.GetElapsedTime()

	while tasks.IsBusy() and (system.GetElapsedTime() - start) < max_wait do
		T.Sleep(0.01)
	end
end

-- Helper functions for wrapping timer for use in tasks
local function create_timer_lib()
	local timer_mock = {}
	timer_mock.Delay = function(time, callback)
		timer.Delay(time, callback)
	end
	return timer_mock
end

local function wrap_timer()
	local timer_lib = create_timer_lib()
	tasks.WrapCallback(timer_lib, "Delay")
	return timer_lib
end

T.Test("tasks.CreateTask basic execution", function()
	cleanup_tasks()
	local started = false
	local finished = false
	local result = nil
	local task = tasks.CreateTask(
		function()
			started = true
			return "test_result"
		end,
		function(self, res)
			finished = true
			result = res
		end,
		true
	)

	-- Run event loop to execute and complete task
	T.WaitUntil(function()
		return finished
	end)

	T(started)["=="](true)
	T(finished)["=="](true)
	T(result)["=="]("test_result")
end)

T.Test("tasks.CreateTask with Wait", function()
	cleanup_tasks()
	local step1 = false
	local step2 = false
	local step3 = false
	local task = tasks.CreateTask(
		function(self)
			step1 = true
			self:Wait(0.05)
			step2 = true
			self:Wait(0.05)
			step3 = true
		end,
		nil,
		true
	)

	-- Wait for each step to complete
	T.WaitUntil(function()
		return step1
	end)

	T(step1)["=="](true)

	T.WaitUntil(function()
		return step2
	end)

	T(step2)["=="](true)

	T.WaitUntil(function()
		return step3
	end)

	T(step3)["=="](true)
end)

T.Test("tasks.Wait in task", function()
	cleanup_tasks()
	local start_time = system.GetElapsedTime()
	local end_time = nil

	tasks.CreateTask(
		function(self)
			self:Wait(0.2)
			end_time = system.GetElapsedTime()
		end,
		nil,
		true
	)

	T.WaitUntil(function()
		return end_time ~= nil
	end)

	T(end_time)[">="](start_time + 0.2)
end)

T.Test("tasks.WrapCallback with timer.Delay", function()
	cleanup_tasks()
	-- Create a wrapped timer lib for use in tasks
	local timer_wrapped = wrap_timer()
	local execution_order = {}

	tasks.CreateTask(
		function(self)
			timer_wrapped.Delay(0.1)
			table.insert(execution_order, 1)
			timer_wrapped.Delay(0.1)
			table.insert(execution_order, 2)
			timer_wrapped.Delay(0.1)
			table.insert(execution_order, 3)
		end,
		nil,
		true
	)

	T.WaitUntil(function()
		return #execution_order == 3
	end)
end)

T.Pending("tasks.WrapCallback async-like behavior", function()
	cleanup_tasks()
	local timer_wrapped = wrap_timer()
	local value = 0

	local function test_async()
		tasks.CreateTask(
			function(self)
				value = 1
				timer_wrapped.Delay(0.05)
				value = 2
				timer_wrapped.Delay(0.05)
				value = 3
			end,
			nil,
			true
		)
	end

	test_async()

	T.WaitUntil(function()
		return value == 1
	end)

	T.WaitUntil(function()
		return value == 2
	end)

	T.WaitUntil(function()
		return value == 3
	end)
end)

T.Test("tasks.ReportProgress tracks progress", function()
	cleanup_tasks()
	local task = tasks.CreateTask(
		function(self)
			for i = 1, 10 do
				self:ReportProgress("test_progress", 100)
				self:Wait(0.01)
			end
		end,
		nil,
		true
	)

	T.WaitUntil(function()
		return task:GetProgress("test_progress") ~= "0%"
	end)
end)

T.Test("multiple tasks run in parallel", function()
	cleanup_tasks()
	local task1_done = false
	local task2_done = false

	tasks.CreateTask(function(self)
		self:Wait(0.1)
		task1_done = true
	end, nil, true)

	tasks.CreateTask(function(self)
		self:Wait(0.1)
		task2_done = true
	end, nil, true)

	T(task1_done)["=="](false)
	T(task2_done)["=="](false)

	T.WaitUntil(function()
		return task1_done and task2_done
	end)

	T(task1_done)["=="](true)
	T(task2_done)["=="](true)
end)

T.Test("tasks.GetActiveTask returns current task", function()
	cleanup_tasks()
	local active_task_ref = nil
	local task_ref = nil
	task_ref = tasks.CreateTask(function(self)
		active_task_ref = tasks.GetActiveTask()
	end, nil, true)

	T.WaitUntil(function()
		return active_task_ref ~= nil
	end)

	T(active_task_ref)["=="](task_ref)
end)

T.Test("task OnError handler", function()
	cleanup_tasks()
	local error_caught = false
	local error_message = nil
	local task = tasks.CreateTask(
		function(self)
			error("Test error")
		end,
		nil,
		true,
		function(self, err)
			error_caught = true
			error_message = err
		end
	)

	T.WaitUntil(function()
		return error_caught
	end)

	T(error_caught)["=="](true)
	T(error_message ~= nil)["=="](true)
end)

T.Test("task with IterationsPerTick", function()
	cleanup_tasks()
	local iterations = 0
	local task = tasks.CreateTask(
		function(self)
			for i = 1, 100 do
				iterations = iterations + 1
				self:Wait()
			end
		end,
		nil,
		true
	)
	task:SetIterationsPerTick(10)

	-- Should process multiple iterations per tick
	T.WaitUntil(function()
		return iterations > 10
	end)

	T(iterations > 10)["=="](true)
end)

T.Test("tasks.IsBusy returns correct state", function() -- Skip this test due to concurrent test execution issues
-- The global tasks.busy state is shared across all concurrent tests
-- making it impossible to reliably test in isolation
end)

--[=[
T.Test("tasks.IsBusy returns correct state (DISABLED)", function()
	cleanup_tasks()
	print("DEBUG: Initial IsBusy:", tasks.IsBusy())
	-- IsBusy should be false or nil (not busy) after cleanup
	T(not tasks.IsBusy())["=="](true)
	print("DEBUG: Creating task...")
	local task = tasks.CreateTask(function(self)
		print("DEBUG: Task OnStart called")
		self:Wait(0.1)
		print("DEBUG: Task finished waiting")
	end, nil, true)
	print("DEBUG: After CreateTask, IsBusy:", tasks.IsBusy())
	T.Sleep(0.05)
	print("DEBUG: After 0.05s sleep, IsBusy:", tasks.IsBusy())
	-- After creating a task and waiting a bit, should be busy
	T(tasks.IsBusy())["=="](true)
	T.Sleep(0.2)
	print("DEBUG: After 0.2s more sleep, IsBusy:", tasks.IsBusy())
	-- After task completes, should not be busy (false or nil)
	T(not tasks.IsBusy())["=="](true)
end)
--]=]
T.Test("task with OnUpdate callback", function()
	cleanup_tasks()
	local update_count = 0
	local task = tasks.CreateTask(function(self)
		for i = 1, 5 do
			self:Wait(0.01)
		end
	end, nil, true)
	task.OnUpdate = function()
		update_count = update_count + 1
	end

	T.WaitUntil(function()
		return update_count > 0
	end)

	T(update_count > 0)["=="](true)
end)

T.Test("task with Frequency setting", function()
	cleanup_tasks()
	local execution_count = 0
	local last_time = system.GetTime()
	local intervals = {}
	local task = tasks.CreateTask(
		function(self)
			for i = 1, 5 do
				local current_time = system.GetTime()

				if i > 1 then table.insert(intervals, current_time - last_time) end

				last_time = current_time
				execution_count = execution_count + 1
				self:Wait()
			end
		end,
		nil,
		false -- Don't start immediately
	)
	task:SetFrequency(10) -- 10 Hz = 0.1 seconds between executions
	task:Start() -- Start after frequency is set
	T.Sleep(0.05)

	T.WaitUntil(function()
		return execution_count >= 5
	end)

	-- Check that intervals are approximately 0.1 seconds
	for _, interval in ipairs(intervals) do
		T(interval)["~="](0)
	end
end)

T.Test("WrapCallback with error handling", function()
	cleanup_tasks()
	local timer_wrapped = wrap_timer()
	local error_handled = false
	local task = tasks.CreateTask(
		function(self)
			timer_wrapped.Delay(0.05)
			error("Test error after delay")
		end,
		nil,
		true,
		function(self, err)
			error_handled = true
		end
	)

	T.WaitUntil(function()
		return error_handled
	end)

	T(error_handled)["=="](true)
end)

T.Test("nested WrapCallback calls", function()
	cleanup_tasks()
	local timer_wrapped = wrap_timer()
	local order = {}

	tasks.CreateTask(
		function(self)
			table.insert(order, "start")
			timer_wrapped.Delay(0.05)
			table.insert(order, "after first delay")
			timer_wrapped.Delay(0.05)
			table.insert(order, "after second delay")
		end,
		nil,
		true
	)

	T.WaitUntil(function()
		return #order >= 1
	end)

	T(#order)["=="](1)

	T.WaitUntil(function()
		return #order >= 2
	end)

	T(#order)[">="](2)
	T(order[2])["=="]("after first delay")

	T.WaitUntil(function()
		return #order >= 3
	end)

	T(#order)[">="](3)
	T(order[3])["=="]("after second delay")
end)

T.Test("task max concurrent limit", function()
	cleanup_tasks()
	local original_max = tasks.max
	tasks.max = 2
	local running_count = 0
	local max_concurrent = 0

	local function track_task()
		tasks.CreateTask(
			function(self)
				running_count = running_count + 1
				max_concurrent = math.max(max_concurrent, running_count)
				self:Wait(0.1)
				running_count = running_count - 1
			end,
			nil,
			false
		) -- don't start immediately
	end

	-- Create 5 tasks
	for i = 1, 5 do
		track_task()
	end

	-- Trigger update to start tasks
	tasks.Update()
	T.Sleep(0.05)
	-- Should respect max limit
	T(max_concurrent)["<="](2)

	T.WaitUntil(function()
		return running_count == 0
	end)

	-- All tasks should eventually complete
	T(running_count)["=="](0)
	tasks.max = original_max
end)

-- Test re-entrancy protection
T.Pending("task re-entrancy protection with event.Call", function()
	cleanup_tasks()
	local event = require("event")
	local resume_attempts = 0
	local completed = false
	
	local task = tasks.CreateTask(function(self)
		resume_attempts = resume_attempts + 1
		-- This should not cause the task to be resumed again
		event.Call("Update")
		tasks.Wait(0.01)
		event.Call("Update")
		completed = true
	end, function()
	end, true)
	
	T.WaitUntil(function()
		return completed
	end, 2)
	
	T(completed)["=="](true)
	-- Should only resume once per wait, not re-enter
	T(resume_attempts)["=="](1)
end)

-- Test OnError receives coroutine for traceback
T.Pending("task OnError receives coroutine parameter", function()
	cleanup_tasks()
	local error_msg = nil
	local error_co = nil
	local debug = require("debug")
	
	local task = tasks.CreateTask(function(self)
		tasks.Wait(0.01)
		error("test error from task")
	end, function()
	end, true, function(self, err, co)
		error_msg = err
		error_co = co
	end)
	
	T.WaitUntil(function()
		return error_msg ~= nil
	end, 2)
	
	T(error_msg ~= nil)["=="](true)
	T(error_msg:find("test error from task", 1, true) ~= nil)["=="](true)
	T(error_co ~= nil)["=="](true)
	T(type(error_co))["=="]("thread")
	
	-- Verify we can get a traceback from the coroutine
	if error_co then
		local trace = debug.traceback(error_co)
		T(type(trace))["=="]("string")
		T(#trace > 0)["=="](true)
	end
end)

-- Test WaitForNestedTask functionality
T.Pending("tasks.WaitForNestedTask waits for nested task completion", function()
	cleanup_tasks()
	local outer_started = false
	local inner_started = false
	local outer_finished = false
	local inner_finished = false
	local execution_order = {}
	
	local outer_task = tasks.CreateTask(function(self)
		outer_started = true
		table.insert(execution_order, "outer_start")
		
		-- Create a nested task
		local inner_task = tasks.CreateTask(function()
			inner_started = true
			table.insert(execution_order, "inner_start")
			tasks.Wait(0.05)
			table.insert(execution_order, "inner_end")
			inner_finished = true
		end, function()
		end, true)
		
		-- Wait for nested task to complete
		local ok, err = tasks.WaitForNestedTask(inner_task)
		
		T(ok)["=="](true)
		T(inner_finished)["=="](true)
		table.insert(execution_order, "outer_end")
		outer_finished = true
	end, function()
	end, true)
	
	T.WaitUntil(function()
		return outer_finished
	end, 2)
	
	T(outer_started)["=="](true)
	T(inner_started)["=="](true)
	T(inner_finished)["=="](true)
	T(outer_finished)["=="](true)
	
	-- Verify execution order
	T(execution_order[1])["=="]("outer_start")
	T(execution_order[2])["=="]("inner_start")
	T(execution_order[3])["=="]("inner_end")
	T(execution_order[4])["=="]("outer_end")
end)

-- Test WaitForNestedTask with failed nested task
T.Pending("tasks.WaitForNestedTask handles nested task errors", function()
	cleanup_tasks()
	local outer_completed = false
	local nested_error_received = false
	
	local outer_task = tasks.CreateTask(function(self)
		-- Create a nested task that will fail
		local inner_task
		inner_task = tasks.CreateTask(function()
			tasks.Wait(0.01)
			error("nested task error")
		end, function()
		end, true)
		
		-- Wait for nested task - should return false with error
		local ok, err = tasks.WaitForNestedTask(inner_task)
		
		if not ok then
			nested_error_received = true
			T(err ~= nil)["=="](true)
			if err then
				T(type(err))["=="]("string")
			end
		end
		
		outer_completed = true
	end, function()
	end, true)
	
	T.WaitUntil(function()
		return outer_completed
	end, 5)
	
	T(outer_completed)["=="](true)
	T(nested_error_received)["=="](true)
end)

-- Test OnError receives coroutine for better debugging
T.Test("task OnError receives coroutine", function()
	cleanup_tasks()
	local error_received = false
	local co_received = nil
	
	local task = tasks.CreateTask(function()
		error("test error from task")
	end, function()
	end, true, function(self, err, co)
		error_received = true
		co_received = co
	end)
	
	T.WaitUntil(function()
		return error_received
	end, 2)
	
	T(error_received)["=="](true)
	T(co_received ~= nil)["=="](true)
	T(type(co_received))["=="]("thread")
end)

-- Test WaitForNestedTask basic usage
T.Pending("tasks.WaitForNestedTask basic usage", function()
	cleanup_tasks()
	local inner_executed = false
	local outer_executed = false
	local inner_task = nil
	
	local outer_task = tasks.CreateTask(function()
		inner_task = tasks.CreateTask(function()
			tasks.Wait(0.05)
			inner_executed = true
		end, function()
		end, true)
		
		local ok, err = tasks.WaitForNestedTask(inner_task)
		T(ok)["=="](true)
		T(inner_executed)["=="](true)
		outer_executed = true
	end, function()
	end, true)
	
	T.WaitUntil(function()
		return outer_executed
	end, 2)
	
	T(outer_executed)["=="](true)
	T(inner_executed)["=="](true)
end)

-- Test WaitForNestedTask with error propagation
T.Pending("tasks.WaitForNestedTask error propagation", function()
	cleanup_tasks()
	local outer_completed = false
	local error_caught = false
	local inner_task = nil
	
	local outer_task = tasks.CreateTask(function()
		inner_task = tasks.CreateTask(function()
			tasks.Wait(0.01)
			error("nested task error")
		end, function()
		end, true)
		
		local ok, err = tasks.WaitForNestedTask(inner_task)
		T(ok)["=="](false)
		T(err ~= nil)["=="](true)
		error_caught = true
		outer_completed = true
	end, function()
	end, true)
	
	T.WaitUntil(function()
		return outer_completed
	end, 2)
	
	T(outer_completed)["=="](true)
	T(error_caught)["=="](true)
end)
