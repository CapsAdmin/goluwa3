local Vec2 = import("goluwa/structs/vec2.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local RadioButton = import("goluwa/render2d/ui/elements/radio_button.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
return {
	Name = "misc",
	Create = function()
		local canvas = Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "start",
			},
		}
		local selected_radio = 1
		local selected_dropdown_val = "Option 1"
		return canvas{
			Slider{
				Value = 50,
				Min = 0,
				Max = 100,
				OnChange = function(value)
					print("Slider value:", value)
				end,
				layout = {
					Direction = "x",
					AlignmentY = "center",
					FitHeight = true,
					GrowWidth = 1,
				},
			},
			Button{
				Size = Vec2(30, 30),
				Mode = "filled",
				layout = {
					Direction = "x",
					AlignmentY = "center",
					FitHeight = true,
					GrowWidth = 1,
				},
			}{
				Text{Text = "Text Button", IgnoreMouseInput = true},
			},
			Button{
				Size = Vec2(30, 30),
				Mode = "outline",
				layout = {
					Direction = "x",
					AlignmentY = "center",
					FitHeight = true,
					GrowWidth = 1,
				},
			}{
				Text{Text = "Outline Button", IgnoreMouseInput = true},
			},
			Row{
				layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
			}{
				Checkbox{
					Value = true,
					OnChange = function(val)
						print("Checkbox value:", val)
					end,
				},
				Text({Text = "Toggle me"}),
			},
			Column{
				layout = {Direction = "y", ChildGap = 5, AlignmentX = "start"},
			}(
				(
					function()
						local t = {}

						for i = 1, 3 do
							t[i] = Row{
								layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
							}{
								RadioButton{
									IsSelected = function()
										return selected_radio == i
									end,
									OnSelect = function()
										print("Radio " .. i .. " selected")
										selected_radio = i
									end,
								},
								Text({Text = "Option " .. i}),
							}
						end

						return t
					end
				)()
			),
			Dropdown{
				Text = "Select Option",
				Options = {"Option 1", "Option 2", "Option 3", "Option 4"},
				OnSelect = function(val)
					print("Dropdown selected:", val)
					selected_dropdown_val = val
				end,
				GetText = function()
					return "Selected: " .. selected_dropdown_val
				end,
				layout = {GrowWidth = 1},
			},
		}
	end,
}
