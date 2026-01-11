local T = require("test.environment")
local ecs = require("ecs")
local prototype = require("prototype")

T.Test("ecs core basic", function()
	ecs.ClearWorld()
	local world = ecs.GetWorld()
	-- Test component registration
	local test_component = prototype.CreateTemplate("component", "test_component")
	test_component.ComponentName = "test_component"
	test_component.Foo = 1
	test_component:Register()
	ecs.RegisterComponent(test_component)
	T(ecs.GetComponent("test_component"))["=="](test_component)
	-- Test AddComponent
	local ent = ecs.CreateEntity("test")
	local c = ent:AddComponent("test_component")
	T(c)["~="](nil)
	T(ent.test_component)["=="](c)
	T(ent:HasComponent("test_component"))["=="](true)
	T(ent:GetComponent("test_component"))["=="](c)
	-- Test RemoveComponent
	ent:RemoveComponent("test_component")
	T(ent.test_component)["=="](nil)
	T(ent:HasComponent("test_component"))["=="](false)
	T(ent:GetComponent("test_component"))["=="](nil)
	ent:Remove()
end)

T.Test("ecs OnRemove component", function()
	ecs.ClearWorld()
	local on_remove_called = false
	local META = prototype.CreateTemplate("component", "test_on_remove")
	META.ComponentName = "test_on_remove"

	function META:OnRemove()
		on_remove_called = true
	end

	META:Register()
	ecs.RegisterComponent(META)
	local ent = ecs.CreateEntity("test")
	ent:AddComponent("test_on_remove")
	ent:RemoveComponent("test_on_remove")
	T(on_remove_called)["=="](true)
	on_remove_called = false
	ent:AddComponent("test_on_remove")
	ent:Remove()
	T(on_remove_called)["=="](true)
end)

T.Test("ecs GetComponents", function()
	ecs.ClearWorld()
	local META = prototype.CreateTemplate("component", "c1")
	META.ComponentName = "c1"
	META:Register()
	ecs.RegisterComponent(META)
	local e1 = ecs.CreateEntity("e1")
	local e2 = ecs.CreateEntity("e2")
	local e3 = ecs.CreateEntity("e3")
	local c1 = e1:AddComponent("c1")
	local c2 = e2:AddComponent("c1")
	local components = ecs.GetComponents("c1")
	T(#components)["=="](2)
	T(components[1])["=="](c1)
	T(components[2])["=="](c2)
	e1:Remove()
	components = ecs.GetComponents("c1")
	T(#components)["=="](1)
	T(components[1])["=="](c2)
	e2:Remove()
	components = ecs.GetComponents("c1")
	T(#components)["=="](0)
end)

T.Test("ecs entity removal during loop", function()
	ecs.ClearWorld()
	local world = ecs.GetWorld()

	for i = 1, 10 do
		ecs.CreateEntity("e" .. i)
	end

	local children = world:GetChildren()
	T(#children)["=="](10)

	-- Test removing while looping
	-- Note: ecs.lua doesn't seem to have a specific loop helper that handles removal safely,
	-- so we test standard Lua table behavior if that's what's used, or if ecs provides one.
	-- ENTITY:OnRemove() does local children = self:GetChildren() and loops backwards.
	for i = #children, 1, -1 do
		children[i]:Remove()
	end

	T(#world:GetChildren())["=="](0)
end)

T.Test("ecs component removal during loop", function()
	ecs.ClearWorld()
	local META = prototype.CreateTemplate("component", "loop_test")
	META.ComponentName = "loop_test"
	META:Register()
	ecs.RegisterComponent(META)

	for i = 1, 5 do
		local ent = ecs.CreateEntity("e" .. i)
		ent:AddComponent("loop_test")
	end

	local components = ecs.GetComponents("loop_test")
	T(#components)["=="](5)

	-- ecs.GetComponents returns a reference to the internal list (or a copy?)
	-- In goluwa/ecs.lua:
	-- function ecs.GetComponents(component_name)
	-- 	return ecs.component_instances[component_name] or {}
	-- end
	-- It returns the table itself.
	-- Removing components should update the list
	for i = #components, 1, -1 do
		components[i].Entity:RemoveComponent("loop_test")
	end

	T(#components)["=="](0)
end)

T.Test("ecs internal component removal via RemoveCommand", function()
	ecs.ClearWorld()
	local META = prototype.CreateTemplate("component", "rem_test")
	META.ComponentName = "rem_test"
	META:Register()
	ecs.RegisterComponent(META)
	local ent = ecs.CreateEntity()
	local comp = ent:AddComponent("rem_test")
	T(#ecs.GetComponents("rem_test"))["=="](1)

	-- Test if remove_component works (it is registered via CallOnRemove)
	-- CallOnRemove is usually from prototype or utility.
	-- In ecs.lua: component:CallOnRemove(remove_component)
	-- usually this is called when the object is 'removed' via component:Remove()
	if comp.Remove then
		comp:Remove()
		T(ent:HasComponent("rem_test"))["=="](false)
		T(#ecs.GetComponents("rem_test"))["=="](0)
	end
end)

T.Test("ecs AddComponent requirements", function()
	ecs.ClearWorld()
	local meta_req = prototype.CreateTemplate("component", "with_req")
	meta_req.ComponentName = "with_req"
	meta_req.Require = {"req1", "req2"}
	meta_req:Register()
	ecs.RegisterComponent(meta_req)
	local meta_req1 = prototype.CreateTemplate("component", "req1")
	meta_req1.ComponentName = "req1"
	meta_req1:Register()
	ecs.RegisterComponent(meta_req1)
	local meta_req2 = prototype.CreateTemplate("component", "req2")
	meta_req2.ComponentName = "req2"
	meta_req2:Register()
	ecs.RegisterComponent(meta_req2)
	local ent = ecs.CreateEntity()
	ent:AddComponent("with_req")
	T(ent:HasComponent("with_req"))["=="](true)
	T(ent:HasComponent("req1"))["=="](true)
	T(ent:HasComponent("req2"))["=="](true)
end)

T.Test("ecs OnEntityAddComponent", function()
	ecs.ClearWorld()
	local added_component = nil
	local meta_listener = prototype.CreateTemplate("component", "listener")
	meta_listener.ComponentName = "listener"

	function meta_listener:OnEntityAddComponent(comp)
		added_component = comp
	end

	meta_listener:Register()
	ecs.RegisterComponent(meta_listener)
	local meta_other = prototype.CreateTemplate("component", "other")
	meta_other.ComponentName = "other"
	meta_other:Register()
	ecs.RegisterComponent(meta_other)
	local ent = ecs.CreateEntity()
	local listener = ent:AddComponent("listener")
	local other = ent:AddComponent("other")
	T(added_component)["=="](other)
end)
