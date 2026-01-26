local T = require("test.environment")
local ecs = require("ecs.ecs")
local lsx = require("ecs.lsx_ecs")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local W = 512
local H = 512

local function TestGUI(name, func)
	return T.Test2D(name, function()
		ecs.Clear2DWorld()
		local world = ecs.Get2DWorld()
		world.transform_2d:SetSize(Vec2(W, H))
		local ret = func()
		world:CalcLayout()

		for _, child in ipairs(world:GetChildren()) do
			local gui = child:GetComponent("gui_element_2d")

			if gui then gui:DrawRecursive() end
		end

		return ret
	end)
end

TestGUI("example test", function()
	local p = ecs.CreateEntity("test_gui", ecs.Get2DWorld())
	p:AddComponent(require("ecs.components.2d.transform"))
	p:AddComponent(require("ecs.components.2d.layout"))
	p:AddComponent(require("ecs.components.2d.rect"))
	p.transform_2d:SetSize(Vec2(100, 100))
	p.transform_2d:SetPosition(Vec2(10, 10))
	p.rect_2d:SetColor(Color(1, 0, 0, 1))
	p.layout_2d:SetLayout({
		"CenterX",
		"CenterY",
	})
	return function()
		local x, y = p.transform_2d:GetWorldMatrix():GetTranslation()
		T((W - 100) / 2)["=="](x)
		T((H - 100) / 2)["=="](y)
		T.Screenshot("test")
	end
end)
