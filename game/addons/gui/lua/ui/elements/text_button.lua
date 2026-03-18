local Vec2 = import("goluwa/structs/vec2.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	return Clickable(props){
		Text{
			IgnoreMouseInput = true,
			Text = props.Text or "Button",
			Color = props.TextColor or "text_foreground",
			layout = {
				FitWidth = true,
				FitHeight = true,
			},
			AlignX = "center",
			AlignY = "center",
		},
	}
end
