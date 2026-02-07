local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	return Panel.NewPanel(
		table.merge_many(
			{
				Name = "Column",
				Color = theme.GetColor("invisible"),
				layout = {
					Direction = "y",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "center",
					ChildGap = theme.GetSize("S"),
				},
			},
			props
		)
	)
end
