local T = import("test/environment.lua")
local objects = import("goluwa/objects/objects.lua")

T.Test("objects slot sends user children to the slot and keeps internal ones on the object", function()
	local META = objects.CreateTemplate("test_slot_parent")
	objects.ParentingTemplate(META)
	META.Slot = "content"

	function META:OnRemove()
		self:UnParent()
		self:RemoveAllChildren()
	end

	META:Register()
	local CHILD_META = objects.CreateTemplate("test_slot_child")
	objects.ParentingTemplate(CHILD_META)

	function CHILD_META:OnRemove()
		self:UnParent()
		self:RemoveAllChildren()
	end

	CHILD_META:Register()
	local parent = objects.CreateObject(META)
	local added = {}
	local removed = 0

	function parent:OnChildAdd(child)
		added[#added + 1] = child
	end

	function parent:OnChildrenRemoved()
		removed = removed + 1
	end

	local early = objects.CreateObject(CHILD_META)
	local ok = pcall(parent.AddChild, parent, early)
	T(ok)["=="](false)
	local content = objects.CreateObject(CHILD_META)
	content.IsInternal = true
	parent:AddChild(content)
	parent.content = content
	local header = objects.CreateObject(CHILD_META)
	header.IsInternal = true
	parent:AddChild(header)
	local a = objects.CreateObject(CHILD_META)
	local b = objects.CreateObject(CHILD_META)
	T(parent:AddChild(a))["=="](a)
	parent:AddChild(b, 1)
	T(a:GetParent())["=="](content)
	T(b:GetParent())["=="](content)
	T(content:GetChildren()[1])["=="](b)
	T(#parent:GetChildren())["=="](2)
	T(#added)["=="](4)
	T(added[3])["=="](a)
	T(added[4])["=="](b)
	parent:RemoveChildren()
	T(removed)["=="](1)
	T(a:IsValid())["=="](false)
	T(b:IsValid())["=="](false)
	T(#content:GetChildren())["=="](0)
	T(content:IsValid())["=="](true)
	T(header:IsValid())["=="](true)
	local c = objects.CreateObject(CHILD_META)
	parent:AddChild(c)
	parent:Remove()
	T(c:IsValid())["=="](false)
	T(content:IsValid())["=="](false)
	T(header:IsValid())["=="](false)
end)

T.Test("objects RemoveChildren keeps internal children without a slot and removes the rest completely", function()
	local META = objects.CreateTemplate("test_internal_children")
	objects.ParentingTemplate(META)

	function META:OnRemove()
		self:UnParent()
		self:RemoveAllChildren()
	end

	META:Register()
	local parent = objects.CreateObject(META)
	local internal = objects.CreateObject(META)
	internal.IsInternal = true
	local external_a = objects.CreateObject(META)
	local external_b = objects.CreateObject(META)
	local grandchild = objects.CreateObject(META)
	parent:AddChild(external_a)
	parent:AddChild(internal)
	parent:AddChild(external_b)
	external_a:AddChild(grandchild)
	parent:RemoveChildren()
	T(#parent:GetChildren())["=="](1)
	T(parent:GetChildren()[1])["=="](internal)
	T(internal:IsValid())["=="](true)
	T(external_a:IsValid())["=="](false)
	T(external_b:IsValid())["=="](false)
	T(grandchild:IsValid())["=="](false)
	T(#parent:GetChildrenList())["=="](1)
	parent:RemoveAllChildren()
	T(#parent:GetChildren())["=="](0)
	T(internal:IsValid())["=="](false)
end)

T.Test("objects RemoveChildren bulk semantics", function()
	local META = objects.CreateTemplate("test_remove_children_bulk")
	objects.ParentingTemplate(META)

	function META:OnRemove()
		self:UnParent()
		self:RemoveAllChildren()
	end

	META:Register()
	local parent = objects.CreateObject(META)
	local child_a = objects.CreateObject(META)
	local child_b = objects.CreateObject(META)
	local grandchild = objects.CreateObject(META)
	local unparent_calls = 0
	local child_remove_calls = 0

	function child_a:OnUnParent(old_parent)
		unparent_calls = unparent_calls + 1
		T(old_parent)["=="](parent)
	end

	function child_b:OnUnParent(old_parent)
		unparent_calls = unparent_calls + 1
		T(old_parent)["=="](parent)
	end

	function parent:OnChildRemove(child)
		child_remove_calls = child_remove_calls + 1
		T(child == child_a or child == child_b)["=="](true)
	end

	child_a:SetParent(parent)
	child_b:SetParent(parent)
	grandchild:SetParent(child_a)
	T(#parent:GetChildren())["=="](2)
	T(#parent:GetChildrenList())["=="](3)
	T(#child_a:GetParentList())["=="](1)
	T(#grandchild:GetParentList())["=="](2)
	parent:RemoveChildren()
	T(#parent:GetChildren())["=="](0)
	T(parent:HasChildren())["=="](false)
	T(child_remove_calls)["=="](2)
	T(unparent_calls)["=="](2)
	T(child_a:IsValid())["=="](false)
	T(child_b:IsValid())["=="](false)
	T(grandchild:IsValid())["=="](false)
	T(child_a:HasParent())["=="](false)
	T(child_b:HasParent())["=="](false)
	T(grandchild:HasParent())["=="](false)
	T(#parent:GetChildrenList())["=="](0)
end)

T.Test("objects BringToFront and SendToBack reorder without reparent", function()
	local META = objects.CreateTemplate("test_reorder_without_reparent")
	objects.ParentingTemplate(META)
	META:Register()
	local parent = objects.CreateObject(META)
	local child_a = objects.CreateObject(META)
	local child_b = objects.CreateObject(META)
	local child_c = objects.CreateObject(META)
	local parent_calls = 0
	local unparent_calls = 0

	function child_a:OnParent()
		parent_calls = parent_calls + 1
	end

	function child_a:OnUnParent()
		unparent_calls = unparent_calls + 1
	end

	child_a:SetParent(parent)
	child_b:SetParent(parent)
	child_c:SetParent(parent)
	T(parent:GetChildren()[1])["=="](child_a)
	T(parent:GetChildren()[2])["=="](child_b)
	T(parent:GetChildren()[3])["=="](child_c)
	T(#child_a:GetParentList())["=="](1)
	T(parent_calls)["=="](1)
	T(unparent_calls)["=="](0)
	child_a:BringToFront()
	T(parent:GetChildren()[1])["=="](child_b)
	T(parent:GetChildren()[2])["=="](child_c)
	T(parent:GetChildren()[3])["=="](child_a)
	T(#child_a:GetParentList())["=="](1)
	T(child_a:GetParent())["=="](parent)
	T(parent_calls)["=="](1)
	T(unparent_calls)["=="](0)
	child_a:SendToBack()
	T(parent:GetChildren()[1])["=="](child_a)
	T(parent:GetChildren()[2])["=="](child_b)
	T(parent:GetChildren()[3])["=="](child_c)
	T(#child_a:GetParentList())["=="](1)
	T(child_a:GetParent())["=="](parent)
	T(parent_calls)["=="](1)
	T(unparent_calls)["=="](0)
	T(child_a._child_insert_order < child_b._child_insert_order)["=="](true)
	T(child_b._child_insert_order < child_c._child_insert_order)["=="](true)
end)
