local Button = import("../elements/button.lua")
local Checkbox = import("../elements/checkbox.lua")
local Column = import("../elements/column.lua")
local Dropdown = import("../elements/dropdown.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")

return {
	Name = "buttons",
	Create = function()
		local state = {
			align_x = "left",
			fit_to_text = false,
			fill_width = true,
			mode = "filled",
		}
		local preview_host

		local function build_preview_button(label)
			local fit_to_text = state.fit_to_text
			local fill_width = state.fill_width and not fit_to_text

			return Button{
				Text = label,
				Mode = state.mode,
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
			preview_host:AddChild(build_preview_button("Primary Action"))
			preview_host:AddChild(build_preview_button("A much longer button label"))

			if preview_host.layout then
				preview_host.layout:InvalidateLayout(true)
			end
		end

		return Column{
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
				Text = "Text Alignment",
				IgnoreMouseInput = true,
			},
			Dropdown{
				Text = "Left",
				Options = {
					{Text = "Left", Value = "left"},
					{Text = "Center", Value = "center"},
					{Text = "Right", Value = "right"},
				},
				GetText = function()
					return state.align_x:gsub("^%l", string.upper)
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
				Options = {
					{Text = "Filled", Value = "filled"},
					{Text = "Outline", Value = "outline"},
				},
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
		}
	end,
}