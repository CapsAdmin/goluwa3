local T = require("test.environment")
local prototype = require("prototype")
local event = require("event")

T.Test("prototype basic registration and creation", function()
	local META = prototype.CreateTemplate("test_type", "test_class")

	function META:Foo()
		return "bar"
	end

	META:Register()
	local obj = prototype.CreateObject(META)
	T(obj.Type)["=="]("test_type")
	T(obj.ClassName)["=="]("test_class")
	T(obj:Foo())["=="]("bar")
	T(obj:IsValid())["=="](true)
	obj:Remove()
	T(obj:IsValid())["=="](false)
end)

T.Test("prototype properties GetSet", function()
	local META = prototype.CreateTemplate("test_type", "test_props")
	META:GetSet("Value", 123)
	META:Register()
	local obj = prototype.CreateObject(META)
	T(obj:GetValue())["=="](123)
	obj:SetValue(456)
	T(obj:GetValue())["=="](456)
	T(obj.Value)["=="](456)
end)

T.Test("prototype properties IsSet", function()
	local META = prototype.CreateTemplate("test_type", "test_is")
	META:IsSet("Cool", false)
	META:Register()
	local obj = prototype.CreateObject(META)
	T(obj:IsCool())["=="](false)
	obj:SetCool(true)
	T(obj:IsCool())["=="](true)
end)

T.Test("prototype inheritance Base", function()
	local BASE = prototype.CreateTemplate("inherited", "base")

	function BASE:Identify()
		return "base"
	end

	BASE:Register()
	local SUB = prototype.CreateTemplate("inherited", "sub")
	SUB.Base = "base"

	function SUB:Identify()
		return "sub"
	end

	function SUB:BaseIdentify()
		return self.BaseClass.Identify(self)
	end

	SUB:Register()
	local obj = prototype.CreateObject(SUB)
	T(obj:Identify())["=="]("sub")
	T(obj:BaseIdentify())["=="]("base")
end)

T.Test("prototype TypeBase", function()
	local TYPE_BASE = prototype.CreateTemplate("type_base_test", "base")

	function TYPE_BASE:Hello()
		return "world"
	end

	TYPE_BASE:Register()
	local SUB = prototype.CreateTemplate("type_base_test", "sub")
	SUB.TypeBase = "base"
	SUB:Register()
	local obj = prototype.CreateObject(SUB)
	T(obj:Hello())["=="]("world")
end)

T.Test("prototype storable", function()
	local META = prototype.CreateTemplate("storable_test", "test")
	META:StartStorable()
	META:GetSet("A", 1)
	META:GetSet("B", "two")
	META:EndStorable()
	META:Register()
	local obj = prototype.CreateObject(META)
	obj:SetA(10)
	obj:SetB("ten")
	local tbl = obj:GetStorableTable()
	T(tbl.A)["=="](10)
	T(tbl.B)["=="]("ten")
	local obj2 = prototype.CreateObject(META)
	obj2:SetStorableTable(tbl)
	T(obj2:GetA())["=="](10)
	T(obj2:GetB())["=="]("ten")
end)

T.Test("prototype parenting", function()
	local META = prototype.CreateTemplate("parenting_test", "test")
	prototype.ParentingTemplate(META)
	META:Register()
	local parent = prototype.CreateObject(META)
	parent:SetName("parent")
	local child = prototype.CreateObject(META)
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

T.Test("prototype GUID", function()
	local META = prototype.CreateTemplate("guid_test", "test")
	META:Register()
	local obj = prototype.CreateObject(META)
	local guid = "my_unique_guid"
	obj:SetGUID(guid)
	T(obj:GetGUID())["=="](guid)
	T(prototype.GetObjectByGUID(guid))["=="](obj)
end)

T.Test("prototype parenting OnUnParent once", function()
	local META = prototype.CreateTemplate("parenting_test", "test_unparent")
	prototype.ParentingTemplate(META)
	local unparent_count = 0

	function META:OnUnParent(parent)
		unparent_count = unparent_count + 1
	end

	META:Register()
	local parent = prototype.CreateObject(META)
	local child = prototype.CreateObject(META)
	child:SetParent(parent)
	unparent_count = 0
	child:UnParent()
	T(unparent_count)["=="](1)
end)

T.Test("prototype UpdateObjects hot reload", function()
	local META = prototype.CreateTemplate("update_test", "test")

	function META:Foo()
		return "old"
	end

	META:Register()
	local obj = prototype.CreateObject(META)
	T(obj:Foo())["=="]("old")
	-- Simulate reload
	local META2 = prototype.CreateTemplate("update_test", "test")

	function META2:Foo()
		return "new"
	end

	function META2:Bar()
		return "bar"
	end

	META2:Register()
	prototype.UpdateObjects(META2)
	T(obj:Foo())["=="]("new")
	T(obj:Bar())["=="]("bar")
	-- Check if it shadowed (it should NOT ideally, but let's see what it does now)
	T(rawget(obj, "Foo"))["~="](nil)
end)

T.Test("prototype GC callback", function()
	local gc_called = false
	local META = prototype.CreateTemplate("gc_test", "test")

	function META:Remove()
		gc_called = true
	end

	META:Register()

	do
		local obj = prototype.CreateObject(META)
	end

	collectgarbage()
	collectgarbage()
	-- Note: This might not work if __gc is not supported on tables in LuaJIT without 5.2 compat
	T(gc_called)["=="](true)
end)

T.Test("prototype PropertyLink memory leak and removal", function()
	local META = prototype.CreateTemplate("link_test", "test")
	META:GetSet("Value", 0)
	META:Register()
	local obj1 = prototype.CreateObject(META)
	local obj2 = prototype.CreateObject(META)
	prototype.AddPropertyLink(obj1, obj2, "Value", "Value")
	-- Check if it works (obj1 pulls from obj2)
	obj2:SetValue(123)
	event.Call("Update")
	T(obj1:GetValue())["=="](123)
	-- Test removal
	prototype.RemovePropertyLinks(obj1)
	obj2:SetValue(456)
	event.Call("Update")
	T(obj1:GetValue())["~="](456)
end)

T.Test("prototype DelegateProperties", function()
	local FROM = prototype.CreateTemplate("delegate_test", "from")
	FROM:StartStorable()
	FROM:GetSet("Value", 0)
	FROM:EndStorable()
	FROM:Register()
	local TO = prototype.CreateTemplate("delegate_test", "to")
	prototype.DelegateProperties(TO, FROM, "SubObj")
	TO:Register()
	local to_obj = prototype.CreateObject(TO)
	local from_obj = prototype.CreateObject(FROM)
	to_obj.SubObj = from_obj
	to_obj:SetValue(789)
	T(from_obj:GetValue())["=="](789)
	T(to_obj:GetValue())["=="](789)
end)

T.Test("prototype parenting cycle", function()
	local META = prototype.CreateTemplate("cycle_test", "test")
	prototype.ParentingTemplate(META)
	META:Register()
	local a = prototype.CreateObject(META)
	local b = prototype.CreateObject(META)
	local c = prototype.CreateObject(META)
	b:SetParent(a)
	c:SetParent(b)
	-- This should fail to prevent cycle A -> B -> C -> A
	T(a:SetParent(c))["=="](false)
end)
