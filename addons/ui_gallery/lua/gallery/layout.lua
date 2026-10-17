local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local Swatch = react.Element(import("addons/ui_gallery/lua/gallery_swatch.lua"))
local alignments = {
	{Text = "Start", Value = "start"},
	{Text = "Center", Value = "center"},
	{Text = "End", Value = "end"},
	{Text = "Stretch", Value = "stretch"},
	{Text = "Space between", Value = "space_between"},
	{Text = "Space around", Value = "space_around"},
	{Text = "Space evenly", Value = "space_evenly"},
}
local cross_alignments = {
	{Text = "Start", Value = "start"},
	{Text = "Center", Value = "center"},
	{Text = "End", Value = "end"},
}
local directions = {
	{Text = "Row (x)", Value = "x"},
	{Text = "Column (y)", Value = "y"},
}
local tokens = {"primary", "positive", "neutral", "negative", "text_disabled", "border_strong"}

local function draw_demo_box(self)
	theme.active:DrawBox(
		self.Owner.transform:GetSize(),
		{fill = self.Owner.Token, radius = theme.active:GetRadius("S")}
	)
end

local function demo_box(token, text, layout)
	return ui.Panel{Key = text .. token, Token = token, transform = true, layout = layout, visual = {OnDraw = draw_demo_box}}{
		ui.Text{Text = text, Color = "text_on_accent", Font = "body_strong S", IgnoreMouseInput = true},
	}
end

return {
	Name = "layout",
	Section = "Layout",
	Order = 1,
	View = react.Component(|| -> do
		local count, set_count = react.UseState(14)
		local size, set_size = react.UseState(56)
		local gap, set_gap = react.UseState(10)
		local direction, set_direction = react.UseState("x")
		local main, set_main = react.UseState("start")
		local cross, set_cross = react.UseState("start")
		local wrap, set_wrap = react.UseState(true)
		local is_row = direction == "x"
		local tiles = {}

		for index = 1, count do
			local tile_size = size + (index % 3) * 8

			-- Size is turned into the min and max size when a swatch is made, a new size needs a new swatch
			tiles[index] = Swatch{
				Key = index .. " " .. tile_size,
				Token = tokens[index % #tokens + 1],
				Size = Vec2(tile_size, tile_size),
			}
		end

		return kit.Page{
			Title = "Layout",
			Description = "Every panel with a layout component is a flex container: direction, alignment, gap, padding, grow, fit and wrapping.",
		}{
			kit.Section{
				Title = "Playground",
				Description = "Tiles differ slightly in size so cross-axis alignment is visible.",
			}{
				ui.Column{layout = {ChildGap = "S", AlignmentX = "stretch"}}{
					kit.SliderRow{Label = "Items", Min = 1, Max = 60, Value = 14, Suffix = "", OnChange = set_count},
					kit.SliderRow{Label = "Size", Min = 24, Max = 120, Value = 56, Suffix = " px", OnChange = set_size},
					kit.SliderRow{Label = "Gap", Min = 0, Max = 32, Value = 10, Suffix = " px", OnChange = set_gap},
					kit.Group(
						{
							kit.Labeled(
								"Direction",
								ui.Dropdown{
									Options = directions,
									Value = "x",
									Padding = "XS",
									OnSelect = set_direction,
									layout = {MinSize = Vec2(140, 0), MaxSize = Vec2(140, 0), GrowWidth = 0},
								}
							),
							kit.Labeled(
								"Main axis",
								ui.Dropdown{
									Options = alignments,
									Value = "start",
									Padding = "XS",
									OnSelect = set_main,
									layout = {MinSize = Vec2(160, 0), MaxSize = Vec2(160, 0), GrowWidth = 0},
								}
							),
							kit.Labeled(
								"Cross axis",
								ui.Dropdown{
									Options = cross_alignments,
									Value = "start",
									Padding = "XS",
									OnSelect = set_cross,
									layout = {MinSize = Vec2(120, 0), MaxSize = Vec2(120, 0), GrowWidth = 0},
								}
							),
							kit.Labeled("Wrap", ui.Checkbox{Value = true, OnChange = set_wrap}),
						},
						{AlignmentY = "end"}
					),
					ui.Frame{Padding = "S", layout = {GrowWidth = 1, FitHeight = true}}{
						ui.Row{
							layout = {
								GrowWidth = 1,
								FitHeight = true,
								Direction = direction,
								WrapChildren = wrap,
								AlignmentX = is_row and main or cross,
								AlignmentY = is_row and cross or main,
								ChildGap = gap,
							},
						}{tiles},
					},
				},
			},
			kit.Section{
				Title = "Grow ratios",
				Description = "GrowWidth distributes the remaining space between children by weight.",
			}{
				ui.Row{
					layout = {
						ChildGap = "S",
						GrowWidth = 1,
						FitHeight = false,
						AlignmentY = "stretch",
						MinSize = Vec2(0, 48),
						MaxSize = Vec2(0, 48),
					},
				}{
					demo_box("primary", "1", {GrowWidth = 1, AlignmentX = "center", AlignmentY = "center"}),
					demo_box("positive", "2", {GrowWidth = 2, AlignmentX = "center", AlignmentY = "center"}),
					demo_box("negative", "1", {GrowWidth = 1, AlignmentX = "center", AlignmentY = "center"}),
					demo_box(
						"neutral",
						"fixed",
						{MinSize = Vec2(80, 0), MaxSize = Vec2(80, 0), AlignmentX = "center", AlignmentY = "center"}
					),
				},
			},
			kit.Section{
				Title = "Fit to content",
				Description = "FitWidth and FitHeight size a panel to its children plus padding.",
			}{
				kit.Group{
					ui.Frame{Padding = "S", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{
						ui.Text{Text = "Fits its text", IgnoreMouseInput = true},
					},
					ui.Frame{Padding = "L", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{
						ui.Text{Text = "Larger padding", IgnoreMouseInput = true},
					},
					ui.Frame{Padding = "XS", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{
						ui.Text{Text = "Tight", IgnoreMouseInput = true},
					},
				},
			},
		}
	end),
}
