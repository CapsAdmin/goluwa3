local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Clickable = require("ui.elements.clickable")
local Text = require("ui.elements.text")
local theme = require("ui.theme")
return function(props)
	return Clickable(
		{
			Size = props.Size or "M",
			Active = props.Active,
			Disabled = props.Disabled,
			OnClick = props.OnClick,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				GrowWidth = 1,
			},
			Padding = "M",
		}
	)(
		{
			Text(
				{
					layout = {
						GrowWidth = 1,
						FitHeight = true,
					},
					Text = props.Text,
					IgnoreMouseInput = true,
					Color = props.Disabled and "text_disabled" or "text_foreground",
				}
			),
		}
	)
end
