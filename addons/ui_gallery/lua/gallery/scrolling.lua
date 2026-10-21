local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local ROWS = 100
local ITEMS = 30
local GRID_ROWS = 30
local GRID_COLUMNS = 16
local WIDE_ROWS = 60
local WIDE_TEXT = " of a block that is wider than the panel, so both scrollbars show and meet in the corner, with an arrow button at each end of both"

local function draw_cell(item, index, x, y, width, height, selected, hovered)
	local font = fonts.GetDefaultFont()
	theme.active:DrawBoxShape(
		x,
		y,
		width,
		height,
		{
			fill = selected and "primary" or (hovered and "surface_alt" or "surface"),
			outline = "border",
			radius = theme.active:GetRadius("S"),
		}
	)
	render2d.SetColor(theme.active:GetColor(selected and "text_on_accent" or "text"):Unpack())
	font:DrawText(item.name, x + 8, y + height - font:GetLineHeight() - 6)
end

return {
	Name = "scrolling",
	Section = "Containers",
	Order = 2,
	View = react.Component(
		||-> do
			local arrow_buttons, set_arrow_buttons = react.UseState()
			local panels = react.UseRef({})
			local targets = react.UseRef({})
			local grid_items = react.UseMemo(
				||-> do
					local out = {}

					for index = 1, 2000 do
						out[index] = {name = "Item " .. index}
					end

					return out
				end,
				{}
			)

			local function remember(map, key)
				return |entity|-> do
					map.current[key] = entity
				end
			end

			local function jump(text, panel, target)
				return ui.Button{
					Key = text,
					Text = text,
					Mode = "outline",
					OnClick = ||->panels.current[panel]:ScrollChildIntoView(targets.current[target], 8),
				}
			end

			local rows = {}

			for index = 1, ROWS do
				rows[index] = ui.Text{
					Key = index,
					Ref = (
							index == 1 or
							index == 50 or
							index == 100
						)
						and
						remember(targets, "row " .. index) or
						nil,
					Text = "Row " .. index,
					IgnoreMouseInput = true,
				}
			end

			local items = {}

			for index = 1, ITEMS do
				items[index] = ui.Button{
					Key = index,
					Ref = (
							index == 1 or
							index == 15 or
							index == 30
						)
						and
						remember(targets, "item " .. index) or
						nil,
					Text = "Item " .. index,
					Padding = "XS",
				}
			end

			local grid_rows = {}

			for row = 1, GRID_ROWS do
				local cells = {}

				for column = 1, GRID_COLUMNS do
					local corner = (
							row == 1 or
							row == 30
						)
						and
						(
							column == 1 or
							column == 16
						)
						or
						row == 15 and
						column == 8
					cells[column] = ui.Text{
						Key = column,
						Ref = corner and remember(targets, row .. "," .. column) or nil,
						Text = string.format("%02d,%02d", row, column),
						IgnoreMouseInput = true,
					}
				end

				grid_rows[row] = ui.Row{
					Key = row,
					layout = {ChildGap = "M", FitWidth = true, FitHeight = true, GrowWidth = 0},
				}{cells}
			end

			local wide_rows = {}

			for index = 1, WIDE_ROWS do
				wide_rows[index] = ui.Text{Key = index, Text = "Row " .. index .. WIDE_TEXT, IgnoreMouseInput = true}
			end

			return kit.Page{
				Title = "Scrolling",
				Description = "ScrollablePanel clips its children and shows scrollbars as needed. Bars are thin until the mouse is over them, then they grow over the content with a backdrop (in themes that collapse them). ScrollChildIntoView and ScrollRectIntoView drive it from code.",
			}{
				kit.Section{
					Title = "Vertical",
					Description = "Wheel scrolling, draggable scrollbar and programmatic jumps. Clicking the track outside the handle scrolls a page towards the click, and holding repeats. Clicking the panel (or anything inside it that takes no focus itself) focuses it, then the arrow keys scroll a line, Page Up and Page Down a page, Home and End go to the ends (KeyScrolling, on by default). Holding the middle mouse button autoscrolls.",
				}{
					kit.Group{
						jump("First row", "vertical", "row 1"),
						jump("Row 50", "vertical", "row 50"),
						jump("Last row", "vertical", "row 100"),
					},
					ui.ScrollablePanel{
						Ref = remember(panels, "vertical"),
						ScrollbarButtons = arrow_buttons,
						layout = {MinSize = Vec2(0, 160), MaxSize = Vec2(0, 160)},
					}{
						ui.Column{layout = {ChildGap = "XXS", AlignmentX = "start", FitHeight = true}}{rows},
					},
				},
				kit.Section{
					Title = "Horizontal",
					Description = "ScrollX = true with ScrollY = false. Hold Shift while scrolling the wheel on a two axis panel.",
				}{
					kit.Group{
						jump("Start", "horizontal", "item 1"),
						jump("Item 15", "horizontal", "item 15"),
						jump("End", "horizontal", "item 30"),
					},
					ui.ScrollablePanel{
						Ref = remember(panels, "horizontal"),
						ScrollX = true,
						ScrollY = false,
						ScrollbarButtons = arrow_buttons,
						layout = {MinSize = Vec2(0, 56), MaxSize = Vec2(0, 56)},
					}{
						ui.Row{
							layout = {ChildGap = "XS", AlignmentY = "center", FitWidth = true, GrowWidth = 0},
						}{items},
					},
				},
				kit.Section{
					Title = "Vertical and horizontal",
					Description = "ScrollX and ScrollY together show both bars. The wheel scrolls vertically and Shift with the wheel horizontally, the arrow keys move a line. Hold the middle mouse button and move away from where you pressed to autoscroll in any direction, faster the further you go, or click it without moving to keep autoscrolling until the next click or Escape.",
				}{
					kit.Group{
						jump("Top left", "two axis", "1,1"),
						jump("Center", "two axis", "15,8"),
						jump("Top right", "two axis", "1,16"),
						jump("Bottom left", "two axis", "30,1"),
						jump("Bottom right", "two axis", "30,16"),
					},
					ui.ScrollablePanel{
						Ref = remember(panels, "two axis"),
						ScrollX = true,
						ScrollY = true,
						layout = {MinSize = Vec2(0, 200), MaxSize = Vec2(0, 200)},
					}{
						ui.Column{
							layout = {
								ChildGap = "XXS",
								AlignmentX = "start",
								FitWidth = true,
								FitHeight = true,
								GrowWidth = 0,
							},
						}{grid_rows},
					},
				},
				kit.Section{
					Title = "Scrollbar buttons",
					Description = "ScrollbarButtons = true adds an arrow button at each end of a visible scrollbar. A click scrolls one wheel notch and holding repeats. The checkbox switches them on every panel of this page.",
				}{
					kit.Group{ui.Checkbox{Text = "Arrow buttons", Value = true, OnChange = set_arrow_buttons}},
					ui.ScrollablePanel{
						ScrollX = true,
						ScrollY = true,
						ScrollbarButtons = arrow_buttons ?? true,
						layout = {MinSize = Vec2(0, 180), MaxSize = Vec2(0, 180)},
					}{
						ui.Column{
							layout = {
								ChildGap = "XXS",
								AlignmentX = "start",
								FitWidth = true,
								FitHeight = true,
								GrowWidth = 0,
							},
						}{wide_rows},
					},
				},
				kit.Section{
					Title = "Virtual grid",
					Description = "2000 items, only the visible cells are drawn. Click to select, arrow keys to move, Enter or double click to activate.",
				}{
					ui.VirtualGrid{
						Items = grid_items,
						CellWidth = 96,
						ExtraHeight = 24,
						Gap = 8,
						OnDrawItem = draw_cell,
						layout = {MinSize = Vec2(0, 260), MaxSize = Vec2(0, 260)},
					},
				},
			}
		end
	),
}
