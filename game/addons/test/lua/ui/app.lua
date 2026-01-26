local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("ecs.lsx_ecs")
local ecs = require("ecs.ecs")
local Ang3 = require("structs.ang3")
local Interactive = runfile("lua/ui/components/interactive.lua")
local App = function()
	return lsx:Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			Interactive(
				lsx:Text(
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
end
require("ecs.ecs").Clear2DWorld()
lsx:Mount(App)

do
	local timer = require("timer")
	local utility = require("utility")
	local pnl = utility.RemoveOldObject(require("ecs.entities.2d.panel")())
	pnl:AddComponent(require("ecs.components.2d.resizable"))
	pnl.transform_2d:SetPosition(Vec2() + 300)
	pnl.transform_2d:SetSize(Vec2() + 200)
	pnl.mouse_input_2d:SetDragEnabled(true)
	pnl.resizable_2d:SetResizable(true)
	pnl.rect_2d:SetClipping(true)
	pnl.transform_2d:SetScrollEnabled(true)
	pnl.rect_2d:SetColor(Color.FromHex("#062a67"):SetAlpha(1))
	local txt = require("ecs.entities.2d.panel")(pnl)
	txt:AddComponent(require("ecs.components.2d.text"))
	txt.text_2d:SetWrap(true)
	txt.text_2d:SetWrapToParent(true)
	txt.text_2d:SetText([[The materia builder is built to assist in exploring the possibilities of dynamic spells, harmonizing culturures, and customizing a written scale. All with implementation in mind to bridge mage and warriors.]])
end
