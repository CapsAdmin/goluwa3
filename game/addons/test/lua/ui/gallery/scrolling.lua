local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local MenuButton = require("ui.elements.menu_button")
local ScrollablePanel = require("ui.elements.scrollable_panel")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
return {
	Name = "Scrolling Demo",
	Create = function()
		return ScrollablePanel(
			{
				Color = Color(0, 0, 0, 0.5),
				layout = {
					MinSize = Vec2(128, 128),
					MaxSize = Vec2(128, 128),
				},
			}
		)(
			Column(
				{
					layout = {
						Direction = "y",
						FitHeight = true,
						ChildGap = 5,
						AlignmentX = "start",
						GrowWidth = 1,
					},
				}
			)(
				{
					MenuButton({Text = "Clickable Item", Padding = "XS"}),
					Text({Text = "Scrollable Content Demo - 100 Items Below"}),
					(
						function()
							local t = {}

							for i = 1, 100 do
								t[i] = Text({Text = "Scrolling Item #" .. i})
							end

							return t
						end
					)(),
					Text({Text = "End of List"}),
				}
			)
		)
	end,
}
