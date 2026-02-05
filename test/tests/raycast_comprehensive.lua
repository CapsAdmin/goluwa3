local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

T.Test("RayCast basic collision", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(100, 100)})
	local obstacle = Panel.NewPanel(
		{
			Name = "Obstacle",
			Parent = parent,
			Position = Vec2(40, 0),
			Size = Vec2(20, 100),
		}
	)
	-- Ensure layout is updated so RayCast works
	parent.layout:CalcLayout()
	local mover = Panel.NewPanel({Name = "Mover", Parent = parent, Size = Vec2(10, 10)})
	-- Test RayCast to the right
	local hit, hit_ent = mover.layout:RayCast(Vec2(0, 45), Vec2(100, 45))
	-- Mover is 10 wide. Obstacle is at x=40.
	-- RayCast is supposed to return the position the mover would be at when hitting.
	-- For dir.x > 0, it calculates: hit_pos.x = target_x - mover_width
	T(hit_ent)["=="](obstacle)
	T(hit.x)["=="](30) -- 40 (obstacle.x) - 10 (mover.width)
end)

T.Test("RayCast directionality and filtering", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(100, 100)})
	local p1 = Panel.NewPanel({Name = "P1", Parent = parent, Position = Vec2(20, 20), Size = Vec2(10, 10)})
	local p2 = Panel.NewPanel({Name = "P2", Parent = parent, Position = Vec2(60, 20), Size = Vec2(10, 10)})
	parent.layout:CalcLayout()
	local mover = Panel.NewPanel({Name = "Mover", Parent = parent, Size = Vec2(5, 5)})
	-- RayCast from 40 to 100 (should hit P2)
	local hit_r, ent_r = mover.layout:RayCast(Vec2(40, 22), Vec2(100, 22))
	T(ent_r)["=="](p2)
	T(hit_r.x)["=="](55) -- 60 - 5
	-- RayCast from 40 to 0 (should hit P1)
	local hit_l, ent_l = mover.layout:RayCast(Vec2(40, 22), Vec2(0, 22))
	T(ent_l)["=="](p1)
	T(hit_l.x)["=="](30) -- 20 + 10 (p1 x + width)
end)

T.Test("RayCast vertical collision", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(100, 100)})
	local floor = Panel.NewPanel({Name = "Floor", Parent = parent, Position = Vec2(0, 80), Size = Vec2(100, 20)})
	parent.layout:CalcLayout()
	local mover = Panel.NewPanel({Name = "Mover", Parent = parent, Size = Vec2(50, 10)})
	-- RayCast down
	local hit_d, ent_d = mover.layout:RayCast(Vec2(0, 0), Vec2(0, 100))
	T(ent_d)["=="](floor)
	T(hit_d.y)["=="](70) -- 80 - 10
	-- RayCast up
	local ceiling = Panel.NewPanel(
		{
			Name = "Ceiling",
			Parent = parent,
			Position = Vec2(0, 10),
			Size = Vec2(100, 5),
		}
	)
	parent.layout:CalcLayout()
	local hit_u, ent_u = mover.layout:RayCast(Vec2(0, 50), Vec2(0, 0))
	T(ent_u)["=="](ceiling)
	T(hit_u.y)["=="](15) -- 10 + 5
end)

T.Test("RayCast margins influence", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(100, 100)})
	local target = Panel.NewPanel(
		{
			Name = "Target",
			Parent = parent,
			Position = Vec2(50, 0),
			Size = Vec2(10, 100),
			Margin = Rect(5, 5, 5, 5),
		}
	)
	parent.layout:CalcLayout()
	local mover = Panel.NewPanel({Name = "Mover", Parent = parent, Size = Vec2(10, 10)})
	-- Should hit target.x - mover.width - target.margin_left - mover.margin_right
	-- Target x=50, margin_left=5. Mover has no margin.
	-- Expected hit: 50 - 10 - 5 = 35?
	-- Current code: hit_pos.x = child_tr:GetX() - entity.transform:GetWidth() - self:GetMargin():GetRight() - child_layout:GetMargin():GetLeft()
	local hit, hit_ent = mover.layout:RayCast(Vec2(0, 45), Vec2(100, 45))
	T(hit_ent)["=="](target)
	T(hit.x)["=="](35)
end)

T.Test("RayCast ignore self and invisible", function()
	local parent = Panel.NewPanel({Name = "Parent", Size = Vec2(100, 100)})
	local mover = Panel.NewPanel({Name = "Mover", Parent = parent, Size = Vec2(10, 10), Position = Vec2(0, 0)})
	local obstacle = Panel.NewPanel(
		{
			Name = "Obstacle",
			Parent = parent,
			Position = Vec2(50, 0),
			Size = Vec2(10, 10),
		}
	)
	parent.layout:CalcLayout()
	-- Should hit obstacle normally
	local hit1, ent1 = mover.layout:RayCast(Vec2(0, 5), Vec2(100, 5))
	T(ent1)["=="](obstacle)
	-- Hide obstacle
	obstacle.gui_element:SetVisible(false)
	parent.layout:CalcLayout()
	local hit2, ent2 = mover.layout:RayCast(Vec2(0, 5), Vec2(100, 5))
	T(ent2)["=="](nil)
	T(hit2.x)["=="](100)
	-- Show obstacle but IgnoreLayout
	obstacle.gui_element:SetVisible(true)
	obstacle.layout:SetIgnoreLayout(true)
	parent.layout:CalcLayout()
	local hit3, ent3 = mover.layout:RayCast(Vec2(0, 5), Vec2(100, 5))
	T(ent3)["=="](nil)
end)
