local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local VirtualGrid = import("goluwa/render2d/ui/elements/virtual_grid.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function jump(button)
	button.ScrollPanel:ScrollChildIntoView(button.ScrollTarget, 8)
end

local function jump_button(text, scroll, target)
	return Button{
		Text = text,
		Mode = "outline",
		ScrollPanel = scroll,
		ScrollTarget = target,
		OnClick = jump,
	}
end

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
	Create = function()
		local rows = {}

		for index = 1, 100 do
			rows[index] = Text{Text = "Row " .. index, IgnoreMouseInput = true}
		end

		local vertical = ScrollablePanel{
			layout = {MinSize = Vec2(0, 160), MaxSize = Vec2(0, 160)},
		}{
			Column{layout = {ChildGap = "XXS", AlignmentX = "start", FitHeight = true}}(rows),
		}
		local items = {}
		local targets = {}

		for index = 1, 30 do
			items[index] = Button{Text = "Item " .. index, Padding = "XS"}
			targets[index] = items[index]
		end

		local horizontal = ScrollablePanel{
			ScrollX = true,
			ScrollY = false,
			layout = {MinSize = Vec2(0, 56), MaxSize = Vec2(0, 56)},
		}{
			Row{
				layout = {ChildGap = "XS", AlignmentY = "center", FitWidth = true, GrowWidth = 0},
			}(items),
		}
		local grid_items = {}

		for index = 1, 2000 do
			grid_items[index] = {name = "Item " .. index}
		end

		local grid = VirtualGrid{
			Items = grid_items,
			CellWidth = 96,
			ExtraHeight = 24,
			Gap = 8,
			OnDrawItem = draw_cell,
			layout = {MinSize = Vec2(0, 260), MaxSize = Vec2(0, 260)},
		}
		return kit.Page{
			Title = "Scrolling",
			Description = "ScrollablePanel clips its children and shows scrollbars as needed. ScrollChildIntoView and ScrollRectIntoView drive it from code.",
		}{
			kit.Section{
				Title = "Vertical",
				Description = "Wheel scrolling, draggable scrollbar and programmatic jumps.",
			}{
				kit.Group{
					jump_button("First row", vertical, rows[1]),
					jump_button("Row 50", vertical, rows[50]),
					jump_button("Last row", vertical, rows[100]),
				},
				vertical,
			},
			kit.Section{
				Title = "Horizontal",
				Description = "ScrollX = true with ScrollY = false. Hold Shift while scrolling the wheel on a two axis panel.",
			}{
				kit.Group{
					jump_button("Start", horizontal, items[1]),
					jump_button("Item 15", horizontal, items[15]),
					jump_button("End", horizontal, items[30]),
				},
				horizontal,
			},
			kit.Section{
				Title = "Virtual grid",
				Description = "2000 items, only the visible cells are drawn. Click to select, arrow keys to move, Enter or double click to activate.",
			}{grid},
		}
	end,
}
