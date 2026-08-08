local T = import("test/environment.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("panel children parenting via constructor", function()
	local child = Panel.New({Name = "Child"})
	local parent = Panel.New{Name = "Parent", Children = {child}}
	T(child:GetParent())["=="](parent)
	T(parent:GetChildren()[1])["=="](child)
	T(parent:HasChild(child))["=="](true)
end)

T.Test("panel nested children parenting via constructor", function()
	local child_child = Panel.New({Name = "GrandChild"})
	local child = Panel.New{Name = "Child", Children = {child_child}}
	local parent = Panel.New{Name = "Parent", Children = {child}}
	T(child_child:GetParent())["=="](child)
	T(child:GetParent())["=="](parent)
	T(parent:GetChildren()[1])["=="](child)
	T(child:GetChildren()[1])["=="](child_child)
end)

T.Test("panel ui objects in config array are added as children not flattened", function()
	local child1 = Panel.New({Name = "Child1"})
	local grandchild1 = Panel.New({Name = "GrandChild1"})
	child1:AddChild(grandchild1)

	local child2 = Panel.New({Name = "Child2"})
	local grandchild2 = Panel.New({Name = "GrandChild2"})
	child2:AddChild(grandchild2)

	local parent = Panel.New{Name = "Parent", Children = {child1, child2}}

	T(#parent:GetChildren())["=="](2)
	T(parent:GetChildren()[1])["=="](child1)
	T(parent:GetChildren()[2])["=="](child2)
	T(child1:GetChildren()[1])["=="](grandchild1)
	T(child2:GetChildren()[1])["=="](grandchild2)
	T(grandchild1:GetParent())["=="](child1)
	T(grandchild2:GetParent())["=="](child2)
end)
