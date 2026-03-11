local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local TextEdit = require("ui.elements.text_edit")
return {
	Name = "text edit",
	Create = function()
		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 20,
				Padding = Rect() + 20,
				AlignmentX = "start",
			},
		}{
			Text{
				Text = "A single dedicated text edit element with built-in scrolling.",
				FontName = "body",
				FontSize = "L",
			},
			TextEdit{
				Text = "Edit this text.\n\nThis dedicated element starts editable, sits inside a darker panel, and scrolls when the content grows.\n\n" .. (
						"Add more lines here...\n"
					):rep(1),
				layout = {
					GrowWidth = 1,
				},
			},
		}
	end,
}