local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("gui.lsx")
local Ang3 = require("structs.ang3")
local Interactive = runfile("lua/ui/components/interactive.lua")

do
	local timer = require("timer")
	local utility = require("utility")
	local Color = require("structs.color")

	timer.Delay(0, function()
		local gui = require("gui.gui")
		local pnl = utility.RemoveOldObject(gui.Create("frame"))
		pnl:SetPosition(Vec2() + 300)
		pnl:SetSize(Vec2() + 200)
		pnl:SetDragEnabled(true)
		pnl:SetResizable(true)
		pnl:SetClipping(true)
		pnl:SetScrollEnabled(true)
		pnl:SetColor(Color.FromHex("#062a67"):SetAlpha(1))
		local txt = pnl:CreatePanel("text")
		txt:SetWrap(true)
		txt:SetWrapToParent(true)
		txt:SetText([[The materia builder is built to assist in exploring the possibilities of dynamic spells, harmonizing culturures, and customizing a written scale. All with implementation in mind to bridge mage and warriors.]])
	end)
end

local App = lsx.Component(function()
	return lsx.Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			Interactive(
				lsx.Text(
					{
						Text = "hello world",
						IgnoreMouseInput = true,
						Color = Color(1, 1, 1, 1),
						Layout = {"CenterSimple"},
					}
				)
			),
			Interactive(
				lsx.Text(
					{
						Text = "hello world",
						IgnoreMouseInput = true,
						Color = Color(1, 1, 1, 1),
						Layout = {"CenterSimple"},
					}
				)
			),
		}
	)
end)
require("gui.gui").Root:RemoveChildren()
lsx.Mount(App())
