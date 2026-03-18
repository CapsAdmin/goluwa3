local T = import("test/environment.lua")
local callback = import("goluwa/callback.lua")
local timer = import("goluwa/timer.lua")

T.Test("callback.Create basic resolve", function()
	local resolved = false
	local resolved_value = nil
	local cb = callback.Create()

	cb:Then(function(value)
		resolved = true
		resolved_value = value
	end)

	cb:Resolve("test_value")
	T(resolved)["=="](true)
	T(resolved_value)["=="]("test_value")
end)

T.Test("callback.Create basic reject", function()
	local rejected = false
	local reject_reason = nil
	local cb = callback.Create()

	cb:Catch(function(reason)
		rejected = true
		reject_reason = reason
	end)

	cb:Reject("test_error")
	T(rejected)["=="](true)
	T(reject_reason)["=="]("test_error")
end)

T.Test("callback.Create multiple resolve handlers", function()
	local count = 0
	local values = {}
	local cb = callback.Create()

	cb:Then(function(value)
		count = count + 1
		table.insert(values, value)
	end)

	cb:Then(function(value)
		count = count + 1
		table.insert(values, value)
	end)

	cb:Resolve("multi_value")
	T(count)["=="](2)
	T(values[1])["=="]("multi_value")
	T(values[2])["=="]("multi_value")
end)

T.Test("callback.Create chained then", function()
	local results = {}
	local cb = callback.Create()

	cb:Then(function(value)
		table.insert(results, value)
		return value .. "_modified"
	end):Then(function(value)
		table.insert(results, value)
	end)

	cb:Resolve("initial")
	T(#results)["=="](2)
	T(results[1])["=="]("initial")
	T(results[2])["=="]("initial")
end)

T.Test("callback.Create chained then with returned callback", function()
	local results = {}
	local inner_cb = callback.Create()
	local cb = callback.Create()

	cb:Then(function(value)
		table.insert(results, value)
		return inner_cb
	end):Then(function(value)
		table.insert(results, value)
	end)

	cb:Resolve("outer")
	T(#results)["=="](1)
	T(results[1])["=="]("outer")
	inner_cb:Resolve("inner")
	T(#results)["=="](2)
	T(results[2])["=="]("inner")
end)

T.Test("callback.Create reject propagates through chain", function()
	local error_caught = false
	local error_message = nil
	local cb = callback.Create()

	cb:Then(function(value)
		return value
	end):Then(function(value)
		return value
	end):Catch(function(err)
		error_caught = true
		error_message = err
	end)

	cb:Reject("chain_error")
	T(error_caught)["=="](true)
	T(error_message)["=="]("chain_error")
end)

T.Test("callback.Create done callback", function()
	local done_called = false
	local cb = callback.Create()

	cb:Then(function() end) -- Need a resolve handler to avoid warning
	cb:Done(function()
		done_called = true
	end)

	cb:Resolve("value")
	T(done_called)["=="](true)
end)

T.Test("callback.Create done callback on reject", function()
	local done_called = false
	local cb = callback.Create()

	cb:Done(function()
		done_called = true
	end)

	cb:Catch(function() end) -- Handle rejection
	cb:Reject("error")
	T(done_called)["=="](true)
end)

T.Test("callback.Create start callback", function()
	local started = false
	local resolved = false
	local cb = callback.Create(function(self)
		started = true
		self.callbacks.resolve("from_start")
	end)

	cb:Then(function(value)
		resolved = true
	end)

	T(started)["=="](false)
	T(resolved)["=="](false)
	cb:Start()
	T(started)["=="](true)
	T(resolved)["=="](true)
end)

T.Test("callback.Create cannot resolve twice", function()
	local count = 0
	local cb = callback.Create()

	cb:Then(function()
		count = count + 1
	end)

	cb:Resolve("first")
	cb:Resolve("second")
	T(count)["=="](1)
end)

T.Test("callback.Create cannot reject resolved callback", function()
	local rejected = false
	local cb = callback.Create()

	cb:Then(function() end) -- Need resolve handler
	cb:Catch(function()
		rejected = true
	end)

	cb:Resolve("value")
	cb:Reject("error")
	T(rejected)["=="](false)
end)

T.Test("callback.Create subscribe custom events", function()
	local progress_values = {}
	local cb = callback.Create()

	cb:Subscribe("progress", function(value)
		table.insert(progress_values, value)
	end)

	cb.callbacks.progress(10)
	cb.callbacks.progress(50)
	cb.callbacks.progress(100)
	T(#progress_values)["=="](3)
	T(progress_values[1])["=="](10)
	T(progress_values[2])["=="](50)
	T(progress_values[3])["=="](100)
end)

T.Test("callback.WrapTask basic usage", function()
	local executed = false
	local passed_value = nil
	local task = callback.WrapTask(function(self, value)
		executed = true
		passed_value = value

		-- Use timer to resolve asynchronously
		timer.Delay(0, function()
			self.callbacks.resolve("result")
		end)
	end)
	local result_value = nil

	task("test_arg"):Then(function(value)
		result_value = value
	end)

	T(executed)["=="](true)
	T(passed_value)["=="]("test_arg")
	-- Result should not be set yet
	T(result_value)["=="](nil)

	do
		return
	end

	-- After event loop runs, result should be set
	T.Sleep(0.02)
	T(result_value)["=="]("result")
end)

T.Test("callback.All resolves when all callbacks resolve", function()
	local a = callback.Create()
	local b = callback.Create()
	local resolved = nil

	callback.All({a, b}):Then(function(results)
		resolved = results
	end)

	timer.Delay(0, function()
		a:Resolve("first")
	end)

	timer.Delay(0.01, function()
		b:Resolve("second", 2)
	end)

	T.Sleep(0.03)
	T(type(resolved))["=="]("table")
	T(resolved[1][1])["=="]("first")
	T(resolved[2][1])["=="]("second")
	T(resolved[2][2])["=="](2)
end)

T.Test("callback.All rejects when any callback rejects", function()
	local a = callback.Create()
	local b = callback.Create()
	local err = nil

	callback.All(a, b):Catch(function(reason)
		err = reason
	end)

	timer.Delay(0, function()
		a:Resolve("ok")
	end)

	timer.Delay(0.01, function()
		b:Reject("boom")
	end)

	T.Sleep(0.03)
	T(err)["=="]("boom")
end)

T.Test("callback.WrapKeyedTask basic usage", function()
	local executions = {}
	local task = callback.WrapKeyedTask(function(self, key, value)
		table.insert(executions, {key = key, value = value})

		timer.Delay(0, function()
			self.callbacks.resolve(key .. "_result")
		end)
	end)
	local results = {}

	task("key1", "val1"):Then(function(value)
		table.insert(results, value)
	end)

	task("key2", "val2"):Then(function(value)
		table.insert(results, value)
	end)

	-- T(#executions)["=="](2)
	-- T(executions[1].key)["=="]("key1")
	-- T(executions[1].value)["=="]("val1")
	-- Results not yet set
	T(#results)["=="](0)
	-- After event loop
	T.Sleep(0.02)
	T(results[1])["=="]("key1_result")
	T(results[2])["=="]("key2_result")
end)

T.Test("callback.WrapKeyedTask same key reuses callback when resolved", function()
	local execution_count = 0
	local task = callback.WrapKeyedTask(function(self, key)
		execution_count = execution_count + 1

		timer.Delay(0, function()
			self.callbacks.resolve("result_" .. execution_count)
		end)
	end)
	local cb1 = task("same_key")

	cb1:Then(function() end)

	T.Sleep(0.02)
	T(execution_count)["=="](1)
	-- Same key after resolution should create new callback
	local cb2 = task("same_key")

	cb2:Then(function() end)

	T.Sleep(0.02)
	T(execution_count)["=="](2)
end)

T.Test("callback.WrapKeyedTask same key shares callback when pending", function()
	local execution_count = 0
	local start_count = 0
	local task = callback.WrapKeyedTask(function(self, key)
		start_count = start_count + 1
	-- Don't resolve immediately
	end)
	local cb1 = task("same_key")

	cb1:Then(function()
		execution_count = execution_count + 1
	end)

	local cb2 = task("same_key")

	cb2:Then(function()
		execution_count = execution_count + 1
	end)

	-- Should only start once
	T(start_count)["=="](1)
	-- Both callbacks should be the same
	T(cb1)["=="](cb2)
	-- When we resolve, both should fire
	cb1:Resolve("shared")
	T(execution_count)["=="](2)
end)

T.Test("callback.WrapKeyedTask max concurrent limit", function()
	local active_count = 0
	local max_active = 0
	local started = {}
	local task = callback.WrapKeyedTask(
		function(self, key)
			active_count = active_count + 1
			table.insert(started, key)

			if active_count > max_active then max_active = active_count end
		-- Don't auto-resolve
		end,
		2
	) -- Max 2 concurrent
	local cb1 = task("key1")
	local cb2 = task("key2")
	local cb3 = task("key3")

	cb1:Then(function() end)

	cb2:Then(function() end)

	cb3:Then(function() end)

	-- Only first 2 should start
	T(#started)["=="](2)
	T(max_active)["=="](2)
	-- Complete first task
	cb1:Resolve()
	active_count = active_count - 1
	-- Third should now start
	T.Sleep(0.01)
	T(#started)["=="](3)
end)

T.Test("callback.WrapKeyedTask queue callback notification", function()
	local queue_events = {}
	local task = callback.WrapKeyedTask(function(self, key) -- Don't resolve
	end, 1, function(what, cb, key, queue)
		table.insert(queue_events, {what = what, key = key, queue_size = #queue})
	end)
	local cb1 = task("key1")
	local cb2 = task("key2")

	cb1:Then(function() end)

	cb2:Then(function() end)

	-- Should have one push event for key2
	T(#queue_events)["=="](1)
	T(queue_events[1].what)["=="]("push")
	T(queue_events[1].key)["=="]("key2")
	-- Complete first, should trigger pop
	cb1:Resolve()
	T.Sleep(0.01)
	T(#queue_events)["=="](2)
	T(queue_events[2].what)["=="]("pop")
	T(queue_events[2].key)["=="]("key2")
end)

T.Test("callback.WrapKeyedTask start_on_callback delayed start", function()
	local started = false
	local task = callback.WrapKeyedTask(
		function(self, key)
			started = true
			self.callbacks.resolve()
		end,
		nil,
		nil,
		true
	) -- start_on_callback = true
	local cb = task("key1")
	-- Should not start immediately
	T(started)["=="](false)

	-- Should start when Then is called
	cb:Then(function() end)

	T(started)["=="](true)
end)

T.Test("callback.Resolve creates auto-resolving callback", function()
	local resolved = false
	local value = nil
	local cb = callback.Resolve("test_value")

	cb:Then(function(val)
		resolved = true
		value = val
	end)

	-- Should not resolve immediately
	T(resolved)["=="](false)
	-- Should resolve after timer delay
	T.Sleep(0.02)
	T(resolved)["=="](true)
	T(value)["=="]("test_value")
end)

T.Test("callback reject in then handler", function()
	local error_caught = false
	local error_msg = nil
	local cb = callback.Create()

	cb:Then(function(value)
		error("intentional error in then")
	end):Catch(function(err)
		error_caught = true
		error_msg = err
	end)

	cb:Resolve("test")
	T(error_caught)["=="](true)
	T(error_msg ~= nil)["=="](true)
end)

T.Test("callback stop callback", function()
	local stopped = false
	local started = false
	local cb = callback.Create(function(self)
		started = true
		self.on_stop = function()
			stopped = true
		end
	end)
	cb:Start()
	T(started)["=="](true)
	T(stopped)["=="](false)
	cb:Stop()
	T(stopped)["=="](true)
end)

T.Test("callback child callbacks inherit parent reject", function()
	local child_rejected = false
	local parent = callback.Create()
	local child = parent:Then(function() end)

	child:Catch(function(err)
		child_rejected = true
	end)

	parent:Reject("parent_error")
	T(child_rejected)["=="](true)
end)

T.Test("callback multiple arguments in resolve", function()
	local arg1, arg2, arg3 = nil, nil, nil
	local cb = callback.Create()

	cb:Then(function(a, b, c)
		arg1, arg2, arg3 = a, b, c
	end)

	cb:Resolve("first", "second", "third")
	T(arg1)["=="]("first")
	T(arg2)["=="]("second")
	T(arg3)["=="]("third")
end)

T.Test("callback Get waits for resolution", function()
	local cb = callback.Create(function(self)
		timer.Delay(0.05, function()
			self.callbacks.resolve("delayed_value")
		end)
	end)
	cb:Start()
	-- This should block until resolved
	local result = cb:Get()
	T(result)["=="]("delayed_value")
end)

T.Test("callback Get throws on reject", function()
	local cb = callback.Create(function(self)
		timer.Delay(0.05, function()
			self.callbacks.reject("error_value")
		end)
	end)
	cb:Start()
	local ok, err = pcall(function()
		cb:Get()
	end)
	T(ok)["=="](false)
	T(err ~= nil)["=="](true)
end)

T.Test("callback TryGet returns ok and value", function()
	local cb = callback.Create(function(self)
		timer.Delay(0.05, function()
			self.callbacks.resolve("delayed_value")
		end)
	end)
	cb:Start()
	local ok, result = cb:TryGet()
	T(ok)["=="](true)
	T(result)["=="]("delayed_value")
end)

T.Test("callback TryGet returns false and error on reject", function()
	local cb = callback.Create(function(self)
		timer.Delay(0.05, function()
			self.callbacks.reject("error_value")
		end)
	end)
	cb:Start()
	local ok, err = cb:TryGet()
	T(ok)["=="](false)
	T(type(err))["=="]("string")
	T(#err > 0)["=="](true)
end)

T.Test("callback TryGet returns false on nil reject", function()
	local cb = callback.Create(function(self)
		timer.Delay(0.05, function()
			self.callbacks.reject()
		end)
	end)
	cb:Start()
	local ok, err = cb:TryGet()
	T(ok)["=="](false)
	T(type(err))["=="]("string")
	T(err:find("nil", 1, true) ~= nil)["=="](true)
end)

T.Test("callback parent subscribe propagates to children", function()
	local events = {}
	local parent = callback.Create()
	local child1 = parent:Then(function() end)
	local child2 = child1:Then(function() end)

	-- Subscribe on child should affect parent
	child2:Subscribe("custom", function(value)
		table.insert(events, value)
	end)

	parent.callbacks.custom("event1")
	parent.callbacks.custom("event2")
	T(#events)["=="](2)
	T(events[1])["=="]("event1")
	T(events[2])["=="]("event2")
end)

T.Test("callback integration with timer", function()
	local Delay = callback.WrapTask(function(self, delay)
		local resolve = self.callbacks.resolve

		timer.Delay(delay, function()
			resolve("delayed_result")
		end)
	end)
	local result = nil

	Delay(0.1):Then(function(value)
		result = value
	end)

	T(result)["=="](nil)
	T.Sleep(0.15)
	T(result)["=="]("delayed_result")
end)

T.Test("callback reject from custom event returning false", function()
	local rejected = false
	local reject_msg = nil
	local cb = callback.Create()

	cb:Subscribe("custom", function(value)
		return false, "custom_error"
	end)

	cb:Catch(function(err)
		rejected = true
		reject_msg = err
	end)

	cb.callbacks.custom("test")
	T(rejected)["=="](true)
	T(reject_msg)["=="]("custom_error")
end)

T.Test("callback.Subscribe on root", function()
	local cb = callback.Create()
	local chunks = {}

	cb:Subscribe("chunk", function(data)
		table.insert(chunks, data)
	end)

	cb:Trigger("chunk", "a")
	cb:Trigger("chunk", "b")
	T(#chunks)["=="](2)
	T(chunks[1])["=="]("a")
	T(chunks[2])["=="]("b")
end)

T.Test("callback.Subscribe on child", function()
	local root = callback.Create()
	local child = root:Then(function(val)
		return val
	end)
	local chunks = {}

	child:Subscribe("chunk", function(data)
		table.insert(chunks, data)
	end)

	root:Trigger("chunk", "hello")
	T(#chunks)["=="](1)
	T(chunks[1])["=="]("hello")
end)

T.Test("callback.Subscribe on deep child", function()
	local root = callback.Create()
	local child1 = root:Then(function(val)
		return val
	end)
	local child2 = child1:Then(function(val)
		return val
	end)
	local chunks = {}

	child2:Subscribe("chunk", function(data)
		table.insert(chunks, data)
	end)

	root:Trigger("chunk", "deep")
	T(#chunks)["=="](1)
	T(chunks[1])["=="]("deep")
end)

T.Test("callback.Trigger on root should trigger child subscribers logic check", function()
	local root = callback.Create()
	local child = root:Then(function(val)
		return val
	end)
	local results = {}

	-- In our new model, Subscribe always goes to root.
	-- Trigger always goes to root.
	child:Subscribe("chunk", function(c)
		table.insert(results, c)
	end)

	root:Trigger("chunk", "1")
	T(#results)["=="](1)
	T(results[1])["=="]("1")
end)

T.Test("callback.Subscribe before trigger should catch all chunks", function()
	local root = callback.Create()
	local results = {}
	local child = root:Then(function(val)
		return val
	end)

	-- In the real world, POST() triggers chunks
	-- But the user calls :Subscribe() ON the child/parent.
	child:Subscribe("chunk", function(c)
		table.insert(results, c)
	end)

	root:Trigger("chunk", "1")
	root:Trigger("chunk", "2")
	T(#results)["=="](2)
	T(results[1])["=="]("1")
	T(results[2])["=="]("2")
end)

T.Test("callback.WrapKeyedTask trigger propagation", function()
	local results = {}
	local root_cb
	local wrapper = callback.WrapKeyedTask(function(self, key)
		root_cb = self
	end)
	local child = wrapper("mykey")

	child:Subscribe("chunk", function(c)
		table.insert(results, c)
	end)

	-- In WrapKeyedTask, the real work doesn't start until Get() is called
	-- (due to the tasks logic at the bottom of add)
	-- BUT in this test environment, tasks are disabled or we are at root.
	-- Let's force start.
	child:Start()
	T(root_cb ~= nil)["=="](true)
	T(root_cb)["=="](child)
	root_cb:Trigger("chunk", "test")
	T(#results)["=="](1)
	T(results[1])["=="]("test")
end)

T.Test("callback.WrapKeyedTask normal sharing without suffix", function()
	local task_count = 0
	local wrapper = callback.WrapKeyedTask(function(self, key)
		task_count = task_count + 1
	end)
	local c1 = wrapper("bar")
	local c2 = wrapper("bar")
	T(c1)["=="](c2)
	T(task_count)["=="](1)
end)
