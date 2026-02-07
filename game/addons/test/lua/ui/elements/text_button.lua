local Vec2 = require("structs.vec2")
local Button = require("ui.elements.button")
local Text = require("ui.elements.text")
local theme = require("ui.theme")
return function(props)
	return Button(props)(
		{
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
		}
	)
end
