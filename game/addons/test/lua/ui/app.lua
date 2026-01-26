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
local App = function()
	return lsx:Panel(
		{
			Name = "App",
			Size = Vec2(render2d.GetSize()),
			Color = Color(0, 0, 0, 0),
			Padding = Rect(20, 20, 20, 20),
			Frame(
				{
					Size = Vec2() + 300,
					Position = Vec2() + 100,
					Button(
						{
							lsx:Text(
								{
									Text = "hello world",
									IgnoreMouseInput = true,
									Color = Color(1, 1, 1, 1),
									Layout = {"CenterSimple"},
								}
							),
						}
					),
				}
			),
		}
	)
end
require("ecs.ecs").Clear2DWorld()
lsx:Mount(App)
