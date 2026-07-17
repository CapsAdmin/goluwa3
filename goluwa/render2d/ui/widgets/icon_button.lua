local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
return function(props)
	local icon_size = props.IconSize or 20
	local children = {}

	if props.SVG then
		children[#children + 1] = SVG{
			Source = props.SVG,
			Size = icon_size,
			MinSize = icon_size,
			MaxSize = icon_size,
			Color = props.TextColor,
			IgnoreMouseInput = true,
			AlignX = "center",
			AlignY = "center",
			layout = {
				GrowWidth = 0,
				FitWidth = false,
				FitHeight = false,
			},
		}
	elseif props.Text then
		children[#children + 1] = Text{
			Text = props.Text,
			Font = props.Font,
			FontName = props.FontName,
			FontSize = props.FontSize or "M",
			IgnoreMouseInput = true,
			Color = props.TextColor,
			AlignX = "center",
			AlignY = "center",
			layout = {
				--MinSize = icon_size,
				--MaxSize = icon_size,
				FitWidth = false,
				FitHeight = false,
			},
			InheritColor = props.TextColor == nil,
		}
	end

	return Clickable{
		Active = props.Active,
		ButtonColor = props.ButtonColor,
		Disabled = props.Disabled,
		Mode = props.Mode or "filled",
		Ref = props.Ref,
		layout = {
			MinSize = icon_size,
			MaxSize = icon_size,
			FitWidth = false,
			FitHeight = true,
			Direction = "x",
			AlignmentX = "center",
			AlignmentY = "center",
			props.layout,
		},
		transform = {
			Size = props.Size,
		},
		OnClick = props.OnClick,
		Padding = props.Padding or "none",
	}(children)
end
