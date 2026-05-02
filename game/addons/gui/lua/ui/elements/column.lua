local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	return Panel.New{
		props,
		{
			Name = "Column",
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "center",
				ChildGap = "M",
				props.layout,
			},
			transform = true,
		},
	}
end
