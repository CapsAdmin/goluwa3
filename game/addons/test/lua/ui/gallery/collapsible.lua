local Vec2 = require("structs.vec2")
local Text = require("ui.elements.text")
local Column = require("ui.elements.column")
local Button = require("ui.elements.button")
local Collapsible = require("ui.elements.collapsible")
return {
	Name = "Collapsible Panels",
	Create = function()
		local canvas = Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 10,
					AlignmentX = "stretch",
				},
			}
		)
		canvas:AddChild(
			Collapsible({
				Title = "Information",
				Collapsed = false,
			})(
				Text(
					{
						Text = "This is a basic collapsible panel. You can put any elements inside it, and it will expand or shrink to fit its content.",
						Wrap = true,
						layout = {
							GrowWidth = 1,
						},
					}
				)
			)
		)
		canvas:AddChild(
			Collapsible({
				Title = "Nested Elements",
				Collapsed = true,
			})(
				Column(
					{
						layout = {
							Direction = "y",
							FitHeight = true,
							GrowWidth = 1,
							ChildGap = 5,
						},
					}
				)(
					{
						Button(
							{
								Text = "Button 1",
								layout = {
									GrowWidth = 1,
								},
							}
						),
						Button(
							{
								Text = "Button 2",
								layout = {
									GrowWidth = 1,
								},
							}
						),
						Collapsible({
							Title = "Sub-Collapsible",
							Collapsed = true,
						})(Text({Text = "Nested content depth 2"})),
					}
				)
			)
		)
		canvas:AddChild(
			Collapsible({
				Title = "Long Content",
				Collapsed = true,
			})(
				Text(
					{
						Text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
						Wrap = true,
						layout = {
							GrowWidth = 1,
						},
					}
				)
			)
		)
		return canvas
	end,
}
