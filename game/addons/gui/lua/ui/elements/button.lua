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
		Ref = props.Ref,
		layout = {
			FitWidth = true,
			FitHeight = true,
			props.layout,
		},
		OnClick = props.OnClick,
		Padding = props.Padding or "XS",
	}(
		Text{
			Text = props.Text,
			IgnoreMouseInput = true,
			Color = props.Disabled and "text_disabled" or "text_foreground",
			AlignX = props.AlignX or "center",
			AlignY = props.AlignY or "center",
			layout = props.TextLayout,
		}
	)
end
