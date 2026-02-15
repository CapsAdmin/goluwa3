local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local ScrollablePanel = require("ui.elements.scrollable_panel")
local Panel = require("ecs.panel")
local Color = require("structs.color")
local theme = require("ui.theme")
return {
	Name = "fonts",
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
			list.map(theme.GetFontNames(), function(font_name)
				return Column(
					{
						layout = {
							ChildGap = 5,
							AlignmentX = "start",
						},
					}
				)(
					{
						Text({Text = "Font: " .. font_name, Font = theme.GetFont("heading"), FontSize = "L"}),
						Column(
							{
								layout = {
									ChildGap = 2,
									AlignmentX = "start",
								},
							}
						)(
							list.map(theme.GetFontSizes(), function(size)
								return Text(
									{
										Text = "The quick brown fox jumps over the lazy dog. (" .. size .. ")",
										Font = font_name,
										FontSize = size,
									}
								)
							end)
						),
					}
				)
			end)
		)
	end,
}
