local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Collapsible = import("../elements/collapsible.lua")
local Clickable = import("../elements/clickable.lua")
local Text = import("../elements/text.lua")
local theme = import("../theme.lua")
return function(props)
	local container
	return Collapsible{
		Ref = function(panel)
			container = panel
		end,
		Header = Clickable{
			IsInternal = true,
			Name = "Header",
			Tooltip = props.Tooltip,
			TooltipOptions = props.TooltipOptions,
			TooltipMaxWidth = props.TooltipMaxWidth,
			TooltipOffset = props.TooltipOffset,
			Mode = props.HeaderMode or "outline",
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				MinSize = props.HeaderHeight and Vec2(0, props.HeaderHeight) or nil,
				MaxSize = props.HeaderHeight and Vec2(0, props.HeaderHeight) or nil,
				Padding = props.HeaderPadding or "M",
				ChildGap = props.HeaderGap or "M",
			},
			OnClick = function(self)
				container:ToggleCollapsed()
			end,
		}{
			Panel.New{
				IsInternal = true,
				Name = "ArrowContainer",
				style = true,
				transform = {
					Size = Vec2() + theme.GetFontSize(props.HeaderFontSize or "M"),
				},
				gui_element = {
					OnDraw = function(self)
						local background = self.Owner.style and self.Owner.style:GetResolvedBackgroundColor()
						local open_fraction = container and container:IsValid() and container:GetOpenFraction() or 0
						theme.active:DrawIcon(
							"disclosure",
							self.Owner.transform:GetSize(),
							{
								thickness = 2,
								open_fraction = open_fraction,
								color = theme.GetColorOn(props.HeaderTextColor or "text", background),
							}
						)
					end,
				},
				mouse_input = {
					Cursor = "pointer",
					IgnoreMouseInput = true,
				},
			},
			Text{
				Text = props.Title or "Collapsible",
				Color = props.HeaderTextColor or "text",
				FontName = props.HeaderFontName or "body",
				FontSize = props.HeaderFontSize or "M",
				layout = {
					GrowWidth = 1,
					FitHeight = true,
				},
				mouse_input = {
					IgnoreMouseInput = true,
				},
			},
		},
	}
end
