local T = require("test.environment")
local lsx = require("gui.lsx")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local gui = require("gui.gui")

T.Test("lsx component ref and layout", function()
	local ref_called = false
	local MyComponent = lsx.Component(function(props)
		return lsx.Panel({
			Name = "InternalPanel",
			Size = Vec2(100, 100),
		})
	end)
	local root = gui.Create("base")
	local instance = lsx.Mount(
		MyComponent({
			ref = function(pnl)
				ref_called = true
			end,
			Layout = {"Fill"},
		}),
		root
	)
	T(ref_called)["=="](true)
	T(instance.Layout[1])["=="]("Fill")
	instance:Remove()
	root:Remove()
end)

T.Test("lsx layout calculation with children", function()
	local MyComponent = lsx.Component(function(props)
		return lsx.Panel(
			{
				Name = "Container",
				Size = Vec2(200, 200),
				Layout = {"Fill"}, -- This layout might depend on children if it was something else, but let's test a simple Case
				lsx.Panel(
					{
						Name = "Child",
						Size = Vec2(50, 50),
						Layout = {"CenterXSimple"},
					}
				),
			}
		)
	end)
	local root = gui.Create("base")
	root:SetSize(Vec2(500, 500))
	local surface = lsx.Mount(MyComponent({}), root)
	-- Trigger layout calculation
	root:CalcLayout()
	T(surface.Size.x)["=="](500)
	T(surface.Size.y)["=="](500)
	local child = surface:GetChildren()[1]
	T(child ~= nil)["=="](true)
	child:CalcLayout()
	-- CenterXSimple should put it at (500-50)/2 = 225
	T(child.Position.x)["=="](225)
	surface:Remove()
	root:Remove()
end)
