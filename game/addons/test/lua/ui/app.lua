local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Color = require("structs.color")
local lsx = require("gui.lsx")
local Ang3 = require("structs.ang3")
local Interactive = runfile("lua/ui/components/interactive.lua")
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
		}
	)
end)
require("gui.gui").Root:RemoveChildren()
lsx.Mount(App())
