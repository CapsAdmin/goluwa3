local T = import("test/environment.lua")
local Panel = import("goluwa/ecs/panel.lua")
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