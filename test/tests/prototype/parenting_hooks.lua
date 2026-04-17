local T = import("test/environment.lua")
local prototype = import("goluwa/prototype.lua")

T.Test("prototype parenting hooks", function()
	local META = prototype.CreateTemplate("test_parenting_hooks")
	prototype.ParentingTemplate(META)
	META:Register()
	local CHILD_META = prototype.CreateTemplate("test_child")
	prototype.ParentingTemplate(CHILD_META)
	CHILD_META:Register()
	local parent = prototype.CreateObject(META)
	local child1 = prototype.CreateObject(CHILD_META)
	local child2 = prototype.CreateObject(CHILD_META)
	-- 1. Test standard AddChild
	parent:AddChild(child1)
	T(#parent:GetChildren())["=="](1)
	T(child1:GetParent())["=="](parent)

	-- 2. Test PreChildAdd blocking
	function parent:PreChildAdd(obj)
		if obj == child2 then return false end
	end

	parent:AddChild(child2)
	T(#parent:GetChildren())["=="](1)
	T(child2:HasParent())["=="](false)
	-- 2.1 Test PreChildAdd receiving pos
	local captured_pos

	function parent:PreChildAdd(obj, pos)
		captured_pos = pos
		return true
	end

	parent:AddChild(child2, 5)
	T(captured_pos)["=="](5)
	-- 3. Test PreChildAdd redirection
	local container = prototype.CreateObject(CHILD_META)
	parent:AddChild(container)
	T(#parent:GetChildren())["=="](2)

	function parent:PreChildAdd(obj)
		if obj.Type == "test_child" and obj ~= container then
			container:AddChild(obj)
			return false
		end
	end

	local child3 = prototype.CreateObject(CHILD_META)
	parent:AddChild(child3)
	T(#parent:GetChildren())["=="](2) -- Should still be 2 (container and child1)
	T(child3:GetParent())["=="](container) -- Should be redirected to container
	-- 4. Test PreRemoveChildren blocking
	local p2 = prototype.CreateObject(META)
	local c1 = prototype.CreateObject(CHILD_META)
	p2:AddChild(c1)
	T(#p2:GetChildren())["=="](1)

	function p2:PreRemoveChildren()
		return false
	end

	p2:RemoveChildren()
	T(#p2:GetChildren())["=="](1) -- Should NOT be removed
	T(c1:IsValid())["=="](true)
	-- 5. Test PreRemoveChildren custom logic
	local p3 = prototype.CreateObject(META)
	local sub_container = prototype.CreateObject(CHILD_META)
	p3:AddChild(sub_container)

	function sub_container:PreChildAdd()
		return true
	end -- allow all
	local internal_child = prototype.CreateObject(CHILD_META)
	internal_child.IsInternal = true
	sub_container:AddChild(internal_child)
	local external_child = prototype.CreateObject(CHILD_META)
	sub_container:AddChild(external_child)
	T(#sub_container:GetChildren())["=="](2)

	function sub_container:PreRemoveChildren()
		local children = self:GetChildren()

		for i = #children, 1, -1 do
			local child = children[i]

			if not child.IsInternal then
				child:UnParent()
				child:Remove()
			end
		end

		return false
	end

	sub_container:RemoveChildren()
	T(#sub_container:GetChildren())["=="](1)
	T(internal_child:IsValid())["=="](true)
	T(external_child:IsValid())["=="](false)
end)

T.Test("prototype RemoveChildren bulk semantics", function()
	local META = prototype.CreateTemplate("test_remove_children_bulk")
	prototype.ParentingTemplate(META)

	function META:OnRemove()
		self:UnParent()
		self:RemoveChildren()
	end

	META:Register()
	local parent = prototype.CreateObject(META)
	local child_a = prototype.CreateObject(META)
	local child_b = prototype.CreateObject(META)
	local grandchild = prototype.CreateObject(META)
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

T.Test("prototype BringToFront and SendToBack reorder without reparent", function()
	local META = prototype.CreateTemplate("test_reorder_without_reparent")
	prototype.ParentingTemplate(META)
	META:Register()
	local parent = prototype.CreateObject(META)
	local child_a = prototype.CreateObject(META)
	local child_b = prototype.CreateObject(META)
	local child_c = prototype.CreateObject(META)
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
