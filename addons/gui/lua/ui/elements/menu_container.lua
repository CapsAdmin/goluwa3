local Panel = import("goluwa/ecs/panel.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	props = props or {}
	return Panel.New{
		props,
		{
			Name = "MenuContainer",
			transform = true,
			layout = {
				Direction = "y",
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = "none",
				Padding = "none",
				props.layout,
			},
			gui_element = {
				OnDraw = function(self)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = true,
			clickable = true,
			animation = true,
		},
	}
end
