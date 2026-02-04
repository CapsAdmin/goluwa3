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
			Padding = props.Padding or (Rect() + theme.Sizes2.M),
			Margin = props.Margin or Rect(),
			Children = {
				Text(
					{
						Layout = {"CenterSimple", "MoveLeft"},
						Text = props.Text,
						IgnoreMouseInput = true,
						Color = props.Disabled and theme.Colors.TextDisabled or theme.Colors.TextNormal,
					}
				),
			},
		}
	)
end
