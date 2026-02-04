local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Ang3 = require("structs.ang3")
local window = require("window")
local prototype = require("prototype")
local fonts = require("render2d.fonts")
local gfx = require("render2d.gfx")
local Panel = require("ecs.entities.2d.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Panel(
		table.merge(
			{
				Name = "frame",
				Color = theme.Colors.FrameBackground,
				gui_element = {
					OnDraw = function(self)
						theme.DrawFrame(self.Owner)
					end,
					OnPostDraw = function(self)
						theme.DrawFramePost(self.Owner)
					end,
				},
			},
			props
		)
	)
end
