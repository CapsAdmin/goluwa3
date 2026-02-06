local Vec2 = require("structs.vec2")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	local button_props = table.copy(props)
	button_props.Children = {
		Text(
			{
				IgnoreMouseInput = true,
				Text = props.Text or "Button",
				Color = props.TextColor or theme.Colors.Text,
				layout = {
					FitWidth = true,
					FitHeight = true,
				},
				AlignX = "center",
				AlignY = "center",
			}
		),
		props.Children,
	}
	button_props.layout = table.merge({
		AlignmentX = "center",
		AlignmentY = "center",
	}, props.layout or {})
	return Button(button_props)
end
