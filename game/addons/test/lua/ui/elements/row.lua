local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Panel.NewPanel(
		table.merge(
			{
				Name = "Row",
				Color = Color(0, 0, 0, 0),
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "center",
					ChildGap = theme.Sizes2.M,
				},
			},
			props
		)
	)
end
