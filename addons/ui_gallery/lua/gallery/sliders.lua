local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local ProgressBar = import("goluwa/render2d/ui/elements/progress_bar.lua")
local StepNumberValue = import("goluwa/render2d/ui/widgets/step_number_value.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local timer = import("goluwa/timer.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function on_slider_change(value, slider)
	slider.Readout.text:SetText(string.format("%s = %.2f", slider.Label, value))
end

local function on_plane_change(value, slider)
	slider.Readout.text:SetText(string.format("x = %.2f, y = %.2f", value.x, value.y))
end

local function on_step_change(value, old_value, control)
	control.Readout.text:SetText("value = " .. value)
end

return {
	Name = "sliders",
	Section = "Controls",
	Order = 3,
	Create = function()
		local horizontal_readout = Text{Text = "volume = 0.40", Color = "text_disabled", IgnoreMouseInput = true}
		local vertical_readout = Text{Text = "gain = 0.70", Color = "text_disabled", IgnoreMouseInput = true}
		local plane_readout = Text{Text = "x = 0.50, y = 0.50", Color = "text_disabled", IgnoreMouseInput = true}
		local step_readout = Text{Text = "value = 5", Color = "text_disabled", IgnoreMouseInput = true}
		local animated = ProgressBar{Value = 0}
		local progress = 0

		timer.Repeat(
			"gallery_progress_animation",
			0.016,
			0,
			function()
				if not animated:IsValid() then
					timer.RemoveTimer("gallery_progress_animation")
					return
				end

				progress = (progress + 0.004) % 1
				animated:SetValue(progress)
			end
		)

		return kit.Page{
			Title = "Sliders and progress",
			Description = "Continuous values: sliders in three modes, progress bars and a stepped number field.",
		}{
			kit.Section{
				Title = "Horizontal and vertical",
				Description = "Mode = horizontal | vertical. Min and Max default to 0 and 1.",
			}{
				kit.Group(
					{
						Column{layout = {ChildGap = "XS", GrowWidth = 1, AlignmentX = "stretch"}}{
							Slider{
								Value = 0.4,
								Label = "volume",
								Readout = horizontal_readout,
								OnChange = on_slider_change,
								layout = {GrowWidth = 1, MinSize = Vec2(200, 16)},
							},
							horizontal_readout,
						},
						Column{
							layout = {ChildGap = "XS", GrowWidth = 0, FitWidth = true, AlignmentX = "start"},
						}{
							Slider{
								Mode = "vertical",
								Value = 0.7,
								Label = "gain",
								Readout = vertical_readout,
								OnChange = on_slider_change,
								layout = {MinSize = Vec2(16, 140)},
							},
							vertical_readout,
						},
					},
					{AlignmentY = "start"}
				),
			},
			kit.Section{
				Title = "Two dimensions",
				Description = "Mode = 2d takes Vec2 Min, Max and Value.",
			}{
				kit.Group{
					Slider{
						Mode = "2d",
						Value = Vec2(0.5, 0.5),
						Readout = plane_readout,
						OnChange = on_plane_change,
						layout = {MinSize = Vec2(220, 160), MaxSize = Vec2(220, 160)},
					},
					plane_readout,
				},
			},
			kit.Section{
				Title = "Progress bars",
				Description = "Value is clamped to 0..1. Color takes a palette token or a Color.",
			}{
				kit.Labeled("25 percent", ProgressBar{Value = 0.25}),
				kit.Labeled("Positive, 50 percent", ProgressBar{Value = 0.5, Color = "positive"}),
				kit.Labeled(
					"Custom color, 75 percent",
					ProgressBar{Value = 0.75, Color = Color.FromHex("#00ffd4")}
				),
				kit.Labeled("Animated", animated),
			},
			kit.Section{
				Title = "Step number value",
				Description = "Drag the field vertically, double click to type, or use the arrows. Hold Alt for fine steps.",
			}{
				kit.Group{
					StepNumberValue{
						Value = 5,
						Min = 0,
						Max = 10,
						Step = 1,
						Precision = 0,
						Readout = step_readout,
						OnChange = on_step_change,
						layout = {GrowWidth = 0},
					},
					step_readout,
				},
			},
		}
	end,
}
