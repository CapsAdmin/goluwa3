local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
local theme = runfile("lua/ui/theme.lua")
return function(props)
	return Button(
		{
			Margin = theme.Sizes.MenuButtonMargin,
			Size = props.Size or theme.Sizes.MenuButtonSize,
			Active = props.Active,
			Disabled = props.Disabled,
			Layout = props.Layout,
			OnClick = props.OnClick,
			Children = {
				Text(
					{
						Text = props.Text,
						IgnoreMouseInput = true,
						Color = props.Disabled and theme.Colors.TextDisabled or theme.Colors.TextNormal,
						Layout = {"MoveLeft", "CenterY"},
					}
				),
			},
		}
	)
end
