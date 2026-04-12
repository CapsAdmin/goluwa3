local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Column = import("../elements/column.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Panel = import("goluwa/ecs/panel.lua")

local ARTICLE = [[
Justified text stretches the spaces on each interior line so the paragraph reaches both edges of the column. It is the same core idea as CSS text-align: justify: break the lines first, then distribute the remaining width across the expandable spaces.

This demo compares the current wrapped text component in ragged mode against the new justified mode. The final line of each paragraph stays ragged, which matches common typography rules.
]]

local function paragraph_card(title, align_x)
	return Panel.New{
		transform = true,
		rect = {
			Color = Color(0.09, 0.11, 0.14, 1),
			Radius = 8,
		},
		layout = {
			GrowWidth = 1,
			FitHeight = true,
		},
	}{
		Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
				Padding = Rect(14, 14, 14, 14),
			},
		}{
			Text{
				Text = title,
				Color = Color(0.62, 0.82, 1.0, 1),
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = ARTICLE,
				Wrap = true,
				AlignX = align_x,
				layout = {
					GrowWidth = 1,
				},
			},
		},
	}
end

return {
	Name = "text justify",
	Create = function()
		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Wrap + justify for plain text. The left column is normal ragged wrapping; the right column stretches interior spaces to fill the width.",
				Wrap = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					Direction = "x",
					GrowWidth = 1,
					FitHeight = true,
					ChildGap = 14,
					AlignmentX = "stretch",
				},
			}{
				paragraph_card("Ragged wrap", "left"),
				paragraph_card("Justified wrap", "justify"),
			},
		}
	end,
}