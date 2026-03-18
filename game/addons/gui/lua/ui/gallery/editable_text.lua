local Rect = import("goluwa/structs/rect.lua")
local Text = import("../elements/text.lua")
local Column = import("../elements/column.lua")
local TextEdit = import("../elements/text_edit.lua")
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
