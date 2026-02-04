local Rect = require("structs.rect")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local Button = runfile("lua/ui/elements/button.lua")
local Text = runfile("lua/ui/elements/text.lua")
return function(props)
	return Button(
		{
			Margin = Rect() + 10,
			Size = props.Size or Vec2(150, 40),
			Active = props.Active,
			Disabled = props.Disabled,
			Layout = props.Layout,
			OnClick = props.OnClick,
			Children = {
				Text(
					{
						Text = props.Text,
						IgnoreMouseInput = true,
						Color = props.Disabled and Color(1, 1, 1, 0.3) or Color(1, 1, 1, 0.8),
						Layout = {"MoveLeft", "CenterY"},
					}
				),
			},
		}
	)
end
