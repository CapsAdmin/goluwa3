local T = require("test.environment")
local prototype = require("prototype")

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
