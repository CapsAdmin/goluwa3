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
	return Panel.NewPanel(
		table.merge_many(
			{
				Name = "frame",
				Color = theme.GetColor("background"),
				gui_element = {
					OnDraw = function(self)
						theme.DrawFrame(self.Owner)
					end,
					OnPostDraw = function(self)
						theme.DrawFramePost(self.Owner)
					end,
				},
			},
			props,
			{
				Padding = Rect() + theme.GetPadding(props.Padding),
			}
		)
	)
end
