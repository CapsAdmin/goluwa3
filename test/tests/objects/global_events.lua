local T = import("test/environment.lua")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")

T.Test("AddGlobalEvent dispatches to registered object methods", function()
	local META = objects.CreateTemplate("test_global_event_basic")
	META:GetSet("Val", 0)
	META:Register()
	local obj = objects.CreateObject(META)
	local calls = {}

	obj:AddGlobalEvent("Test_GlobalDispatch", {func_name = "OnTestGlobalDispatch"})

	function obj:OnTestGlobalDispatch(a, b)
		calls[#calls + 1] = {self = self, a = a, b = b}
	end

	event.Call("Test_GlobalDispatch", "hello", 42)
	T(#calls)["=="](1)
	T(calls[1].self)["=="](obj)
	T(calls[1].a)["=="]("hello")
	T(calls[1].b)["=="](42)
	obj:RemoveEvent("Test_GlobalDispatch")
end)

T.Test("AddGlobalEvent propagates return values through event.Call", function()
	local META = objects.CreateTemplate("test_global_event_return")
	META:GetSet("Val", 0)
	META:Register()
	local obj = objects.CreateObject(META)

	obj:AddGlobalEvent("Test_GlobalReturn", {func_name = "OnTestGlobalReturn"})

	function obj:OnTestGlobalReturn(a, b)
		if a == "double" then return b * 2 end

		return nil
	end

	local result = event.Call("Test_GlobalReturn", "double", 21)
	T(result)["=="](42)
	obj:RemoveEvent("Test_GlobalReturn")
end)

T.Test("AddGlobalEvent no self-recursion from config.callback", function()
	-- Regression test: config.callback was being set by AddListener to the
	-- anonymous wrapper, causing func = config.callback to point back at
	-- itself and recurse infinitely.
	local META = objects.CreateTemplate("test_global_event_no_recurse")
	META:GetSet("Val", 0)
	META:Register()
	local obj = objects.CreateObject(META)
	local call_count = 0

	obj:AddGlobalEvent("Test_NoRecurse", {func_name = "OnTestNoRecurse"})

	function obj:OnTestNoRecurse(x)
		call_count = call_count + 1

		if call_count > 100 then error("infinite recursion detected!", 0) end
	end

	-- This would stack overflow before the fix
	event.Call("Test_NoRecurse", "ping")
	T(call_count)["=="](1)
	obj:RemoveEvent("Test_NoRecurse")
end)

T.Test("AddGlobalEvent multiple objects all receive the event", function()
	local META = objects.CreateTemplate("test_global_event_multi")
	META:GetSet("Val", 0)
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	local obj3 = objects.CreateObject(META)
	local order = {}

	obj1:AddGlobalEvent("Test_Multi", {func_name = "OnTestMulti"})
	obj2:AddGlobalEvent("Test_Multi", {func_name = "OnTestMulti"})
	obj3:AddGlobalEvent("Test_Multi", {func_name = "OnTestMulti"})

	function obj1:OnTestMulti(name)
		order[#order + 1] = "obj1:" .. name
	end

	function obj2:OnTestMulti(name)
		order[#order + 1] = "obj2:" .. name
	end

	function obj3:OnTestMulti(name)
		order[#order + 1] = "obj3:" .. name
	end

	event.Call("Test_Multi", "tick")
	T(#order)["=="](3)
	T(order[1])["=="]("obj1:tick")
	T(order[2])["=="]("obj2:tick")
	T(order[3])["=="]("obj3:tick")

	obj1:RemoveEvent("Test_Multi")
	obj2:RemoveEvent("Test_Multi")
	obj3:RemoveEvent("Test_Multi")
end)

T.Test("AddGlobalEvent last handler return value wins", function()
	-- Matches event.Call behavior: the last listener's return values are used.
	local META = objects.CreateTemplate("test_global_event_last_wins")
	META:GetSet("Val", 0)
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)

	obj1:AddGlobalEvent("Test_LastWins", {func_name = "OnTestLastWins"})
	obj2:AddGlobalEvent("Test_LastWins", {func_name = "OnTestLastWins"})

	function obj1:OnTestLastWins(x)
		return "first"
	end

	function obj2:OnTestLastWins(x)
		return "second"
	end

	local result = event.Call("Test_LastWins", "x")
	T(result)["=="]("second")

	obj1:RemoveEvent("Test_LastWins")
	obj2:RemoveEvent("Test_LastWins")
end)

T.Test("AddGlobalEvent RemoveEvent stops dispatch", function()
	local META = objects.CreateTemplate("test_global_event_remove")
	META:GetSet("Val", 0)
	META:Register()
	local obj = objects.CreateObject(META)
	local call_count = 0

	obj:AddGlobalEvent("Test_Remove", {func_name = "OnTestRemove"})

	function obj:OnTestRemove()
		call_count = call_count + 1
	end

	event.Call("Test_Remove")
	T(call_count)["=="](1)
	obj:RemoveEvent("Test_Remove")
	event.Call("Test_Remove")
	T(call_count)["=="](1) -- Should NOT have incremented
end)

T.Test("AddGlobalEvent skipping nil handler methods", function()
	-- If a registered object doesn't have the expected method, it should be
	-- logged and removed, but not crash.
	local META = objects.CreateTemplate("test_global_event_nil_handler")
	META:GetSet("Val", 0)
	META:Register()
	local obj = objects.CreateObject(META)
	local call_count = 0

	obj:AddGlobalEvent("Test_NilHandler", {func_name = "OnTestNilHandler"})

	-- Intentionally NOT defining OnTestNilHandler

	event.AddListener("Test_NilHandler", "other", function()
		call_count = call_count + 1
	end)

	-- Should not error, just log and remove the broken handler
	event.Call("Test_NilHandler")
	T(call_count)["=="](1) -- The other listener still works
	T(event.IsListenerActive("Test_NilHandler", "objects_events:Test_NilHandler"))["=="](false)
	event.RemoveListener("Test_NilHandler", "other")
end)

T.Test("AddGlobalEvent return values propagate through entity-like property flow", function()
	-- Integration-style test: simulates how entities/base.lua uses
	-- event.Call("OnEntitySetProperty", ...) and relies on the return value.
	local META = objects.CreateTemplate("test_global_event_property_flow")
	META:GetSet("Val", 0)
	META:Register()
	local theme_obj = objects.CreateObject(META)

	theme_obj:AddGlobalEvent("OnEntitySetProperty", {func_name = "OnEntitySetProperty"})

	function theme_obj:OnEntitySetProperty(entity, key, val)
		if key == "Padding" and type(val) == "string" then
			return {x = 10, y = 10, w = 10, h = 10}
		end

		return nil
	end

	local entity = {Type = "layout"}
	local new_val = event.Call("OnEntitySetProperty", entity, "Padding", "S")
	T(new_val ~= nil)["=="](true)
	T(new_val.x)["=="](10)
	T(new_val.y)["=="](10)
	T(new_val.w)["=="](10)
	T(new_val.h)["=="](10)

	local no_convert = event.Call("OnEntitySetProperty", entity, "Color", "red")
	T(no_convert)["=="](nil)

	theme_obj:RemoveEvent("OnEntitySetProperty")
end)
