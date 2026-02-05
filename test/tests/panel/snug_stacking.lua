local T = require("test.environment")
local Panel = require("ecs.panel")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

T.Test("panels should stack snugly with SizeToChildren and MoveLeft", function()
	local parent = Panel.NewPanel({
		Name = "Parent",
		Size = Vec2(1000, 100),
	})

	local function CreateSnugPanel(name, width)
		local p = Panel.NewPanel(
			{
				Name = name,
				Parent = parent,
				Layout = {"SizeToChildren", "CenterYSimple", "MoveLeft"},
			}
		)
		-- Add a child that gives it size
		Panel.NewPanel(
			{
				Parent = p,
				Size = Vec2(width, 24),
			-- No layout on child, so it stays at 0,0 within the panel
			}
		)
		return p
	end

	local p1 = CreateSnugPanel("P1", 50)
	local p2 = CreateSnugPanel("P2", 70)
	local p3 = CreateSnugPanel("P3", 30)
	parent.layout:CalcLayout()
	-- Check sizes
	T(p1.transform.Size.x)["=="](50)
	T(p1.transform.Size.y)["=="](24)
	T(p2.transform.Size.x)["=="](70)
	T(p3.transform.Size.x)["=="](30)
	-- Check positions
	T(p1.transform.Position.x)["=="](0)
	T(p2.transform.Position.x)["=="](50)
	T(p3.transform.Position.x)["=="](120)
end)
