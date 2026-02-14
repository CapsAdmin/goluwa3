local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Text = require("ui.elements.text")
local ProgressBar = require("ui.elements.progress_bar")
local Column = require("ui.elements.column")
local timer = require("timer")
local Color = require("structs.color")
local theme = require("ui.theme")
return {
	Name = "Progress Bars",
	Create = function()
		local canvas = Column(
			{
				layout = {
					Direction = "y",
					FitHeight = true,
					GrowWidth = 1,
					ChildGap = 20,
					AlignmentX = "start",
				},
			}
		)
		canvas.layout:SetPadding(
			Rect(
				theme.GetPadding("M"),
				theme.GetPadding("M"),
				theme.GetPadding("M"),
				theme.GetPadding("M")
			)
		)
		canvas:AddChild(
			Text(
				{
					Text = "Static Progress Bars",
					FontName = "heading",
					Size = Vec2() + theme.GetSize("L"),
				}
			)
		)
		canvas:AddChild(
			Column({layout = {ChildGap = 5}})({
				Text({Text = "Default (25%)"}),
				ProgressBar({Value = 0.25}),
			})
		)
		canvas:AddChild(
			Column({layout = {ChildGap = 5}})(
				{
					Text({Text = "Orange (50%)"}),
					ProgressBar({Value = 0.5, Color = Color.FromHex("#ff8800")}),
				}
			)
		)
		canvas:AddChild(
			Column({layout = {ChildGap = 5}})(
				{
					Text({Text = "Teal (75%)"}),
					ProgressBar({Value = 0.75, Color = Color.FromHex("#00ffd4")}),
				}
			)
		)
		canvas:AddChild(
			Text(
				{
					Text = "Animated Progress Bar",
					FontName = "heading",
					FontSize = "L",
				}
			)
		)
		local animated_pb = ProgressBar({Value = 0})
		canvas:AddChild(animated_pb)
		local t = 0

		timer.Repeat(
			"gallery_pb_anim",
			0.01,
			0,
			function()
				if not animated_pb:IsValid() then
					timer.RemoveTimer("gallery_pb_anim")
					return
				end

				t = (t + 0.005) % 1
				animated_pb:SetValue(t)
			end
		)

		return canvas
	end,
}
