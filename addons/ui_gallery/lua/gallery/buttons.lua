local Button = import("goluwa/render2d/ui/widgets/button.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
return {
	Name = "buttons",
	Create = function()
		local state = {
			align_x = 0,
			fit_to_text = false,
			fill_width = true,
			mode = "filled",
		}
		local preview_host
		local color_variants = {
			{label = "Primary Action", color = nil},
			{label = "Positive Action", color = "positive"},
			{label = "Caution Action", color = "neutral"},
			{label = "Destructive Action", color = "negative"},
			{
				label = "Inverted Surface",
				color = "surface_tile_1",
				text_color = "text_on_dark",
			},
		}

		local function build_preview_button(label, button_color, text_color)
			local fit_to_text = state.fit_to_text
			local fill_width = state.fill_width and not fit_to_text
			return Button{
				Text = label,
				ButtonColor = button_color,
				Mode = state.mode,
				TextColor = text_color,
				layout = {
					GrowWidth = fill_width and 1 or 0,
					FitWidth = fit_to_text,
				},
				TextLayout = {
					GrowWidth = fill_width and 1 or 0,
					FitWidth = fit_to_text,
				},
				AlignX = state.align_x,
			}
		end

		local function rebuild_preview()
			if not preview_host or not preview_host:IsValid() then return end

			preview_host:RemoveChildren()

			for _, variant in ipairs(color_variants) do
				preview_host:AddChild(build_preview_button(variant.label, variant.color, variant.text_color))
			end

			preview_host:AddChild(build_preview_button("A much longer button label", "primary"))

			if preview_host.layout then preview_host.layout:InvalidateLayout(true) end
		end

		local pnl = Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Button Editor",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Use these controls to preview button sizing and label alignment.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = "Text X Alignment",
				IgnoreMouseInput = true,
			},
			Dropdown{
				Text = "Left",
				Value = state.align_x,
				Options = {
					{Text = "0", Value = 0},
					{Text = "0.5", Value = 0.5},
					{Text = "1", Value = 1},
				},
				GetValue = function()
					return state.align_x
				end,
				GetText = function()
					return tostring(state.align_x)
				end,
				OnSelect = function(value)
					state.align_x = value
					rebuild_preview()
				end,
				layout = {
					GrowWidth = 1,
				},
				Padding = "XS",
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
				},
			}{
				Checkbox{
					Value = state.fill_width,
					OnChange = function(value)
						state.fill_width = value
						rebuild_preview()
					end,
				},
				Text{
					Text = "Fill Width",
					IgnoreMouseInput = true,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
				},
			}{
				Checkbox{
					Value = state.fit_to_text,
					OnChange = function(value)
						state.fit_to_text = value
						rebuild_preview()
					end,
				},
				Text{
					Text = "Fit To Text",
					IgnoreMouseInput = true,
				},
			},
			Text{
				Text = "Mode",
				IgnoreMouseInput = true,
			},
			Dropdown{
				Text = "Filled",
				Value = state.mode,
				Options = {
					{Text = "Filled", Value = "filled"},
					{Text = "Outline", Value = "outline"},
					{Text = "Text", Value = "text"},
					{Text = "Menu", Value = "menu"},
				},
				GetValue = function()
					return state.mode
				end,
				GetText = function()
					return state.mode == "outline" and "Outline" or "Filled"
				end,
				OnSelect = function(value)
					state.mode = value
					rebuild_preview()
				end,
				layout = {
					GrowWidth = 1,
				},
				Padding = "XS",
			},
			Text{
				Text = "Preview",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Column{
				Ref = function(self)
					preview_host = self
					rebuild_preview()
				end,
				layout = {
					GrowWidth = 1,
					FitHeight = true,
					AlignmentX = "stretch",
					ChildGap = 10,
				},
			}{},
			Text{
				Text = "Icon Buttons",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Compact buttons that display text or SVG icons. Supports all button modes and colors.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = "Text Icon Buttons",
				IgnoreMouseInput = true,
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				IconButton{
					Text = "+",
					FontSize = "L",
					Mode = "filled",
				},
				IconButton{
					Text = "×",
					FontSize = "L",
					Mode = "filled",
					ButtonColor = "negative",
				},
				IconButton{
					Text = "↗",
					FontSize = "XL",
					Mode = "outline",
				},
				IconButton{
					Text = "…",
					FontSize = "L",
					Mode = "text",
				},
				IconButton{
					Text = "Aa",
					FontSize = "M",
					Mode = "filled",
					ButtonColor = "positive",
				},
			},
			Text{
				Text = "SVG Icon Buttons",
				IgnoreMouseInput = true,
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/add-rounded.svg",
					Mode = "filled",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/delete-rounded.svg",
					Mode = "filled",
					ButtonColor = "negative",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/edit-rounded.svg",
					Mode = "outline",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/settings-rounded.svg",
					Mode = "filled",
					ButtonColor = "neutral",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/favorite-rounded.svg",
					Mode = "text",
					ButtonColor = "positive",
					TextColor = "positive",
				},
			},
			Text{
				Text = "Sizes",
				IgnoreMouseInput = true,
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
					IconSize = "S",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
					IconSize = "M",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
					IconSize = "L",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
					IconSize = "XL",
				},
				IconButton{
					SVG = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
					IconSize = "XXL",
				},
			},
		}
		rebuild_preview()
		return pnl
	end,
}
