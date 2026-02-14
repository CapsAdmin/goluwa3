local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local Panel = require("ecs.panel")
local Texture = require("render.texture")
local theme = require("ui.theme")
return function(props)
	props = props or {}
	return Panel.New(
		{
			Name = "MenuSpacer",
			transform = {
				Size = props.Vertical and
					Vec2(theme.GetSize("line_height"), 0) or
					Vec2(0, theme.GetSize("line_height")),
			},
			rect = {
				Color = theme.GetColor("invisible"),
			},
			layout = {
				GrowWidth = 1,
			},
			gui_element = {
				OnDraw = function(self)
					theme.DrawMenuSpacer(self, props)
				end,
			},
			mouse_input = true,
			clickable = true,
			animation = true,
		}
	)
end
