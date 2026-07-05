local Vec2 = import("goluwa/structs/vec2.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
return function(props)
	return Clickable(props){
		Text{
			IgnoreMouseInput = true,
			Text = props.Text or "Button",
			Color = props.TextColor or "text",
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
			AlignX = "center",
			AlignY = "center",
		},
	}
end
