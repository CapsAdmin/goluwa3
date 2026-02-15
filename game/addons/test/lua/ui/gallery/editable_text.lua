local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local ScrollablePanel = require("ui.elements.scrollable_panel")
local Panel = require("ecs.panel")
local Color = require("structs.color")
local theme = require("ui.theme")
return {
	Name = "text edit",
	Create = function()
		return Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 20,
					Padding = Rect() + 20,
					AlignmentX = "start",
				},
			}
		)(
			{
				Text(
					{
						Text = "Below are editable text fields. Click them to focus and type.",
						FontName = "body",
						FontSize = "L",
					}
				),
				-- Single line editable text
				Text(
					{
						Text = "Single line edit",
						Editable = true,
						key_input = {}, -- Required for editing
						mouse_input = {FocusOnClick = true}, -- Required to receive focus
						Background = {
							Color = "surface",
						},
						layout = {
							GrowWidth = 1,
							Padding = Rect() + 5,
						},
					}
				),
				-- Multi line editable text
				Text(
					{
						Text = "Multi-line edit\nTry pressing enter!\nIt preserves indentation too.",
						Editable = true,
						Wrap = true,
						key_input = {},
						mouse_input = {FocusOnClick = true},
						Background = {
							Color = "surface_variant",
						},
						layout = {
							GrowWidth = 1,
							Padding = Rect() + 10,
							FitHeight = false,
							Height = 100,
						},
					}
				),
				-- Text in a box
				Text({Text = "Text edit in a box:", FontName = "heading"}),
				Panel.New(
					{
						ComponentSet = {"rect", "transform", "gui_element", "layout"},
						gui_element = {
							Color = Color(0.15, 0.15, 0.15, 1),
							BorderRadius = 8,
						},
						layout = {
							Padding = Rect() + 15,
							FitWidth = true,
							FitHeight = true,
						},
					}
				)(
					{
						Text(
							{
								Text = "Editable text inside a Panel with a background rect and border radius.",
								Editable = true,
								Wrap = true,
								key_input = {},
								mouse_input = {FocusOnClick = true},
								layout = {
									Size = Vec2(300, 0),
								},
							}
						),
					}
				),
				-- Scrollable panel
				Text({Text = "Text edit in a scrollable panel:", FontName = "heading"}),
				ScrollablePanel(
					{
						Color = Color(0.15, 0.15, 0.15, 1),
						layout = {
							MinSize = Vec2(400, 150),
							MaxSize = Vec2(400, 150),
						},
					}
				)(
					{
						Text(
							{
								Text = "This text is inside a scrollable panel.\n\nYou can type here, select text, and use the mouse wheel to scroll.\n\n" .. (
										"Extra line for scrolling...\n"
									):rep(15) .. "Reached the bottom!",
								Editable = true,
								Wrap = true,
								Color = Color(1, 1, 1, 1),
								layout = {
									GrowWidth = 1,
									Padding = Rect() + 10,
								},
							}
						),
					}
				),
				-- Styled editable text
				Text(
					{
						Text = "Red editable text",
						Editable = true,
						key_input = {},
						mouse_input = {FocusOnClick = true},
						Color = "error",
						FontName = "heading",
						FontSize = "M",
						layout = {
							GrowWidth = 1,
						},
					}
				),
			}
		)
	end,
}
