local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("ecs.lsx_ecs")
local ecs = require("ecs.ecs")
local Ang3 = require("structs.ang3")
local Button = runfile("lua/ui/elements/button.lua")
local Frame = runfile("lua/ui/elements/frame.lua")
local Text = runfile("lua/ui/elements/text.lua")

local function MenuButton(props)
	return Button(
		{
			Layout = {"GmodTop"},
			Padding = Rect(10, 10, 10, 10),
			Text(
				{
					Text = props.Text,
					IgnoreMouseInput = true,
					Color = Color(1, 1, 1, 0.8),
					Layout = {"MoveLeft", "CenterY"},
				}
			),
		}
	)
end

local App = function()
	return lsx:Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			Frame(
				{
					Layout = {"CenterSimple", "SizeToChildrenHeight"},
					Resizable = true,
					Size = Vec2(350, 200),
					Padding = Rect() + 10,
					MenuButton({
						Text = "Abilities",
					}),
					MenuButton({
						Text = "Spells",
					}),
					MenuButton({
						Text = "Items",
					}),
					MenuButton({
						Text = "Limit Breaks",
					}),
				}
			),
		}
	)
end
require("ecs.ecs").Clear2DWorld()
lsx:Mount(App)
