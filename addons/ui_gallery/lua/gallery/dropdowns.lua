local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function build_options(prefix, count)
	local options = {}

	for index = 1, count do
		options[index] = {
			Text = string.format("%s %02d", prefix, index),
			Value = string.format("%s_%02d", prefix:gsub("%s+", "_"):lower(), index),
		}
	end

	return options
end

local ASSET_PACKS = build_options("Asset pack", 48)
local PRESETS = build_options("Workspace preset", 48)
local COLUMN = {MinSize = Vec2(260, 0), MaxSize = Vec2(260, 0), GrowWidth = 0}
local NARROW = {MinSize = Vec2(180, 0), MaxSize = Vec2(180, 0), GrowWidth = 0}

return {
	Name = "dropdowns",
	Section = "Controls",
	Order = 5,
	View = react.Component(|| -> do
		local readout, set_readout = react.UseState("OnSelect has not fired yet")
		local on_select = |value, text, index| -> set_readout(string.format("OnSelect(%s, %q, %d)", tostring(value), text, index))

		return kit.Page{
			Title = "Dropdowns",
			Description = "A button that opens a context menu of options. Options are strings or {Text, Value} tables.",
		}{
			kit.Section{
				Title = "Basic",
				Description = "OnSelect(value, text, index, dropdown). Value preselects an option and Text is the placeholder.",
			}{
				ui.Dropdown{
					Options = {"Prototype", "Vertical slice", "Content review", "Release candidate"},
					Text = "Pick a milestone",
					OnSelect = on_select,
				},
				ui.Dropdown{
					Options = {
						{Text = "Compact", Value = "compact"},
						{Text = "Comfortable", Value = "comfortable"},
						{Text = "Spacious", Value = "spacious"},
					},
					Value = "comfortable",
					OnSelect = on_select,
				},
				ui.Text{Text = readout, Color = "text_disabled", IgnoreMouseInput = true},
			},
			kit.Section{
				Title = "Long lists",
				Description = "Long option lists scroll. Searchable = true adds a filter field.",
			}{
				kit.Labeled(
					"Scrolling",
					ui.Dropdown{Options = ASSET_PACKS, Text = "Choose a pack", OnSelect = on_select, layout = COLUMN}
				),
				kit.Labeled(
					"Searchable",
					ui.Dropdown{
						Options = PRESETS,
						Text = "Choose a preset",
						Searchable = true,
						OnSelect = on_select,
						layout = COLUMN,
					}
				),
			},
			kit.Section{Title = "Variants"}{
				kit.Group{
					ui.Dropdown{Options = {"One", "Two"}, Text = "Disabled", Disabled = true, layout = NARROW},
					ui.Dropdown{
						Options = {"Small", "Medium", "Large"},
						Text = "Small text",
						FontSize = "S",
						Mode = "filled",
						layout = NARROW,
					},
				},
			},
		}
	end),
}
