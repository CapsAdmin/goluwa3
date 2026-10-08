local Vec2 = import("goluwa/structs/vec2.lua")
local Dropdown = import("goluwa/render2d/ui/widgets/dropdown.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
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

local function on_select(value, text, index, dropdown)
	dropdown.Readout.text:SetText(string.format("OnSelect(%s, %q, %d)", tostring(value), text, index))
end

return {
	Name = "dropdowns",
	Section = "Controls",
	Order = 5,
	Create = function()
		local readout = Text{
			Text = "OnSelect has not fired yet",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		return kit.Page{
			Title = "Dropdowns",
			Description = "A button that opens a context menu of options. Options are strings or {Text, Value} tables.",
		}{
			kit.Section{
				Title = "Basic",
				Description = "OnSelect(value, text, index, dropdown). Value preselects an option and Text is the placeholder.",
			}{
				Dropdown{
					Options = {"Prototype", "Vertical slice", "Content review", "Release candidate"},
					Text = "Pick a milestone",
					Readout = readout,
					OnSelect = on_select,
				},
				Dropdown{
					Options = {
						{Text = "Compact", Value = "compact"},
						{Text = "Comfortable", Value = "comfortable"},
						{Text = "Spacious", Value = "spacious"},
					},
					Value = "comfortable",
					Readout = readout,
					OnSelect = on_select,
				},
				readout,
			},
			kit.Section{
				Title = "Long lists",
				Description = "Long option lists scroll. Searchable = true adds a filter field.",
			}{
				kit.Labeled(
					"Scrolling",
					Dropdown{
						Options = build_options("Asset pack", 48),
						Text = "Choose a pack",
						Readout = readout,
						OnSelect = on_select,
						layout = {MinSize = Vec2(260, 0), MaxSize = Vec2(260, 0), GrowWidth = 0},
					}
				),
				kit.Labeled(
					"Searchable",
					Dropdown{
						Options = build_options("Workspace preset", 48),
						Text = "Choose a preset",
						Searchable = true,
						Readout = readout,
						OnSelect = on_select,
						layout = {MinSize = Vec2(260, 0), MaxSize = Vec2(260, 0), GrowWidth = 0},
					}
				),
			},
			kit.Section{Title = "Variants"}{
				kit.Group{
					Dropdown{
						Options = {"One", "Two"},
						Text = "Disabled",
						Disabled = true,
						layout = {MinSize = Vec2(180, 0), MaxSize = Vec2(180, 0), GrowWidth = 0},
					},
					Dropdown{
						Options = {"Small", "Medium", "Large"},
						Text = "Small text",
						FontSize = "S",
						Mode = "filled",
						layout = {MinSize = Vec2(180, 0), MaxSize = Vec2(180, 0), GrowWidth = 0},
					},
				},
			},
		}
	end,
}
