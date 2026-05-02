local Color = import("goluwa/structs/color.lua")
local Clickable = import("lua/ui/elements/clickable.lua")
local Text = import("lua/ui/elements/text.lua")
return function(props)
	return Clickable{
		Active = props.Active,
		ButtonColor = props.ButtonColor,
		Disabled = props.Disabled,
		Mode = props.Mode or "filled",
		Ref = props.Ref,
		layout = {
			FitWidth = true,
			FitHeight = true,
			props.layout,
		},
		OnClick = props.OnClick,
		Padding = props.Padding or "S",
	}(
		Text{
			Text = props.Text,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize,
			IgnoreMouseInput = true,
			Color = props.TextColor or
				(
					(
						(
							props.Mode == "text" or
							props.Mode == "outline"
						)
						and
						props.ButtonColor
					)
					or
					(
						props.Disabled and
						"text_disabled" or
						"text"
					)
				),
			AlignX = props.AlignX or "center",
			AlignY = props.AlignY or "center",
			layout = props.TextLayout,
		}
	)
end
