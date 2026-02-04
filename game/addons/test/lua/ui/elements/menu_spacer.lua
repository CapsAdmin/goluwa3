local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local Panel = require("ecs.entities.2d.panel")
local Texture = require("render.texture")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	props = props or {}
	return Panel(
		{
			Name = "MenuSpacer",
			Size = props.Vertical and Vec2(theme.line_height, 0) or Vec2(0, theme.line_height), -- 0 is assumed to get stretched out somehow
			Color = theme.Colors.Invisible,
			Layout = {"FillX"},
			gui_element = {
				OnDraw = function(self)
					theme.DrawMenuSpacer(self, props)
				end,
			},
		}
	)
end
