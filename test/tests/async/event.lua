-- Comprehensive test suite for goluwa/event.lua
-- Some tests are designed to fail to highlight strange behaviors/bugs.
local T = require("test.environment")
local event = require("event")

T.Test("Basic Event Call", function()
	local called = 0

	event.AddListener("Test_Basic", "id1", function()
		called = called + 1
	end)

	event.Call("Test_Basic")
	T(called)["=="](1)
	event.RemoveListener("Test_Basic", "id1")
end)

T.Test("Multiple Listeners & Priority", function()
	local order = {}

	event.AddListener(
		"Test_Priority",
		"low",
		function()
			table.insert(order, "low")
		end,
		{priority = 1}
	)

	event.AddListener(
		"Test_Priority",
		"high",
		function()
			table.insert(order, "high")
		end,
		{priority = 10}
	)

	event.Call("Test_Priority")
	T(#order)["=="](2)
	T(order[1])["=="]("high")
	T(order[2])["=="]("low")
	event.RemoveListener("Test_Priority", "low")
	event.RemoveListener("Test_Priority", "high")
end)

T.Test("Arguments and Return Values", function()
	event.AddListener("Test_Args", "id1", function(a, b)
		return a + b
	end)

	local result = event.Call("Test_Args", 10, 20)
	T(result)["=="](30)
	event.RemoveListener("Test_Args", "id1")
end)

T.Test("remove_after_one_call", function()
	local called = 0

	event.AddListener(
		"Test_Once",
		"id1",
		function()
			called = called + 1
		end,
		{remove_after_one_call = true}
	)

	event.Call("Test_Once")
	event.Call("Test_Once")
	T(called)["=="](1)
	T(event.IsListenerActive("Test_Once", "id1"))["=="](false)
end)

T.Test("event.destroy_tag", function()
	local called = 0

	event.AddListener("Test_Destroy", "id1", function()
		called = called + 1
		return event.destroy_tag
	end)

	event.Call("Test_Destroy")
	event.Call("Test_Destroy")
	T(called)["=="](1)
	T(event.IsListenerActive("Test_Destroy", "id1"))["=="](false)
end)

T.Test("self_arg validity", function()
	local obj = {
		valid = true,
		IsValid = function(self)
			return self.valid
		end,
	}
	local called = 0

	event.AddListener(
		"Test_Self",
		"id1",
		function(self)
			called = called + 1
			T(self)["=="](obj)
		end,
		{self_arg = obj}
	)

	event.Call("Test_Self")
	T(called)["=="](1)
	obj.valid = false
	event.Call("Test_Self")
	T(called)["=="](1) -- should not have incremented
	T(event.IsListenerActive("Test_Self", "id1"))["=="](false)
end)

T.Test("EventAdded and EventRemoved basic", function()
	local added = false
	local removed = false

	event.AddListener("EventAdded", "detect_add", function(config)
		if config.event_type == "Test_Detection" then added = true end
	end)

	event.AddListener("EventRemoved", "detect_remove", function(tbl)
		removed = true
	end)

	event.AddListener("Test_Detection", "id1", function() end)

	T(added)["=="](true)
	event.RemoveListener("Test_Detection", "id1")
	T(removed)["=="](true)
	event.RemoveListener("EventAdded", "detect_add")
	event.RemoveListener("EventRemoved", "detect_remove")
end)

-- Strange Behavior / Bugs found below:
T.Test("CreateRealm", function()
	local realm = event.CreateRealm("my_realm")
	local called = 0
	realm.MyEvent = function()
		called = called + 1
	end
	event.Call("MyEvent")
	T(called)["=="](1)
	realm.MyEvent = nil
	event.Call("MyEvent")
	-- Fails because RemoveListener has a bug with table arguments
	T(called)["=="](1)
end)

T.Test("Nested event call removing listener from parent event stops parent chain", function()
	local called1 = false
	local called2 = false
	local called3 = false

	event.AddListener(
		"Parent",
		"L1",
		function()
			called1 = true
			event.Call("Child")
		end,
		{priority = 10}
	)

	event.AddListener("Parent", "L2", function()
		called2 = true
	end, {priority = 5})

	event.AddListener("Parent", "L3", function()
		called3 = true
	end, {priority = 1})

	event.AddListener("Child", "CL1", function()
		event.RemoveListener("Parent", "L2")
	end)

	event.Call("Parent")
	T(called1)["=="](true)
	T(called2)["=="](false) -- L2 correctly removed and not called
	-- Fails because holes in the table stop the event loop
	T(called3)["=="](true)
	event.RemoveListener("Parent", "L1")
	event.RemoveListener("Parent", "L3")
	event.RemoveListener("Child", "CL1")
end)

T.Test("remove_after_one_call with return value", function()
	event.AddListener(
		"Test_OnceReturn",
		"id1",
		function()
			return "val"
		end,
		{remove_after_one_call = true}
	)

	local res = event.Call("Test_OnceReturn")
	-- Fails because Call returns nil when a listener is removed
	T(res)["=="]("val")
end)

T.Test("EventRemoved receives the listener being removed", function()
	local removed_listener = nil

	event.AddListener("EventRemoved", "check", function(config)
		if config.id == "to_be_removed" then removed_listener = config end
	end)

	event.AddListener("Test_RemovedContained", "to_be_removed", function() end)

	event.RemoveListener("Test_RemovedContained", "to_be_removed")
	T(removed_listener ~= nil)["=="](true)
	T(removed_listener.id)["=="]("to_be_removed")
	event.RemoveListener("EventRemoved", "check")
end)
