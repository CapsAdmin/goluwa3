local T = require("test.environment")
local gui = require("gui.gui")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local W = 512
local H = 512

local function TestGUI(name, func)
	return T.Test2D(name, function()
		gui.Initialize() -- resets the gui.Root
		local ret = func()
		gui.Root:Draw() -- draw once to the render target
		return ret
	end)
end

TestGUI("example test", function()
	local p = gui.Create("base")
	p:SetSize(Vec2(100, 100))
	p:SetPosition(Vec2(10, 10))
	p:SetColor(Color(1, 0, 0, 1))
	p:SetLayout({
		"CenterX",
		"CenterY",
	})
	return function()
		local x, y = p.WorldMatrix:GetTranslation()
		T((W - 100) / 2)["=="](x)
		T((H - 100) / 2)["=="](y)
		T.Screenshot("test")
	end
end)
