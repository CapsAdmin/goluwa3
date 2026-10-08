local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local modes = {"filled", "outline", "text", "menu"}
local colors = {
	{label = "primary", token = nil},
	{label = "positive", token = "positive"},
	{label = "neutral", token = "neutral"},
	{label = "negative", token = "negative"},
}
local icons = {
	add = "https://api.iconify.design/material-symbols-light/add-rounded.svg",
	delete = "https://api.iconify.design/material-symbols-light/delete-rounded.svg",
	edit = "https://api.iconify.design/material-symbols-light/edit-rounded.svg",
	settings = "https://api.iconify.design/material-symbols-light/settings-rounded.svg",
	favorite = "https://api.iconify.design/material-symbols-light/favorite-rounded.svg",
	arrow = "https://api.iconify.design/material-symbols-light/arrow-forward-rounded.svg",
}

local function update_counter(button)
	button.Presses = button.Presses + 1
	button:SetText("Pressed " .. button.Presses .. " times")
end

local function rebuild_preview(preview)
	local state = preview.PreviewState
	preview:RemoveChildren()

	for _, color in ipairs(colors) do
		local fill = state.fill
		preview:AddChild(
			Button{
				Text = color.label .. " action",
				Mode = state.mode,
				ButtonColor = color.token,
				AlignX = state.align_x,
				layout = {
					GrowWidth = fill and 1 or 0,
					FitWidth = not fill,
				},
				TextLayout = {
					GrowWidth = fill and 1 or 0,
					FitWidth = not fill,
				},
			}
		)
	end
end

local function on_align_select(value, text, index, dropdown)
	dropdown.Preview.PreviewState.align_x = value
	rebuild_preview(dropdown.Preview)
end

local function on_mode_select(value, text, index, dropdown)
	dropdown.Preview.PreviewState.mode = value
	rebuild_preview(dropdown.Preview)
end

local function on_fill_change(value, checkbox)
	checkbox.Preview.PreviewState.fill = value
	rebuild_preview(checkbox.Preview)
end

return {
	Name = "buttons",
	Section = "Controls",
	Order = 1,
	Create = function()
		local mode_rows = {}

		for _, mode in ipairs(modes) do
			local row = {}

			for _, color in ipairs(colors) do
				row[#row + 1] = Button{Text = color.label, Mode = mode, ButtonColor = color.token}
			end

			mode_rows[#mode_rows + 1] = kit.Labeled(mode, kit.Group(row))
		end

		local preview = Column{
			PreviewState = {mode = "filled", align_x = 0.5, fill = true},
			layout = {
				ChildGap = "XS",
				AlignmentX = "stretch",
			},
		}
		local controls = kit.Group(
			{
				kit.Labeled(
					"Mode",
					Dropdown{
						Preview = preview,
						Options = {
							{Text = "Filled", Value = "filled"},
							{Text = "Outline", Value = "outline"},
							{Text = "Text", Value = "text"},
							{Text = "Menu", Value = "menu"},
						},
						Value = "filled",
						Padding = "XS",
						OnSelect = on_mode_select,
						layout = {MinSize = Vec2(140, 0), MaxSize = Vec2(140, 0), GrowWidth = 0},
					}
				),
				kit.Labeled(
					"Text alignment",
					Dropdown{
						Preview = preview,
						Options = {
							{Text = "Left", Value = 0},
							{Text = "Center", Value = 0.5},
							{Text = "Right", Value = 1},
						},
						Value = 0.5,
						Padding = "XS",
						OnSelect = on_align_select,
						layout = {MinSize = Vec2(140, 0), MaxSize = Vec2(140, 0), GrowWidth = 0},
					}
				),
				kit.Labeled(
					"Fill width",
					Checkbox{Preview = preview, Value = true, OnChange = on_fill_change}
				),
			},
			{AlignmentY = "end"}
		)
		rebuild_preview(preview)
		local counter = Button{Text = "Pressed 0 times", Presses = 0, OnClick = update_counter}
		local glyphs = {}

		for index, glyph in ipairs{"+", "×", "↗", "…", "Aa"} do
			glyphs[index] = IconButton{
				Text = glyph,
				FontSize = "L",
				Mode = index % 2 == 0 and "outline" or "filled",
				ButtonColor = index == 2 and "negative" or nil,
			}
		end

		local svgs = {}

		for _, name in ipairs{"add", "delete", "edit", "settings", "favorite"} do
			svgs[#svgs + 1] = IconButton{
				SVG = icons[name],
				Mode = name == "edit" and "outline" or "filled",
				ButtonColor = (name == "delete" and "negative") or (name == "favorite" and "positive") or nil,
			}
		end

		local sized = {}

		for _, size in ipairs{"S", "M", "L", "XL", "XXL"} do
			sized[#sized + 1] = IconButton{SVG = icons.arrow, IconSize = size}
		end

		return kit.Page{
			Title = "Buttons",
			Description = "Button, IconButton and the Clickable base they share. Modes, theme colors, states and sizing.",
		}{
			kit.Section{
				Title = "Modes and colors",
				Description = "Mode = filled | outline | text | menu, ButtonColor = palette token.",
			}(mode_rows),
			kit.Section{Title = "States"}{
				kit.Group{
					Button{Text = "Default"},
					Button{Text = "Active", Active = true},
					Button{Text = "Disabled", Disabled = true},
					Button{Text = "Active outline", Active = true, Mode = "outline"},
					Button{Text = "Disabled outline", Disabled = true, Mode = "outline"},
				},
			},
			kit.Section{
				Title = "Callbacks",
				Description = "OnClick runs on release over the button. SetText updates the label.",
			}{counter},
			kit.Section{
				Title = "Layout playground",
				Description = "Fill width stretches both the button and its label so alignment has room to act.",
			}{
				controls,
				preview,
			},
			kit.Section{Title = "Icon buttons"}{
				kit.Labeled("Glyphs", kit.Group(glyphs)),
				kit.Labeled("SVG icons", kit.Group(svgs)),
				kit.Labeled("IconSize = S, M, L, XL, XXL", kit.Group(sized)),
			},
		}
	end,
}
