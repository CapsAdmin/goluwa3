local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local ScrollablePanel = require("ui.elements.scrollable_panel")
local Panel = require("ecs.panel")
local Color = require("structs.color")
local theme = require("ui.theme")
return {
	Name = "Editable Text",
	Create = function()
		local canvas = Column(
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
		)
		canvas:AddChild(
			Text(
				{
					Text = "Below are editable text fields. Click them to focus and type.",
					FontName = "body",
					FontSize = "L",
				}
			)
		)
		-- Single line editable text
		canvas:AddChild(
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
			)
		)
		-- Multi line editable text
		canvas:AddChild(
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
			)
		)
		-- Text in a box
		canvas:AddChild(Text({Text = "Text edit in a box:", FontName = "heading"}))
		local box = Panel.New(
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
		)
		box:AddChild(
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
			)
		)
		canvas:AddChild(box)
		-- Scrollable panel
		canvas:AddChild(Text({Text = "Text edit in a scrollable panel:", FontName = "heading"}))
		local scroll_container = ScrollablePanel(
			{
				Color = Color(0.15, 0.15, 0.15, 1),
				layout = {
					MinSize = Vec2(400, 150),
					MaxSize = Vec2(400, 150),
				},
			}
		)
		scroll_container:AddChild(
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
			)
		)
		canvas:AddChild(scroll_container)
		-- Styled editable text
		canvas:AddChild(
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
			)
		)
		return canvas
	end,
}
