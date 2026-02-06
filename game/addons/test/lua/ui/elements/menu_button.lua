local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
local theme = runfile("lua/ui/theme.lua")
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
						Color = props.Disabled and theme.Colors.TextDisabled or theme.Colors.TextNormal,
					}
				),
			},
		}
	)
end
