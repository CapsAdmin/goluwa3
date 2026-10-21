local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local modes = {"filled", "outline", "text", "menu"}
local colors = {
	{label = "primary", token = nil},
	{label = "positive", token = "positive"},
	{label = "neutral", token = "neutral"},
	{label = "negative", token = "negative"},
}
local icons = {
	add = "plus",
	delete = "trash",
	edit = "edit",
	settings = "settings",
	favorite = "star",
	arrow = "arrow_right",
}
local SELECT = {MinSize = Vec2(140, 0), MaxSize = Vec2(140, 0), GrowWidth = 0}
return {
	Name = "buttons",
	Section = "Controls",
	Order = 1,
	View = react.Component(
		||-> do
			local presses, set_presses = react.UseState(0)
			local mode, set_mode = react.UseState("filled")
			local align_x, set_align_x = react.UseState(0.5)
			local fill, set_fill = react.UseState(true)
			return kit.Page{
				Title = "Buttons",
				Description = "Button, IconButton and the Clickable base they share. Modes, theme colors, states and sizing.",
			}{
				kit.Section{
					Title = "Modes and colors",
					Description = "Mode = filled | outline | text | menu, ButtonColor = palette token.",
				}{
					list.map(
						modes,
						|row_mode|->kit.Labeled(
							row_mode,
							kit.Group(
								list.map(
									colors,
									|color|->ui.Button{
										Key = color.label,
										Text = color.label,
										Mode = row_mode,
										ButtonColor = color.token,
									}
								)
							)
						)
					),
				},
				kit.Section{Title = "States"}{
					kit.Group{
						ui.Button{Text = "Default"},
						ui.Button{Text = "Active", Active = true},
						ui.Button{Text = "Disabled", Disabled = true},
						ui.Button{Text = "Active outline", Active = true, Mode = "outline"},
						ui.Button{Text = "Disabled outline", Disabled = true, Mode = "outline"},
					},
				},
				kit.Section{
					Title = "Callbacks",
					Description = "OnClick runs on release over the button. SetText updates the label.",
				}{
					ui.Button{
						Text = "Pressed " .. presses .. " times",
						OnClick = ||->set_presses(|count|->count + 1),
					},
				},
				kit.Section{
					Title = "Layout playground",
					Description = "Fill width stretches both the button and its label so alignment has room to act.",
				}{
					kit.Group(
						{
							kit.Labeled(
								"Mode",
								ui.Dropdown{
									Options = {
										{Text = "Filled", Value = "filled"},
										{Text = "Outline", Value = "outline"},
										{Text = "Text", Value = "text"},
										{Text = "Menu", Value = "menu"},
									},
									Value = "filled",
									Padding = "XS",
									OnSelect = set_mode,
									layout = SELECT,
								}
							),
							kit.Labeled(
								"Text alignment",
								ui.Dropdown{
									Options = {
										{Text = "Left", Value = 0},
										{Text = "Center", Value = 0.5},
										{Text = "Right", Value = 1},
									},
									Value = 0.5,
									Padding = "XS",
									OnSelect = set_align_x,
									layout = SELECT,
								}
							),
							kit.Labeled("Fill width", ui.Checkbox{Value = true, OnChange = set_fill}),
						},
						{AlignmentY = "end"}
					),
					ui.Column{layout = {ChildGap = "XS", AlignmentX = "stretch"}}{
						list.map(
							colors,
							|color|->ui.Button{
								Key = color.label .. " " .. mode .. " " .. align_x .. " " .. tostring(fill),
								Text = color.label .. " action",
								Mode = mode,
								ButtonColor = color.token,
								AlignX = align_x,
								layout = {GrowWidth = fill and 1 or 0, FitWidth = not fill},
								TextLayout = {GrowWidth = fill and 1 or 0, FitWidth = not fill},
							}
						),
					},
				},
				kit.Section{Title = "Icon buttons"}{
					kit.Labeled(
						"Glyphs",
						kit.Group(
							list.map(
								{"+", "×", "↗", "…", "Aa"},
								|glyph,index|->ui.IconButton{
									Key = glyph,
									Text = glyph,
									FontSize = "L",
									Mode = index % 2 == 0 and "outline" or "filled",
									ButtonColor = index == 2 and "negative" or nil,
								}
							)
						)
					),
					kit.Labeled(
						"Icons",
						kit.Group(
							list.map(
								{"add", "delete", "edit", "settings", "favorite"},
								|name|->ui.IconButton{
									Key = name,
									Icon = icons[name],
									Mode = name == "edit" and "outline" or "filled",
									ButtonColor = (name == "delete" and "negative") or (name == "favorite" and "positive") or nil,
								}
							)
						)
					),
					kit.Labeled(
						"IconSize = S, M, L, XL, XXL",
						kit.Group(
							list.map(
								{"S", "M", "L", "XL", "XXL"},
								|size|->ui.IconButton{Key = size, Icon = icons.arrow, IconSize = size}
							)
						)
					),
				},
			}
		end
	),
}
