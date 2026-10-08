local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local RadioButton = import("goluwa/render2d/ui/elements/radio_button.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function on_check_change(value, checkbox)
	checkbox.Readout.text:SetText("Checkbox value: " .. tostring(value))
end

local function is_option_selected(radio)
	return radio.Group.selected == radio.Index
end

local function on_option_select(radio)
	local group = radio.Group
	group.selected = radio.Index
	group.Readout.text:SetText("Selected: " .. group.options[radio.Index])
end

return {
	Name = "selection",
	Section = "Controls",
	Order = 2,
	Create = function()
		local check_readout = Text{Text = "Checkbox value: true", Color = "text_disabled", IgnoreMouseInput = true}
		local radio_readout = Text{Text = "Selected: Low", Color = "text_disabled", IgnoreMouseInput = true}
		local group = {selected = 1, options = {"Low", "Medium", "High"}, Readout = radio_readout}
		local radios = {}

		for index, option in ipairs(group.options) do
			radios[index] = RadioButton{
				Text = option,
				Group = group,
				Index = index,
				IsSelected = is_option_selected,
				OnSelect = on_option_select,
			}
		end

		return kit.Page{
			Title = "Selection",
			Description = "Checkboxes and radio buttons share the theme's checkable look and spring animation.",
		}{
			kit.Section{
				Title = "Checkbox",
				Description = "OnChange(value) fires when the value flips. SetValue(value, notify) controls whether it fires.",
			}{
				kit.Group{
					Checkbox{
						Text = "Enabled",
						Value = true,
						Readout = check_readout,
						OnChange = on_check_change,
					},
					Checkbox{
						Text = "Unchecked",
						Value = false,
						Readout = check_readout,
						OnChange = on_check_change,
					},
					Checkbox{Text = "Disabled", Value = true, Disabled = true},
				},
				check_readout,
			},
			kit.Section{
				Title = "Radio buttons",
				Description = "IsSelected is polled each frame so the group state can live anywhere.",
			}{
				kit.Group(radios, {ChildGap = "L"}),
				radio_readout,
			},
		}
	end,
}
