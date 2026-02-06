local Vec2 = require("structs.vec2")
local Button = require("ui.elements.button")
local Text = require("ui.elements.text")
local theme = require("ui.theme")
return function(props)
	local button_props = table.copy(props)
	button_props.Children = {
		Text(
			{
				IgnoreMouseInput = true,
				Text = props.Text or "Button",
				Color = props.TextColor or theme.GetColor("text_foreground"),
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
