local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
return function(props)
	return Panel.New{
		props,
		{
			Name = "Row",
			layout = {
				Direction = "x",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentY = "center",
				ChildGap = "M",
				props.layout,
			},
			transform = true,
		},
	}
end
