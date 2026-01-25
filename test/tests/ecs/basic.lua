local T = require("test.environment")
local ecs = require("ecs")
local prototype = require("prototype")

T.Test("ecs core basic", function()
	local world = ecs.Get3DWorld()
	-- Test component registration
	local test_component = prototype.CreateTemplate("test_component")
	test_component.ComponentName = "test_component"
	test_component.Foo = 1
	test_component:Register()
	ecs.RegisterComponent(test_component)
	-- Test AddComponent
	local ent = ecs.CreateEntity("test")
	local c = ent:AddComponent(test_component)
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
	local on_remove_called = false
	local META = prototype.CreateTemplate("test_on_remove")
	META.ComponentName = "test_on_remove"

	function META:OnRemove()
		on_remove_called = true
	end

	META:Register()
	ecs.RegisterComponent(META)
	local ent = ecs.CreateEntity("test")
	ent:AddComponent(META)
	ent:RemoveComponent("test_on_remove")
	T(on_remove_called)["=="](true)
	on_remove_called = false
	ent:AddComponent(META)
	ent:Remove()
	T(on_remove_called)["=="](true)
end)

T.Test("ecs GetComponents", function()
	local META = prototype.CreateTemplate("c1")
	META.ComponentName = "c1"
	META:Register()
	ecs.RegisterComponent(META)
	local e1 = ecs.CreateEntity("e1")
	local e2 = ecs.CreateEntity("e2")
	local e3 = ecs.CreateEntity("e3")
	local c1 = e1:AddComponent(META)
	local c2 = e2:AddComponent(META)
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
	local world = ecs.Get3DWorld()
	local count = #world:GetChildren()
	local added = {}

	for i = 1, 10 do
		added[i] = ecs.CreateEntity("e" .. i)
	end

	local children = world:GetChildren()
	T(#children)["=="](count + 10)

	-- Test removing while looping
	-- Note: ecs.lua doesn't seem to have a specific loop helper that handles removal safely,
	-- so we test standard Lua table behavior if that's what's used, or if ecs provides one.
	-- ENTITY:OnRemove() does local children = self:GetChildren() and loops backwards.
	for i = #added, 1, -1 do
		added[i]:Remove()
	end

	T(#world:GetChildren())["=="](count)
end)

T.Test("ecs component removal during loop", function()
	local META = prototype.CreateTemplate("loop_test")
	META.ComponentName = "loop_test"
	META:Register()
	ecs.RegisterComponent(META)

	for i = 1, 5 do
		local ent = ecs.CreateEntity("e" .. i)
		ent:AddComponent(META)
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
	local META = prototype.CreateTemplate("rem_test")
	META.ComponentName = "rem_test"
	META:Register()
	ecs.RegisterComponent(META)
	local ent = ecs.CreateEntity()
	local comp = ent:AddComponent(META)
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
	local meta_req1 = prototype.CreateTemplate("req1")
	meta_req1.ComponentName = "req1"
	meta_req1:Register()
	ecs.RegisterComponent(meta_req1)
	local meta_req2 = prototype.CreateTemplate("req2")
	meta_req2.ComponentName = "req2"
	meta_req2:Register()
	ecs.RegisterComponent(meta_req2)
	local meta_req = prototype.CreateTemplate("with_req")
	meta_req.ComponentName = "with_req"
	meta_req.Require = {meta_req1, meta_req2}
	meta_req:Register()
	ecs.RegisterComponent(meta_req)
	local ent = ecs.CreateEntity()
	ent:AddComponent(meta_req)
	T(ent:HasComponent("with_req"))["=="](true)
	T(ent:HasComponent("req1"))["=="](true)
	T(ent:HasComponent("req2"))["=="](true)
end)

T.Test("ecs OnEntityAddComponent", function()
	local added_component = nil
	local meta_listener = prototype.CreateTemplate("listener")
	meta_listener.ComponentName = "listener"

	function meta_listener:OnEntityAddComponent(comp)
		added_component = comp
	end

	meta_listener:Register()
	ecs.RegisterComponent(meta_listener)
	local meta_other = prototype.CreateTemplate("other")
	meta_other.ComponentName = "other"
	meta_other:Register()
	ecs.RegisterComponent(meta_other)
	local ent = ecs.CreateEntity()
	local listener = ent:AddComponent(meta_listener)
	local other = ent:AddComponent(meta_other)
	T(added_component)["=="](other)
end)

T.Test("remove children", function()
	local world = ecs.CreateEntity("fake_world")
	T(#world:GetChildren())["=="](0)
	local e1 = ecs.CreateEntity("e1", world)
	local e2 = ecs.CreateEntity("e2", world)
	local e3 = ecs.CreateEntity("e3", world)
	T(#world:GetChildren())["=="](3)
	world:Remove()
end)

T.Test("ecs entity recursive removal", function()
	local world = ecs.CreateEntity("fake_world")
	local parent = ecs.CreateEntity("parent", world)
	local child1 = ecs.CreateEntity("child1", parent)
	local child2 = ecs.CreateEntity("child2", parent)
	local grandchild = ecs.CreateEntity("grandchild", child1)
	T(#world:GetChildren())["=="](1)
	T(#parent:GetChildren())["=="](2)
	T(#child1:GetChildren())["=="](1)
	parent:Remove()
	-- After removal, they should be invalid (next frame for MakeNULL, but __removed is immediate)
	T(parent:IsValid())["=="](false)
	T(child1:IsValid())["=="](false)
	T(child2:IsValid())["=="](false)
	T(grandchild:IsValid())["=="](false)
	T(#world:GetChildren())["=="](0)
end)
