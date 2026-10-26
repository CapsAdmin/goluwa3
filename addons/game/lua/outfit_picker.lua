local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local pvars = import("goluwa/cli/pvars.lua")
local previews = import("lua/asset_preview.lua")
local outfit = import("lua/outfit.lua")
local outfit_source = import("lua/outfit_source.lua")
local Rect = import("goluwa/structs/rect.lua")
local Window = react.Element(import("goluwa/render2d/ui/widgets/window.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local Checkbox = react.Element(import("goluwa/render2d/ui/elements/checkbox.lua"))
local Slider = react.Element(import("goluwa/render2d/ui/elements/slider.lua"))
local VirtualGrid = react.Element(import("goluwa/render2d/ui/elements/virtual_grid.lua"))
local LABEL_HEIGHT = 24
local picker = {}
local grid_ref

function picker.GetItems()
	outfit.Ensure(outfit.CustomName)
	local items = {
		{label = "Custom", name = outfit.CustomName},
		{label = "Default", name = outfit.DefaultName},
	}

	if outfit_source.IsAvailable() then
		for _, model in ipairs(outfit_source.Models) do
			items[#items + 1] = {
				label = model:match("([^/]+)%.mdl$"),
				name = outfit_source.Name,
				model = model,
				inputs = {Model = model},
			}
		end
	end

	for _, item in ipairs(items) do
		item.category = "prefabs"
	end

	return items
end

function picker.GetSelected(items)
	local name = outfit.GetLocalName()
	local model = pvars.Get("cl_outfit_model")

	for _, item in ipairs(items) do
		if item.name == name and (not item.model or item.model == model) then
			return item
		end
	end
end

function picker.Select(item)
	pvars.Set("cl_outfit", item.name)

	if item.model then pvars.Set("cl_outfit_model", item.model) end
end

local function draw_item(item, index, x, y, w, h, selected, hovered)
	local active = theme.active
	local font = active:GetFont("body", "S")
	local text = active:GetColor("text")
	local surface = active:GetColor("surface_alt")
	render2d.DrawBox(
		x,
		y,
		w,
		h,
		6,
		{r = surface.r, g = surface.g, b = surface.b, a = hovered and 1 or 0.7},
		selected and active:GetColor("primary") or active:GetColor("border"),
		selected and -2 or -1
	)
	local size = w - 8
	render2d.DrawBox(x + 4, y + 4, size, size, 4, {r = 0.2, g = 0.21, b = 0.24, a = 1})
	local preview = previews.Request(item)

	if preview.status == "ready" then previews.Draw(preview, x + 4, y + 4, size, size) end

	local tw, th = font:GetTextSize(item.label)
	render2d.SetTexture(nil)
	render2d.PushColor(text.r, text.g, text.b, 1)
	font:DrawText(item.label, x + (w - tw) / 2, y + h - LABEL_HEIGHT + (LABEL_HEIGHT - th) / 2, 0)
	render2d.PopColor()
end

local Content = react.Component(
	||-> do
		local grid = react.UseRef()
		local items = react.UseMemo(picker.GetItems, {})
		react.UseLayoutEffect(
			||-> do
				grid_ref = grid.current
			end,
			{}
		)
		return Column{
			layout = {GrowWidth = 1, GrowHeight = 1, FitHeight = false, AlignmentX = "stretch", ChildGap = 6},
		}{
			VirtualGrid{
				Ref = grid,
				Items = items,
				SelectedItem = picker.GetSelected(items),
				CellWidth = 128,
				ExtraHeight = LABEL_HEIGHT,
				Gap = 8,
				ContentPadding = 8,
				OnDrawItem = draw_item,
				OnSelect = picker.Select,
				layout = {GrowWidth = 1, GrowHeight = 1},
			},
			Row{layout = {GrowWidth = 1, ChildGap = 10, AlignmentY = "center", Padding = Rect() + 6}}{
				Text{Text = "Near", Color = "text_disabled", layout = {FitWidth = true}},
				Slider{
					Mode = "horizontal",
					Min = 0.001,
					Max = 0.2,
					Value = pvars.Get("cl_outfit_head_near"),
					OnChange = |value|->pvars.Set("cl_outfit_head_near", value),
					Tooltip = pvars.GetObject("cl_outfit_head_near").help,
					layout = {MinSize = Vec2(120, 16), MaxSize = Vec2(120, 16), FitWidth = false},
				},
			},
			Row{layout = {GrowWidth = 1, ChildGap = 10, AlignmentY = "center", Padding = Rect() + 6}}{
				Checkbox{
					Text = "Head camera",
					Value = pvars.Get("cl_outfit_head_camera"),
					OnChange = |value|->pvars.Set("cl_outfit_head_camera", value),
					Tooltip = pvars.GetObject("cl_outfit_head_camera").help,
				},
				Checkbox{
					Text = "Vertical",
					Value = pvars.Get("cl_outfit_head_vertical"),
					OnChange = |value|->pvars.Set("cl_outfit_head_vertical", value),
					Tooltip = pvars.GetObject("cl_outfit_head_vertical").help,
				},
				Text{Text = "Smoothing", Color = "text_disabled", layout = {FitWidth = true}},
				Slider{
					Mode = "horizontal",
					Min = 0,
					Max = 0.5,
					Value = pvars.Get("cl_outfit_head_smoothing"),
					OnChange = |value|->pvars.Set("cl_outfit_head_smoothing", value),
					Tooltip = pvars.GetObject("cl_outfit_head_smoothing").help,
					layout = {MinSize = Vec2(120, 16), MaxSize = Vec2(120, 16), FitWidth = false},
				},
			},
		}
	end
)
local View = react.Component(
	||-> Window{
		Title = "OUTFIT",
		Size = Vec2(500, 460),
		MinSize = Vec2(200, 200),
	}{Content{}}
)

function picker.Create()
	return react.Mount(View{}, Panel.World):GetEntity()
end

function picker.GetGrid()
	return grid_ref
end

function picker.Refresh()
	if grid_ref and grid_ref:IsValid() then
		local items = picker.GetItems()
		grid_ref:SetItems(items)
		grid_ref:SetSelectedItem(picker.GetSelected(items))
	end
end

return picker
