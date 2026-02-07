local Vec2 = require("structs.vec2")
local Text = require("ui.elements.text")
local Slider = require("ui.elements.slider")
local Checkbox = require("ui.elements.checkbox")
local RadioButton = require("ui.elements.radio_button")
local Dropdown = require("ui.elements.dropdown")
local Row = require("ui.elements.row")
local Column = require("ui.elements.column")
return {
	Name = "Basic Elements",
	Create = function()
		local canvas = Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 10,
					AlignmentX = "start",
				},
			}
		)
		canvas:AddChild(
			Slider(
				{
					Size = Vec2(400, 50),
					Value = 0.5,
					Min = 0,
					Max = 100,
					OnChange = function(value)
						print("Slider value:", value)
					end,
					layout = {GrowWidth = 1},
				}
			)
		)
		canvas:AddChild(
			Row({
				layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
			})(
				{
					Checkbox(
						{
							Value = true,
							OnChange = function(val)
								print("Checkbox value:", val)
							end,
						}
					),
					Text({Text = "Toggle me"}),
				}
			)
		)
		local selected_radio = 1
		local radio_group = Column({
			layout = {Direction = "y", ChildGap = 5, AlignmentX = "start"},
		})

		for i = 1, 3 do
			radio_group:AddChild(
				Row({
					layout = {Direction = "x", ChildGap = 10, AlignmentY = "center"},
				})(
					{
						RadioButton(
							{
								IsSelected = function()
									return selected_radio == i
								end,
								OnSelect = function()
									print("Radio " .. i .. " selected")
									selected_radio = i
								end,
							}
						),
						Text({Text = "Option " .. i}),
					}
				)
			)
		end

		canvas:AddChild(radio_group)
		local selected_dropdown_val = "Option 1"
		canvas:AddChild(
			Dropdown(
				{
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
				}
			)
		)
		return canvas
	end,
}
