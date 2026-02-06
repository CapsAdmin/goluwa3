local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Panel.NewPanel(
		table.merge(
			{
				Name = "Column",
				Color = Color(0, 0, 0, 0),
				layout = {
					Direction = "y",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "center",
					ChildGap = theme.Sizes2.S,
				},
			},
			props
		)
	)
end
