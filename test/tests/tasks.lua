do
	return
end

local T = require("test.t")
local tasks = require("tasks")
local timer = require("timer")
local system = require("system")
-- Enable tasks for testing
tasks.enabled = true

T.test("tasks.CreateTask basic execution", function()
	local started = false
	local finished = false
	local result = nil
	local task = tasks.CreateTask(
		function()
			started = true
			return "test_result"
		end,
		function(res)
			finished = true
			result = res
		end,
		true
	)
	-- Run event loop to execute and complete task
	T.sleep(0.1)
	T(started)["=="](true)
	T(finished)["=="](true)
	T(result)["=="]("test_result")
end)

T.test("tasks.CreateTask with Wait", function()
	local step1 = false
	local step2 = false
	local step3 = false
	local task = tasks.CreateTask(
		function(self)
			print("Setting step1")
			step1 = true
			self:Wait(0.05)
			print("Setting step2")
			step2 = true
			self:Wait(0.05)
			print("Setting step3")
			step3 = true
		end,
		nil,
		true
	)
	task.debug = true
	-- Step 1 should execute initially
	T.sleep(0.1)
	print("After first run_for: step1=", step1, "step2=", step2, "step3=", step3)
	T(step1)["=="](true)
	T(step2)["=="](false)
	T(step3)["=="](false)
	-- After waiting, step 2 should execute
	T.sleep(0.1)
	print("After second run_for: step1=", step1, "step2=", step2, "step3=", step3)
	T(step2)["=="](true)
	T(step3)["=="](false)
	-- After another wait, step 3 should execute
	T.sleep(0.1)
	print("After third run_for: step1=", step1, "step2=", step2, "step3=", step3)
	T(step3)["=="](true)
end)

T.test("tasks.Wait in task", function()
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

	T.sleep(0.3)
	T(end_time)[">="](start_time + 0.2)
end)

T.test("tasks.WrapCallback with timer.Delay", function()
	-- Wrap timer.Delay to work synchronously in tasks
	tasks.WrapCallback(timer, "Delay")
	local execution_order = {}

	tasks.CreateTask(
		function(self)
			table.insert(execution_order, 1)
			timer.Delay(0.1)
			table.insert(execution_order, 2)
			timer.Delay(0.1)
			table.insert(execution_order, 3)
		end,
		nil,
		true
	)

	-- Should have started
	T.sleep(0.1)
	T(#execution_order)["=="](1)
	T(execution_order[1])["=="](1)
	-- After first delay
	T.sleep(0.15)
	T(#execution_order)["=="](2)
	T(execution_order[2])["=="](2)
	-- After second delay
	T.sleep(0.15)
	T(#execution_order)["=="](3)
	T(execution_order[3])["=="](3)
end)

T.test("tasks.WrapCallback async-like behavior", function()
	tasks.WrapCallback(timer, "Delay")
	local value = 0

	local function test_async()
		tasks.CreateTask(
			function(self)
				value = 1
				timer.Delay(0.05)
				value = 2
				timer.Delay(0.05)
				value = 3
			end,
			nil,
			true
		)
	end

	test_async()
	-- Value should be 1 after initial execution
	T.sleep(0.1)
	T(value)["=="](1)
	-- After first delay
	T.sleep(0.1)
	T(value)["=="](2)
	-- After second delay
	T.sleep(0.1)
	T(value)["=="](3)
end)

T.test("tasks.ReportProgress tracks progress", function()
	local task = tasks.CreateTask(
		function(self)
			for i = 1, 10 do
				self:ReportProgress("test_progress", 10)
				self:Wait(0.01)
			end
		end,
		nil,
		true
	)
	task.debug = true
	T.sleep(0.1)
	local progress = task:GetProgress("test_progress")
	T(progress ~= "0%")["=="](true)
	T.sleep(0.2)
	-- Should have completed
	T(task:GetProgress("test_progress"))["=="]("0%") -- reset after completion
end)

T.test("multiple tasks run in parallel", function()
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
	T.sleep(0.2)
	T(task1_done)["=="](true)
	T(task2_done)["=="](true)
end)

T.test("tasks.GetActiveTask returns current task", function()
	local active_task_ref = nil
	local task_ref = nil
	task_ref = tasks.CreateTask(function(self)
		active_task_ref = tasks.GetActiveTask()
	end, nil, true)
	T.sleep(0.1)
	T(active_task_ref)["=="](task_ref)
end)

T.test("task OnError handler", function()
	local error_caught = false
	local error_message = nil
	local task = tasks.CreateTask(function(self)
		error("Test error")
	end, nil, true)
	task.OnError = function(self, err)
		error_caught = true
		error_message = err
	end
	T.sleep(0.1)
	T(error_caught)["=="](true)
	T(error_message ~= nil)["=="](true)
end)

T.test("task with IterationsPerTick", function()
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
	T.sleep(0.1)
	T(iterations > 10)["=="](true)
end)

T.test("tasks.IsBusy returns correct state", function()
	T(tasks.IsBusy())["=="](false)
	local task = tasks.CreateTask(function(self)
		self:Wait(0.1)
	end, nil, true)
	T.sleep(0.05)
	T(tasks.IsBusy())["=="](true)
	T.sleep(0.2)
	T(tasks.IsBusy())["=="](false)
end)

T.test("task with OnUpdate callback", function()
	local update_count = 0
	local task = tasks.CreateTask(function(self)
		for i = 1, 5 do
			self:Wait(0.01)
		end
	end, nil, true)
	task.OnUpdate = function()
		update_count = update_count + 1
	end
	T.sleep(0.1)
	T(update_count > 0)["=="](true)
end)

T.test("tasks.Panic removes all tasks", function()
	local task1_finished = false
	local task2_finished = false

	tasks.CreateTask(
		function(self)
			self:Wait(0.1)
		end,
		function()
			task1_finished = true
		end,
		true
	)

	tasks.CreateTask(
		function(self)
			self:Wait(0.1)
		end,
		function()
			task2_finished = true
		end,
		true
	)

	T.sleep(0.01)
	T(tasks.IsBusy())["=="](true)
	tasks.Panic()
	T.sleep(0.01)
	T(tasks.IsBusy())["=="](false)
	T(task1_finished)["=="](false)
	T(task2_finished)["=="](false)
end)

T.test("task with Frequency setting", function()
	local execution_count = 0
	local last_time = system.GetElapsedTime()
	local intervals = {}
	local task = tasks.CreateTask(
		function(self)
			for i = 1, 5 do
				local current_time = system.GetElapsedTime()

				if i > 1 then table.insert(intervals, current_time - last_time) end

				last_time = current_time
				execution_count = execution_count + 1
				self:Wait()
			end
		end,
		nil,
		true
	)
	task:SetFrequency(10) -- 10 times per second
	T.sleep(0.6)
	T(execution_count)["=="](5)

	-- Check that intervals are approximately 0.1 seconds
	for _, interval in ipairs(intervals) do
		T(interval)[">="](0.05)
		T(interval)["<="](0.15)
	end
end)

T.test("WrapCallback with error handling", function()
	tasks.WrapCallback(timer, "Delay")
	local error_handled = false
	local task = tasks.CreateTask(
		function(self)
			timer.Delay(0.05)
			error("Test error after delay")
		end,
		nil,
		true
	)
	task.OnError = function(self, err)
		error_handled = true
	end
	T.sleep(0.1)
	T(error_handled)["=="](true)
end)

T.test("task Report method (debug mode)", function()
	local task = tasks.CreateTask(
		function(self)
			self:Report("Starting task")
			self:Wait(0.05)
			self:Report("Task in progress")
		end,
		nil,
		true
	)
	task.debug = true
	T.sleep(0.1)
	-- Just verify it doesn't crash - logging is internal
	T(true)["=="](true)
end)

T.test("nested WrapCallback calls", function()
	tasks.WrapCallback(timer, "Delay")
	local order = {}

	tasks.CreateTask(
		function(self)
			table.insert(order, "start")
			timer.Delay(0.05)
			table.insert(order, "after first delay")
			timer.Delay(0.05)
			table.insert(order, "after second delay")
		end,
		nil,
		true
	)

	T.sleep(0.02)
	T(#order)["=="](1)
	T.sleep(0.05)
	T(#order)["=="](2)
	T(order[2])["=="]("after first delay")
	T.sleep(0.05)
	T(#order)["=="](3)
	T(order[3])["=="]("after second delay")
end)

T.test("task max concurrent limit", function()
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
	T.sleep(0.05)
	-- Should respect max limit
	T(max_concurrent)["<="](2)
	T.sleep(0.5)
	-- All tasks should eventually complete
	T(running_count)["=="](0)
	tasks.max = original_max
end)
