local T = import("test/environment.lua")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")

T.Test("objects basic registration and creation", function()
	local META = objects.CreateTemplate("test_type")

	function META:Foo()
		return "bar"
	end

	META:Register()
	local obj = objects.CreateObject(META)
	T(obj.Type)["=="]("test_type")
	T(obj:Foo())["=="]("bar")
	T(obj:IsValid())["=="](true)
	obj:Remove()
	T(obj:IsValid())["=="](false)
end)

T.Test("objects .Instances feature", function()
	local META = objects.CreateTemplate("instance_test")
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	T(obj1.Instances)["=="](obj2.Instances)
	T(#obj1.Instances)["=="](2)
	T(obj1.Instances[1])["=="](obj1)
	T(obj1.Instances[2])["=="](obj2)
	-- Instances is on the prepared metatable, not the original template
	local prepared = objects.GetRegistered(META.Type)
	T(obj1.Instances)["=="](prepared.Instances)
	obj1:Remove()
	event.Call("Update") -- prototype_remove_objects is called on Update
	T(#obj2.Instances)["=="](1)
	T(obj2.Instances[1])["=="](obj2)
end)

T.Test("objects .Instances update immediately on remove", function()
	local META = objects.CreateTemplate("instance_immediate_remove_test")
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	obj1:Remove()
	T(#obj2.Instances)["=="](1)
	T(obj2.Instances[1])["=="](obj2)
	T(obj2.Instances[2])["=="](nil)
	event.Call("Update")
	T(#obj2.Instances)["=="](1)
	obj2:Remove()
	event.Call("Update")
end)

T.Test("objects properties GetSet", function()
	local META = objects.CreateTemplate("test_props")
	META:GetSet("Value", 123)
	META:Register()
	local obj = objects.CreateObject(META)
	T(obj:GetValue())["=="](123)
	obj:SetValue(456)
	T(obj:GetValue())["=="](456)
	T(obj.Value)["=="](456)
end)

T.Test("objects properties IsSet", function()
	local META = objects.CreateTemplate("test_is")
	META:IsSet("Cool", false)
	META:Register()
	local obj = objects.CreateObject(META)
	T(obj:IsCool())["=="](false)
	obj:SetCool(true)
	T(obj:IsCool())["=="](true)
end)

T.Test("objects inheritance Base", function()
	local BASE = objects.CreateTemplate("base")

	function BASE:Identify()
		return "base"
	end

	BASE:Register()
	local SUB = objects.CreateTemplate("sub")
	SUB.Base = BASE

	function SUB:Identify()
		return "sub"
	end

	function SUB:BaseIdentify()
		return self.BaseClass.Identify(self)
	end

	SUB:Register()
	local obj = objects.CreateObject(SUB)
	T(obj:Identify())["=="]("sub")
	T(obj:BaseIdentify())["=="]("base")
end)

T.Test("objects Base", function()
	local BASE = objects.CreateTemplate("base_test")

	function BASE:Hello()
		return "world"
	end

	BASE:Register()
	local SUB = objects.CreateTemplate("sub_test")
	SUB.Base = BASE
	SUB:Register()
	local obj = objects.CreateObject(SUB)
	T(obj:Hello())["=="]("world")
end)

T.Test("objects inheritance Base", function()
	local BASE = objects.CreateTemplate("base_identify")

	function BASE:Identify()
		return "base"
	end

	BASE:Register()
	local SUB = objects.CreateTemplate("sub_identify")
	SUB.Base = BASE

	function SUB:Identify()
		return "sub"
	end

	function SUB:BaseIdentify()
		return self.BaseClass.Identify(self)
	end

	SUB:Register()
	local obj = objects.CreateObject(SUB)
	T(obj:Identify())["=="]("sub")
	T(obj:BaseIdentify())["=="]("base")
end)

T.Test("objects registered lookup by table key", function()
	local BASE = objects.CreateTemplate("reg_lookup_base")

	function BASE:Foo()
		return "bar"
	end

	BASE:Register()
	T(objects.registered["reg_lookup_base"])["=="](BASE)
end)

T.Test("objects registered lookup by Type string", function()
	local BASE = objects.CreateTemplate("reg_lookup_type")

	function BASE:Foo()
		return "bar"
	end

	BASE:Register()
	-- Looking up by .Type string should work
	T(objects.registered[BASE.Type])["=="](BASE)
end)

T.Test("objects registered has string keys", function()
	local T1 = objects.CreateTemplate("diag_t1")
	T1:Register()
	local T2 = objects.CreateTemplate("diag_t2")
	T2.Base = T1
	T2:Register()
	-- Check that registered keys are strings (type names)
	local key_types = {}

	for k, v in pairs(objects.registered) do
		key_types[type(k)] = true
	end

	T(key_types["string"])["=="](true)
	-- Check that looking up by table fails
	T(objects.registered[T1])["=="](nil)
	-- Check that looking up by .Type works
	T(objects.registered[T1.Type])["=="](T1)
end)

T.Test("objects Base inheritance chain", function()
	local GRAND = objects.CreateTemplate("grand_parent")

	function GRAND:GrandMethod()
		return "grand"
	end

	GRAND:Register()
	local PARENT = objects.CreateTemplate("parent_of_grand")
	PARENT.Base = GRAND

	function PARENT:ParentMethod()
		return "parent"
	end

	PARENT:Register()
	local CHILD = objects.CreateTemplate("child_of_parent")
	CHILD.Base = PARENT

	function CHILD:ChildMethod()
		return "child"
	end

	CHILD:Register()
	local obj = objects.CreateObject(CHILD)
	T(obj:ChildMethod())["=="]("child")
	T(obj:ParentMethod())["=="]("parent")
	T(obj:GrandMethod())["=="]("grand")
end)

T.Test("objects storable", function()
	local META = objects.CreateTemplate("storable_test")
	META:StartStorable()
	META:GetSet("A", 1)
	META:GetSet("B", "two")
	META:EndStorable()
	META:Register()
	local obj = objects.CreateObject(META)
	obj:SetA(10)
	obj:SetB("ten")
	local tbl = obj:GetStorableTable()
	T(tbl.A)["=="](10)
	T(tbl.B)["=="]("ten")
	local obj2 = objects.CreateObject(META)
	obj2:SetStorableTable(tbl)
	T(obj2:GetA())["=="](10)
	T(obj2:GetB())["=="]("ten")
end)

T.Test("objects parenting", function()
	local META = objects.CreateTemplate("parenting_test")
	objects.ParentingTemplate(META)
	META:Register()
	local parent = objects.CreateObject(META)
	parent:SetName("parent")
	local child = objects.CreateObject(META)
	child:SetName("child")
	child:SetParent(parent)
	T(child:GetParent())["=="](parent)
	T(parent:GetChildren()[1])["=="](child)
	T(child:HasParent())["=="](true)
	T(parent:HasChildren())["=="](true)
	child:UnParent()
	T(child:HasParent())["=="](false)
	T(parent:HasChildren())["=="](false)
end)

T.Test("objects GUID", function()
	local META = objects.CreateTemplate("guid_test")
	META:Register()
	local obj = objects.CreateObject(META)
	local guid = "my_unique_guid"
	obj:SetGUID(guid)
	T(obj:GetGUID())["=="](guid)
	T(objects.GetObjectByGUID(guid))["=="](obj)
end)

T.Test("objects parenting OnUnParent once", function()
	local META = objects.CreateTemplate("test_unparent")
	objects.ParentingTemplate(META)
	local unparent_count = 0

	function META:OnUnParent(parent)
		unparent_count = unparent_count + 1
	end

	META:Register()
	--	
	local parent = objects.CreateObject(META)
	parent:SetName("parent")
	parent:AddLocalListener("OnUnParent", parent.OnUnParent)
	--
	local child = objects.CreateObject(META)
	child:SetName("child")
	child:AddLocalListener("OnUnParent", child.OnUnParent)
	child:SetParent(parent)
	--
	unparent_count = 0
	child:UnParent()
	T(unparent_count)["=="](1)
end)

T.Test("objects UpdateObjects hot reload", function()
	local META = objects.CreateTemplate("update_test")

	function META:Foo()
		return "old"
	end

	META:Register()
	local obj = objects.CreateObject(META)
	T(obj:Foo())["=="]("old")
	-- Simulate reload
	local META2 = objects.CreateTemplate("update_test")

	function META2:Foo()
		return "new"
	end

	function META2:Bar()
		return "bar"
	end

	META2:Register()
	objects.UpdateObjects(META2)
	T(obj:Foo())["=="]("new")
	T(obj:Bar())["=="]("bar")
	-- Check if it shadowed (it should NOT ideally, but let's see what it does now)
	T(rawget(obj, "Foo"))["~="](nil)
end)

T.Test("objects GC callback", function()
	local gc_called = false
	local META = objects.CreateTemplate("gc_test")

	function META:Remove()
		gc_called = true
	end

	META:Register()

	do
		local obj = objects.CreateObject(META)
	end

	collectgarbage()
	collectgarbage()
	-- Note: This might not work if __gc is not supported on tables in LuaJIT without 5.2 compat
	T(gc_called)["=="](true)
end)

T.Pending("objects PropertyLink memory leak and removal", function()
	local META = objects.CreateTemplate("test")
	META:GetSet("Value", 0)
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	objects.AddPropertyLink(obj1, obj2, "Value", "Value")
	-- Check if it works (obj1 pulls from obj2)
	obj2:SetValue(123)
	event.Call("Update")
	T(obj1:GetValue())["=="](123)
	-- Test removal
	objects.RemovePropertyLinks(obj1)
	obj2:SetValue(456)
	event.Call("Update")
	T(obj1:GetValue())["~="](456)
end)

T.Test("objects DelegateProperties", function()
	local FROM = objects.CreateTemplate("from")
	FROM:StartStorable()
	FROM:GetSet("Value", 0)
	FROM:EndStorable()
	FROM:Register()
	local TO = objects.CreateTemplate("to")
	objects.DelegateProperties(TO, FROM, "SubObj")
	TO:Register()
	local to_obj = objects.CreateObject(TO)
	local from_obj = objects.CreateObject(FROM)
	to_obj.SubObj = from_obj
	to_obj:SetValue(789)
	T(from_obj:GetValue())["=="](789)
	T(to_obj:GetValue())["=="](789)
end)

T.Test("objects parenting cycle", function()
	local META = objects.CreateTemplate("test")
	objects.ParentingTemplate(META)
	META:Register()
	local a = objects.CreateObject(META)
	local b = objects.CreateObject(META)
	local c = objects.CreateObject(META)
	b:SetParent(a)
	c:SetParent(b)
	-- This should fail to prevent cycle A -> B -> C -> A
	T(a:SetParent(c))["=="](false)
end)

T.Test("objects OnFirstCreated", function()
	local first_created_called = false
	local META = objects.CreateTemplate("first_created_test")

	function META:OnFirstCreated()
		first_created_called = true
	end

	META:Register()
	T(first_created_called)["=="](false)
	local obj1 = objects.CreateObject(META)
	T(first_created_called)["=="](true)
	-- Reset flag
	first_created_called = false
	-- Second creation should NOT call OnFirstCreated
	local obj2 = objects.CreateObject(META)
	T(first_created_called)["=="](false)
	-- Clean up
	obj1:Remove()
	obj2:Remove()
	event.Call("Update")
end)

T.Test("objects OnLastRemoved", function()
	local last_removed_called = false
	local META = objects.CreateTemplate("last_removed_test")

	function META:OnLastRemoved()
		last_removed_called = true
	end

	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	T(last_removed_called)["=="](false)
	-- Remove first object, should NOT call OnLastRemoved yet
	obj1:Remove()
	event.Call("Update")
	T(last_removed_called)["=="](false)
	-- Remove second object, should call OnLastRemoved
	obj2:Remove()
	event.Call("Update")
	T(last_removed_called)["=="](true)
end)

T.Test("objects OnFirstCreated and OnLastRemoved cycle", function()
	local first_count = 0
	local last_count = 0
	local META = objects.CreateTemplate("lifecycle_test")

	function META:OnFirstCreated()
		first_count = first_count + 1
	end

	function META:OnLastRemoved()
		last_count = last_count + 1
	end

	META:Register()
	-- First cycle
	local obj1 = objects.CreateObject(META)
	T(first_count)["=="](1)
	T(last_count)["=="](0)
	obj1:Remove()
	event.Call("Update")
	T(first_count)["=="](1)
	T(last_count)["=="](1)
	-- Second cycle - OnFirstCreated should be called again
	local obj2 = objects.CreateObject(META)
	T(first_count)["=="](2)
	T(last_count)["=="](1)
	obj2:Remove()
	event.Call("Update")
	T(first_count)["=="](2)
	T(last_count)["=="](2)
end)

T.Test("objects .Instances sequential list", function()
	local META = objects.CreateTemplate("instances_sequential_test")
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	local obj3 = objects.CreateObject(META)
	-- Check initial state
	T(#obj1.Instances)["=="](3)
	T(obj1.Instances[1])["=="](obj1)
	T(obj1.Instances[2])["=="](obj2)
	T(obj1.Instances[3])["=="](obj3)
	-- Remove middle object
	obj2:Remove()
	event.Call("Update")
	-- Check that list remains sequential without holes
	T(#obj1.Instances)["=="](2)
	T(obj1.Instances[1])["=="](obj1)
	T(obj1.Instances[2])["=="](obj3)
	T(obj1.Instances[3])["=="](nil)
	-- Remove first object
	obj1:Remove()
	event.Call("Update")
	T(#obj3.Instances)["=="](1)
	T(obj3.Instances[1])["=="](obj3)
	T(obj3.Instances[2])["=="](nil)
	-- Remove last object
	obj3:Remove()
	event.Call("Update")
end)

T.Test("objects .Instances no holes after multiple removals", function()
	local META = objects.CreateTemplate("instances_no_holes_test")
	META:Register()
	local objs = {}

	-- Create 10 objects
	for i = 1, 10 do
		objs[i] = objects.CreateObject(META)
	end

	T(#objs[1].Instances)["=="](10)
	-- Remove objects 2, 4, 6, 8
	objs[2]:Remove()
	objs[4]:Remove()
	objs[6]:Remove()
	objs[8]:Remove()
	event.Call("Update")
	-- Should have 6 objects, no holes
	local instances = objs[1].Instances
	T(#instances)["=="](6)

	-- Verify all indices are valid and sequential
	for i = 1, #instances do
		T(instances[i])["~="](nil)
		T(instances[i]:IsValid())["=="](true)
	end

	-- Verify no holes beyond the length
	T(instances[7])["=="](nil)

	-- Clean up remaining
	for i = 1, 10 do
		if objs[i]:IsValid() then objs[i]:Remove() end
	end

	event.Call("Update")
end)

T.Test("objects .Instances integrity after mixed operations", function()
	local META = objects.CreateTemplate("instances_integrity_test")
	META:Register()
	local obj1 = objects.CreateObject(META)
	local obj2 = objects.CreateObject(META)
	T(#obj1.Instances)["=="](2)
	-- Remove first
	obj1:Remove()
	event.Call("Update")
	T(#obj2.Instances)["=="](1)
	T(obj2.Instances[1])["=="](obj2)
	-- Create new object
	local obj3 = objects.CreateObject(META)
	T(#obj2.Instances)["=="](2)
	T(obj2.Instances[1])["=="](obj2)
	T(obj2.Instances[2])["=="](obj3)
	-- Remove both
	obj2:Remove()
	obj3:Remove()
	event.Call("Update")
	-- Create again after all removed
	local obj4 = objects.CreateObject(META)
	T(#obj4.Instances)["=="](1)
	T(obj4.Instances[1])["=="](obj4)
	obj4:Remove()
	event.Call("Update")
end)

T.Test("objects local event system", function()
	local META = objects.CreateTemplate("local_event_test")
	META:Register()
	local obj = objects.CreateObject(META)
	local call_count = 0
	local last_args

	obj:AddLocalListener("OnSomething", function(self, a, b)
		call_count = call_count + 1
		last_args = {a, b}
	end)

	-- 1. Test basic call
	obj:CallLocalEvent("OnSomething", 1, 2)
	T(call_count)["=="](1)
	T(last_args[1])["=="](1)
	T(last_args[2])["=="](2)
	-- 2. Test that it's NOT triggerable via global event.Call with string
	event.Call("OnSomething", 3, 4)
	T(call_count)["=="](1)
	-- 3. Test multiple listeners
	local second_called = false

	obj:AddLocalListener("OnSomething", function()
		second_called = true
	end)

	obj:CallLocalEvent("OnSomething")
	T(call_count)["=="](2)
	T(second_called)["=="](true)
	-- 4. Test removal function
	call_count = 0
	local remove = obj:AddLocalListener("OnRemoveMe", function()
		call_count = call_count + 1
	end)
	obj:CallLocalEvent("OnRemoveMe")
	T(call_count)["=="](1)
	remove()
	obj:CallLocalEvent("OnRemoveMe")
	T(call_count)["=="](1) -- Should not have increased
	-- 5. Test use with unique event object
	local my_unique = event.UniqueEvent("my_unique")
	local unique_called = false

	obj:AddLocalListener(my_unique, function()
		unique_called = true
	end)

	obj:CallLocalEvent(my_unique)
	T(unique_called)["=="](true)
end)

T.Test("objects local event cleanup on remove", function()
	local META = objects.CreateTemplate("cleanup_test")
	META:Register()
	local obj = objects.CreateObject(META)
	local unique_event

	obj:AddLocalListener("OnDraw", function() end)

	unique_event = obj.local_events["OnDraw"]
	T(event.active[unique_event] and #event.active[unique_event])["=="](1)
	obj:Remove()
	-- Prototype cleanup happens on Update
	event.Call("Update")
	-- It should be cleaned up from the event system
	local count = 0

	if event.active[unique_event] then
		for _, v in pairs(event.active[unique_event]) do
			if v ~= nil then count = count + 1 end
		end
	end

	T(count)["=="](0)
end)

T.Test("objects global event cleanup on remove", function()
	local META = objects.CreateTemplate("global_cleanup_test")
	META:Register()
	local obj = objects.CreateObject(META)
	local called = false

	function obj:OnMyGlobalEvent()
		called = true
	end

	obj:AddGlobalEvent("MyGlobalEvent")
	T(event.active["MyGlobalEvent"] and #event.active["MyGlobalEvent"])["=="](1)
	obj:Remove()
	-- Prototype cleanup/removal calls RemoveEvent
	T(event.active["MyGlobalEvent"] == nil or #event.active["MyGlobalEvent"] == 0)["=="](true)
end)

T.Test("objects global event with custom name cleanup", function()
	local META = objects.CreateTemplate("global_custom_cleanup_test")
	META:Register()
	local obj = objects.CreateObject(META)

	function obj:OnTest() end

	obj:AddGlobalEvent("Test", {event_name = "RealEventName"})
	T(event.active["RealEventName"] and #event.active["RealEventName"])["=="](1)
	obj:Remove()
	-- This is where it's expected to fail if not fixed
	T(event.active["RealEventName"] == nil or #event.active["RealEventName"] == 0)["=="](true)
end)
