local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Button(
		{
			Size = props.Size or theme.Sizes.MenuButtonSize,
			Active = props.Active,
			Disabled = props.Disabled,
			OnClick = props.OnClick,
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				GrowWidth = 1,
			},
			Padding = props.Padding or (Rect() + theme.Sizes2.M),
			Children = {
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
			},
		}
	)
end
