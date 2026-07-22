local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Collapsible = import("../elements/collapsible.lua")
local Clickable = import("../elements/clickable.lua")
local Text = import("../elements/text.lua")
local theme = import("../theme.lua")
return function(props)
	local container
	return Collapsible{
		Ref = function(panel)
			container = panel

			if props.Ref then props.Ref(panel) end
		end,
		Header = Clickable{
			IsInternal = true,
			Tooltip = props.Tooltip,
			TooltipOptions = props.TooltipOptions,
			TooltipMaxWidth = props.TooltipMaxWidth,
			TooltipOffset = props.TooltipOffset,
			ButtonColor = props.HeaderButtonColor,
			Mode = props.HeaderMode or "outline",
			layout = {
				Direction = "x",
				AlignmentY = "center",
				FitHeight = true,
				MinSize = props.HeaderHeight and Vec2(0, props.HeaderHeight) or nil,
				MaxSize = props.HeaderHeight and Vec2(0, props.HeaderHeight) or nil,
				Padding = props.HeaderPadding or "S",
				ChildGap = props.HeaderGap or "M",
			},
			OnClick = function(self)
				container:SetCollapsed(not container:GetCollapsed())
				return true
			end,
		}{
			Panel.New{
				IsInternal = true,
				Name = "ArrowContainer",
				style = true,
				transform = {
					Size = Vec2() + theme.active:ResolveFontSize(props.HeaderFontSize or "M"),
				},
				visual = {
					OnDraw = function(self)
						theme.active:DrawIcon(
							"disclosure",
							self.Owner.transform:GetSize(),
							{
								thickness = 2,
								open_fraction = container:GetOpenFraction(),
								color = theme.active:ResolveColor(props.HeaderTextColor or "text", self.Owner.style:GetResolvedBackgroundColor()),
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
