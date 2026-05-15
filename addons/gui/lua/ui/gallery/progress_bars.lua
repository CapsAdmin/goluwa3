local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Text = import("../elements/text.lua")
local ProgressBar = import("../elements/progress_bar.lua")
local Column = import("../elements/column.lua")
local timer = import("goluwa/timer.lua")
local Color = import("goluwa/structs/color.lua")
local theme = import("../theme.lua")
return {
	Name = "progress bars",
	Create = function()
		local canvas = Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 20,
				AlignmentX = "start",
				Padding = Rect(
					theme.GetPadding("M"),
					theme.GetPadding("M"),
					theme.GetPadding("M"),
					theme.GetPadding("M")
				),
			},
		}
		local animated_pb = ProgressBar({Value = 0})
		canvas{
			Text{
				Text = "Static Progress Bars",
				FontName = "heading",
				Size = Vec2() + theme.GetSize("L"),
			},
			Column{layout = {ChildGap = 5}}{
				Text({Text = "Default (25%)"}),
				ProgressBar({Value = 0.25}),
			},
			Column{layout = {ChildGap = 5}}{
				Text({Text = "Orange (50%)"}),
				ProgressBar{Value = 0.5, Color = Color.FromHex("#ff8800")},
			},
			Column{layout = {ChildGap = 5}}{
				Text({Text = "Teal (75%)"}),
				ProgressBar{Value = 0.75, Color = Color.FromHex("#00ffd4")},
			},
			Text{
				Text = "Animated Progress Bar",
				FontName = "heading",
				FontSize = "L",
			},
			animated_pb,
		}
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
