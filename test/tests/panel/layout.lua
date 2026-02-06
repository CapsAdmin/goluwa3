local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

local function NewBox(name, size)
	local e = Panel.New()
	e:SetName(name)
	e:AddComponent("transform")
	e.transform:SetSize(size or Vec2(0, 0))
	return e
end

T.Test("layout - horizontal fit", function()
	local parent = NewBox("Parent", Vec2(100, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetFitWidth(true)
	parent.layout:SetFitHeight(true)
	parent.layout:SetPadding(Rect(10, 10, 10, 10))
	parent.layout:SetChildGap(5)
	local child1 = NewBox("Child1", Vec2(30, 40))
	child1:SetParent(parent)
	local child2 = NewBox("Child2", Vec2(20, 50))
	child2:SetParent(parent)
	-- Force layout update
	parent.layout:UpdateLayout()
	-- Padding(10) + child1(30) + gap(5) + child2(20) + padding(10) = 75
	T(parent.transform:GetWidth())["=="](75)
	-- Padding(10) + max(40, 50) + padding(10) = 70
	T(parent.transform:GetHeight())["=="](70)
	-- Child positions
	T(child1.transform:GetX())["=="](10)
	T(child2.transform:GetX())["=="](45) -- 10 + 30 + 5
	-- Cleanup
	parent:Remove()
end)

T.Test("layout - grow", function()
	local parent = NewBox("Parent", Vec2(200, 100))
	parent:AddComponent("layout")
	parent.layout:SetDirection("x")
	parent.layout:SetPadding(Rect(0, 0, 0, 0))
	parent.layout:SetChildGap(0)
	local child1 = NewBox("Child1", Vec2(50, 50))
	child1:SetParent(parent)
	child1:AddComponent("layout")
	child1.layout:SetGrowWidth(1)
	local child2 = NewBox("Child2", Vec2(50, 50))
	child2:SetParent(parent)
	child2:AddComponent("layout")
	child2.layout:SetGrowWidth(1)
	parent.layout:UpdateLayout()
	-- 200 total, 50 + 50 fixed = 100 leftover. 50 + 50 = 100 each.
	T(child1.transform:GetWidth())["=="](100)
	T(child2.transform:GetWidth())["=="](100)
	T(child2.transform:GetX())["=="](100)
	parent:Remove()
end)

T.Test("layout - alignment", function()
	local parent = NewBox("Parent", Vec2(200, 200))
	parent:AddComponent("layout")
	parent.layout:SetDirection("y")
	parent.layout:SetAlignmentX("center")
	parent.layout:SetAlignmentY("end")
	local child = NewBox("Child", Vec2(50, 50))
	child:SetParent(parent)
	parent.layout:UpdateLayout()
	-- Center X: (200 - 50) / 2 = 75
	T(child.transform:GetX())["=="](75)
	-- End Y: 200 - 50 = 150
	T(child.transform:GetY())["=="](150)
	parent:Remove()
end)

T.Test("layout - reactive invalidation", function()
	local parent = NewBox("Parent", Vec2(100, 100))
	parent:AddComponent("layout")
	parent.layout:SetFitWidth(true)
	local child = NewBox("Child", Vec2(50, 50))
	child:SetParent(parent)
	child:AddComponent("layout")
	-- First layout
	parent.layout:UpdateLayout()
	T(parent.transform:GetWidth())["=="](50)
	-- Change child size - should invalidate parent
	child.transform:SetWidth(100)
	T(parent.layout:GetDirty())["=="](true)
	-- Update again
	parent.layout:UpdateLayout()
	T(parent.transform:GetWidth())["=="](100)
	parent:Remove()
end)

T.Test("layout - collapse repro", function()
	local parent = Panel.NewPanel(
		{
			Name = "Parent",
			layout = {
				Direction = "y",
				FitHeight = true,
			},
		}
	)
	local child1 = Panel.NewPanel(
		{
			Parent = parent,
			Name = "Child1",
			layout = {
				FitHeight = true, -- This will collapse to 0 because no children
			},
		}
	)
	local child2 = Panel.NewPanel(
		{
			Parent = parent,
			Name = "Child2",
			layout = {
				FitHeight = true, -- Also collapses to 0
			},
		}
	)
	parent.layout:UpdateLayout()
	-- If they collapse to 0, they both sit at 0
	T(child1.transform:GetY())["=="](0)
	T(child1.transform:GetHeight())["=="](0)
	T(child2.transform:GetY())["=="](0)
	T(child2.transform:GetHeight())["=="](0)
	parent:Remove()
end)

T.Test("layout - text content intrinsic size", function()
	local parent = Panel.NewPanel(
		{
			Name = "Parent",
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
		}
	)
	local text = Panel.NewText(
		{
			Parent = parent,
			Text = "Hello World",
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
		}
	)
	parent.layout:UpdateLayout()
	-- Text should HAVE a size now, not 0
	T(text.transform:GetWidth())[">"](0)
	T(parent.transform:GetWidth())[">"](0)
	parent:Remove()
end)
