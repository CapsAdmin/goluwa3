local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")

T.Test("layout storm guard - identity property update", function()
	local p = Panel.NewPanel({Size = Vec2(100, 100)})
	p.layout:CalcLayout()
	local count = p.layout.layout_count or 0
	p.transform:SetSize(Vec2(100, 100))
	p.layout:CalcLayout()
	T(p.layout.layout_count or 0)["=="](count)
	p.transform:SetPosition(p.transform:GetPosition())
	p.layout:CalcLayout()
	T(p.layout.layout_count or 0)["=="](count)
end)

T.Test("layout storm guard - redundant invalidation during layout", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(200, 200)})
	local child = Panel.NewPanel({Name = "Child", Parent = parent, Size = Vec2(100, 100)})
	parent.layout:CalcLayout()
	local parent_count = parent.layout.layout_count
	-- Manually trigger something that causes layout
	parent.layout:InvalidateLayout()
	parent.layout:CalcLayout()
	T(parent.layout.layout_count)["=="](parent_count + 1)
	parent_count = parent.layout.layout_count
	-- Setting child size to same value should NOT invalidate parent
	child.transform:SetSize(child.transform:GetSize())
	parent.layout:CalcLayout()
	T(parent.layout.layout_count)["=="](parent_count)
end)

T.Test("layout storm guard - SizeToChildren stability", function()
	local parent = Panel.NewPanel({Name = "Parent", Padding = require("structs.rect")(10, 10, 10, 10)})
	local child = Panel.NewPanel({Name = "Child", Parent = parent, Size = Vec2(50, 50)})
	parent.layout:SizeToChildren()
	parent.layout:CalcLayout()
	local parent_count = parent.layout.layout_count
	-- Calling SizeToChildren again with same children should not cause infinite loops or excessive counts
	parent.layout:SizeToChildren()
	parent.layout:CalcLayout()
	-- It might run once more because SizeToChildren might internaly invalidate if it wasn't perfectly stable, 
	-- but it definitely shouldn't be thousands.
	T(parent.layout.layout_count - parent_count)["<"](5)
end)

T.Test("layout storm guard - hierarchical invalidation break", function()
	local grandparent = Panel.NewPanel({Name = "Grandparent", Size = Vec2(300, 300)})
	local parent = Panel.NewPanel({Name = "Parent", Parent = grandparent, Size = Vec2(200, 200)})
	local child = Panel.NewPanel({Name = "Child", Parent = parent, Size = Vec2(100, 100)})
	grandparent.layout:CalcLayout()
	parent.layout:CalcLayout()
	child.layout:CalcLayout()
	local gp_count = grandparent.layout.layout_count
	-- If the parent is "in layout", child invalidations should not reach grandparent
	parent.layout:EnterLayout()
	child.layout:InvalidateLayout()
	T(grandparent.layout.LayoutInvalidated)["=="](false)
	parent.layout:ExitLayout()
	-- Reset child and parent invalidation state for the next part of the test
	child.layout.LayoutInvalidated = false
	parent.layout.LayoutInvalidated = false
	-- But if parent is NOT in layout, child invalidations SHOULD reach grandparent
	child.layout:InvalidateLayout()
	T(grandparent.layout.LayoutInvalidated)["=="](true)
end)
