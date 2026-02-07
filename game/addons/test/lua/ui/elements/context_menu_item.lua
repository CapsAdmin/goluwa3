local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = require("ui.elements.button")
local Text = require("ui.elements.text")
local theme = require("ui.theme")
return function(props)
	return Button(
		{
			Size = props.Size or (Vec2() + theme.GetSize("M")),
			Active = props.Active,
			Disabled = props.Disabled,
			OnClick = props.OnClick,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				GrowWidth = 1,
			},
			Padding = props.Padding or (Rect() + theme.GetSize("M")),
		}
	)(
		{
			Text(
				{
					layout = {GrowWidth = 1, FitHeight = true},
					Text = props.Text,
					IgnoreMouseInput = true,
					Color = props.Disabled and
						theme.GetColor("text_disabled") or
						theme.GetColor("text_foreground"),
				}
			),
		}
	)
end
