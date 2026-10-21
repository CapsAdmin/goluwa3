local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local AnimatedProgress = react.Component(
	||-> do
		local progress, set_progress = react.UseState(0)
		react.UseEvent("Update", |dt|->set_progress(|value|->(value + dt * 0.25) % 1))
		return ui.ProgressBar{Value = progress}
	end
)

local function readout(text)
	return ui.Text{Text = text, Color = "text_disabled", IgnoreMouseInput = true}
end

return {
	Name = "sliders",
	Section = "Controls",
	Order = 3,
	View = react.Component(
		||-> do
			local volume, set_volume = react.UseState(0.4)
			local gain, set_gain = react.UseState(0.7)
			local plane, set_plane = react.UseState(Vec2(0.5, 0.5))
			local step, set_step = react.UseState(5)
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
							ui.Column{layout = {ChildGap = "XS", GrowWidth = 1, AlignmentX = "stretch"}}{
								ui.Slider{
									Value = 0.4,
									OnChange = set_volume,
									layout = {GrowWidth = 1, MinSize = Vec2(200, 16)},
								},
								readout(string.format("volume = %.2f", volume)),
							},
							ui.Column{
								layout = {ChildGap = "XS", GrowWidth = 0, FitWidth = true, AlignmentX = "start"},
							}{
								ui.Slider{
									Mode = "vertical",
									Value = 0.7,
									OnChange = set_gain,
									layout = {MinSize = Vec2(16, 140)},
								},
								readout(string.format("gain = %.2f", gain)),
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
						ui.Slider{
							Mode = "2d",
							Value = Vec2(0.5, 0.5),
							OnChange = set_plane,
							layout = {MinSize = Vec2(220, 160), MaxSize = Vec2(220, 160)},
						},
						readout(string.format("x = %.2f, y = %.2f", plane.x, plane.y)),
					},
				},
				kit.Section{
					Title = "Progress bars",
					Description = "Value is clamped to 0..1. Color takes a palette token or a Color.",
				}{
					kit.Labeled("25 percent", ui.ProgressBar{Value = 0.25}),
					kit.Labeled("Positive, 50 percent", ui.ProgressBar{Value = 0.5, Color = "positive"}),
					kit.Labeled(
						"Custom color, 75 percent",
						ui.ProgressBar{Value = 0.75, Color = Color.FromHex("#00ffd4")}
					),
					kit.Labeled("Animated", AnimatedProgress{}),
				},
				kit.Section{
					Title = "Step number value",
					Description = "Drag the field vertically, double click to type, or use the arrows. Hold Alt for fine steps.",
				}{
					kit.Group{
						ui.StepNumberValue{
							Value = 5,
							Min = 0,
							Max = 10,
							Step = 1,
							Precision = 0,
							OnChange = |value|->set_step(value),
							layout = {GrowWidth = 0},
						},
						readout("value = " .. step),
					},
				},
			}
		end
	),
}
