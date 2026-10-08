local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local Swatch = import("addons/ui_gallery/lua/gallery_swatch.lua")
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

local function rebuild_preview(playground)
	local state = playground.PlaygroundState
	local host = playground.Host
	host:RemoveChildren()
	local layout = host.layout
	local is_row = state.direction == "x"
	layout:SetDirection(state.direction)
	layout:SetWrapChildren(state.wrap)
	layout:SetAlignmentX(is_row and state.main or state.cross)
	layout:SetAlignmentY(is_row and state.cross or state.main)
	layout:SetChildGap(state.gap)

	for index = 1, state.count do
		local size = state.size + (index % 3) * 8
		host:AddChild(
			Swatch{
				Token = tokens[index % #tokens + 1],
				Size = Vec2(size, size),
			}
		)
	end

	layout:InvalidateLayout(true)
end

local function set_state(key)
	return function(value, text, index, control)
		local playground = control.Playground
		playground.PlaygroundState[key] = value
		rebuild_preview(playground)
	end
end

local function on_wrap_change(value, checkbox)
	local playground = checkbox.Playground
	playground.PlaygroundState.wrap = value
	rebuild_preview(playground)
end

local on_main = set_state("main")
local on_cross = set_state("cross")
local on_direction = set_state("direction")

local function playground_slider(playground, label, key, min, max, suffix)
	return kit.SliderRow{
		Label = label,
		Min = min,
		Max = max,
		Value = playground.PlaygroundState[key],
		Suffix = suffix,
		OnChange = function(value)
			playground.PlaygroundState[key] = value
			rebuild_preview(playground)
		end,
	}
end

local function demo_box(token, text, layout)
	return Panel.New{
		transform = true,
		layout = layout,
		visual = {
			OnDraw = function(self)
				theme.active:DrawBox(self.Owner.transform:GetSize(), {fill = token, radius = theme.active:GetRadius("S")})
			end,
		},
	}{
		Text{
			Text = text,
			Color = "text_on_accent",
			Font = "body_strong S",
			IgnoreMouseInput = true,
		},
	}
end

return {
	Name = "layout",
	Section = "Layout",
	Order = 1,
	Create = function()
		local playground = Column{
			PlaygroundState = {
				count = 14,
				size = 56,
				gap = 10,
				direction = "x",
				main = "start",
				cross = "start",
				wrap = true,
			},
			layout = {
				ChildGap = "S",
				AlignmentX = "stretch",
			},
		}
		local host = Row{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				WrapChildren = true,
				AlignmentY = "start",
				ChildGap = 10,
			},
		}
		playground.Host = host
		local controls = {
			playground_slider(playground, "Items", "count", 1, 60, ""),
			playground_slider(playground, "Size", "size", 24, 120, " px"),
			playground_slider(playground, "Gap", "gap", 0, 32, " px"),
			kit.Group(
				{
					kit.Labeled(
						"Direction",
						Dropdown{
							Playground = playground,
							Options = directions,
							Value = "x",
							Padding = "XS",
							OnSelect = on_direction,
							layout = {MinSize = Vec2(140, 0), MaxSize = Vec2(140, 0), GrowWidth = 0},
						}
					),
					kit.Labeled(
						"Main axis",
						Dropdown{
							Playground = playground,
							Options = alignments,
							Value = "start",
							Padding = "XS",
							OnSelect = on_main,
							layout = {MinSize = Vec2(160, 0), MaxSize = Vec2(160, 0), GrowWidth = 0},
						}
					),
					kit.Labeled(
						"Cross axis",
						Dropdown{
							Playground = playground,
							Options = cross_alignments,
							Value = "start",
							Padding = "XS",
							OnSelect = on_cross,
							layout = {MinSize = Vec2(120, 0), MaxSize = Vec2(120, 0), GrowWidth = 0},
						}
					),
					kit.Labeled(
						"Wrap",
						Checkbox{Playground = playground, Value = true, OnChange = on_wrap_change}
					),
				},
				{AlignmentY = "end"}
			),
		}
		playground(controls)
		playground:AddChild(Frame{Padding = "S", layout = {GrowWidth = 1, FitHeight = true}}{host})
		rebuild_preview(playground)
		return kit.Page{
			Title = "Layout",
			Description = "Every panel with a layout component is a flex container: direction, alignment, gap, padding, grow, fit and wrapping.",
		}{
			kit.Section{
				Title = "Playground",
				Description = "Tiles differ slightly in size so cross-axis alignment is visible.",
			}{playground},
			kit.Section{
				Title = "Grow ratios",
				Description = "GrowWidth distributes the remaining space between children by weight.",
			}{
				Row{
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
						{
							MinSize = Vec2(80, 0),
							MaxSize = Vec2(80, 0),
							AlignmentX = "center",
							AlignmentY = "center",
						}
					),
				},
			},
			kit.Section{
				Title = "Fit to content",
				Description = "FitWidth and FitHeight size a panel to its children plus padding.",
			}{
				kit.Group{
					Frame{Padding = "S", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{Text{Text = "Fits its text", IgnoreMouseInput = true}},
					Frame{Padding = "L", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{Text{Text = "Larger padding", IgnoreMouseInput = true}},
					Frame{Padding = "XS", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{Text{Text = "Tight", IgnoreMouseInput = true}},
				},
			},
		}
	end,
}
