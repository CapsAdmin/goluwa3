local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Text = import("lua/ui/elements/text.lua")
local theme = import("lua/ui/theme.lua")
return function(props)
	return Clickable{
		Active = props.Active,
		Disabled = props.Disabled,
		Mode = props.Mode or "filled",
		layout = {
			FitWidth = true,
			FitHeight = true,
		},
		OnClick = props.OnClick,
		Padding = "XS",
	}(
		Text{
			Text = props.Text,
			IgnoreMouseInput = true,
			Color = props.Disabled and "text_disabled" or "text_foreground",
		}
	)
end