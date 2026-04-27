local Vec2 = import("goluwa/structs/vec2.lua")
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
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Compare an empty single-line field against the existing multiline editor to verify caret behavior outside dropdowns.",
				Wrap = true,
				FontName = "body",
				FontSize = "L",
			},
			Text{
				Text = "Single-line empty",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			TextEdit{
				Text = "",
				Size = Vec2(0, 38),
				MinSize = Vec2(100, 38),
				MaxSize = Vec2(0, 38),
				Wrap = false,
				ScrollY = false,
				ScrollX = false,
				layout = {
					GrowWidth = 1,
				},
			},
			Text{
				Text = "Multiline",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			TextEdit{
				Text = "Edit this text.\n\nThis dedicated element starts editable, sits inside a darker panel, and scrolls when the content grows.\n\n" .. (
						"Add more lines here...\n"
					):rep(1),
				Size = Vec2(0, 180),
				MinSize = Vec2(100, 180),
				MaxSize = Vec2(0, 180),
				Wrap = true,
				ScrollY = true,
				ScrollX = false,
				layout = {
					GrowWidth = 1,
				},
			},
		}
	end,
}
