local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = require("ui.elements.button")
local Text = require("ui.elements.text")
local theme = require("ui.theme")
return function(props)
	return Button(
		{
			Active = props.Active,
			Disabled = props.Disabled,
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
			OnClick = props.OnClick,
			Padding = (Rect() + theme.GetPadding(props.Padding or "XS")),
			Children = {
				Text(
					{
						Text = props.Text,
						IgnoreMouseInput = true,
						Color = props.Disabled and
							theme.GetColor("text_disabled") or
							theme.GetColor("text_foreground"),
					}
				),
			},
		}
	)
end
