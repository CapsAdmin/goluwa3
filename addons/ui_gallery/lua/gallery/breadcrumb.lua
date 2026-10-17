local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local SIZES = {"S", "M", "L"}

return {
	Name = "breadcrumb",
	Section = "Containers",
	Order = 4,
	View = react.Component(|| -> do
		local readout, set_readout = react.UseState("OnSelect has not fired yet")
		local items, set_items = react.UseState({"scene", "house.prefab", "door.prefab"})
		local dynamic_readout, set_dynamic_readout = react.UseState("Clicking a crumb truncates the path to it")

		return kit.Page{
			Title = "Breadcrumb",
			Description = "The path to the current location. Every crumb but the last one navigates back to it.",
		}{
			kit.Section{
				Title = "Breadcrumb",
				Description = "Items is the list of names, the last one is the current location. OnSelect(index, breadcrumb) fires when an earlier crumb is clicked.",
			}{
				ui.Breadcrumb{
					Items = {"scene", "house.prefab", "door.prefab", "handle.prefab"},
					OnSelect = |index| -> set_readout("OnSelect(" .. index .. ")"),
				},
				ui.Text{Text = readout, Color = "text_disabled", IgnoreMouseInput = true},
			},
			kit.Section{
				Title = "Icons",
				Description = "Icons maps a name to an icon shown before the label.",
			}{
				ui.Breadcrumb{
					Items = {"scene", "house.prefab", "door.prefab"},
					Icons = {scene = "world", ["house.prefab"] = "layers"},
				},
			},
			kit.Section{
				Title = "Changing the path",
				Description = "SetItems takes a list of names and only rebuilds when it changed.",
			}{
				ui.Breadcrumb{
					Items = items,
					OnSelect = |index| -> do
						set_items(list.slice(items, 1, index))
						set_dynamic_readout("OnSelect(" .. index .. ")")
					end,
				},
				kit.Group{
					ui.Button{
						Text = "Go deeper",
						Mode = "outline",
						OnClick = || -> do
							local deeper = table.shallow_copy(items)
							deeper[#deeper + 1] = "level " .. (#deeper + 1)
							set_items(deeper)
						end,
					},
				},
				ui.Text{Text = dynamic_readout, Color = "text_disabled", IgnoreMouseInput = true},
			},
			kit.Section{Title = "Font size", Description = "FontSize sizes the labels."}{
				kit.Group(
					list.map(
						SIZES,
						|size| -> kit.Labeled(
							"FontSize = " .. size,
							ui.Breadcrumb{
								Key = size,
								Items = {"Home", "Assets", "Models"},
								FontSize = size,
								layout = {MinSize = Vec2(320, 0), GrowWidth = 0},
							}
						)
					),
					{AlignmentY = "start", WrapChildren = true}
				),
			},
		}
	end),
}
