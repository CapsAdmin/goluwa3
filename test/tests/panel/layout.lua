local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

T.Test("panel layout 100px issue reproduction", function()
	local parent = Panel.New({
		Name = "Parent",
	})
	parent:AddComponent("layout")
	parent:AddComponent("transform")
	parent.transform:SetSize(Vec2(200, 200))
	parent.layout:SetLayout({"CenterX"})
	local Panel = require("ecs.panel")
	Panel.World.layout:CalcLayout()
	T(parent.transform:GetSize())["=="](Vec2(200, 200))
end)

T.Test("panel layout padding and SizeToChildren", function()
	local parent = Panel.New({
		Name = "Parent",
		Padding = Rect(10, 10, 10, 10),
	})
	parent:AddComponent("transform")
	T(parent.layout:GetPadding())["=="](Rect(10, 10, 10, 10))
	local child = Panel.New(
		{
			Name = "Child",
			Parent = parent,
			Size = Vec2(50, 50),
			Position = Vec2(0, 0),
		}
	)
	parent.layout:SizeToChildren()
	-- Child is 50x50. Parent has 10px padding on all sides.
	-- SizeToChildren should result in 50 + 10 + 10 = 70.
	T(parent.transform:GetSize())["=="](Vec2(70, 70))
end)
