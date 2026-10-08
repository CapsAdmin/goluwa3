local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local system = import("goluwa/system.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function elapsed_tooltip()
	return string.format("Tooltip text can be computed: %.1f seconds since start", system.GetElapsedTime())
end

return {
	Name = "tooltips",
	Section = "Overlays",
	Order = 3,
	Create = function()
		return kit.Page{
			Title = "Tooltips",
			Description = "Any panel accepts a Tooltip. Hover for about a second and it follows the cursor, staying inside the window.",
		}{
			kit.Section{Title = "Static and dynamic"}{
				kit.Group{
					Button{Text = "Static text", Tooltip = "A plain tooltip"},
					Button{Text = "Computed text", Mode = "outline", Tooltip = elapsed_tooltip},
					Button{Text = "Wrapped", Mode = "outline", Tooltip = kit.Lorem, TooltipMaxWidth = 240},
					Button{
						Text = "Instant",
						Mode = "outline",
						Tooltip = "Delay = 0",
						TooltipOptions = {Delay = 0},
					},
				},
			},
			kit.Section{Title = "On any element"}{
				Frame{
					Padding = "L",
					Tooltip = "Frames and every other panel can have tooltips too",
					layout = {GrowWidth = 1, FitHeight = true},
				}{
					Text{Text = "Hover this frame", Color = "text_disabled", IgnoreMouseInput = true},
				},
			},
		}
	end,
}
