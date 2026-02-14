local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Panel = require("ecs.panel")
local theme = require("ui.theme")
return function(props)
	return Panel.New(
		{
			props,
			{
				Name = "Row",
				OnSetProperty = theme.OnSetProperty,
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					AlignmentY = "center",
					ChildGap = "M",
					props.layout,
				},
				transform = true,
				gui_element = true,
				mouse_input = true,
				clickable = true,
				animation = true,
			},
		}
	)
end
