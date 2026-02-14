local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local window = require("window")
local prototype = require("prototype")
local fonts = require("render2d.fonts")
local gfx = require("render2d.gfx")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	return Panel.New(
		{
			props,
			{
				Name = "frame",
				rect = {
					Color = theme.GetColor("invisible"),
				},
				gui_element = {
					OnDraw = function(self)
						theme.panels.frame(self.Owner, props.Emphasis or 1)
					end,
					OnPostDraw = function(self)
						theme.panels.frame_post(self.Owner, props.Emphasis or 1)
					end,
				},
				layout = {
					Padding = Rect() + theme.GetPadding(props.Padding),
					props.layout,
				},
				transform = true,
				mouse_input = true,
				clickable = true,
				animation = true,
			},
		}
	)
end
