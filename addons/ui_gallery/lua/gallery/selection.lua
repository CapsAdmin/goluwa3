local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local OPTIONS = {"Low", "Medium", "High"}
return {
	Name = "selection",
	Section = "Controls",
	Order = 2,
	View = react.Component(
		||-> do
			local checked, set_checked = react.UseState(true)
			local selected, set_selected = react.UseState(1)
			local radios = list.map(
				OPTIONS,
				|option,index|->ui.RadioButton{
					Key = option,
					Text = option,
					IsSelected = ||->selected == index,
					OnSelect = ||->set_selected(index),
				}
			)
			return kit.Page{
				Title = "Selection",
				Description = "Checkboxes and radio buttons share the theme's checkable look and spring animation.",
			}{
				kit.Section{
					Title = "Checkbox",
					Description = "OnChange(value) fires when the value flips. SetValue(value, notify) controls whether it fires.",
				}{
					kit.Group{
						ui.Checkbox{Text = "Enabled", Value = true, OnChange = set_checked},
						ui.Checkbox{Text = "Unchecked", Value = false, OnChange = set_checked},
						ui.Checkbox{Text = "Disabled", Value = true, Disabled = true},
					},
					ui.Text{
						Text = "Checkbox value: " .. tostring(checked),
						Color = "text_disabled",
						IgnoreMouseInput = true,
					},
				},
				kit.Section{
					Title = "Radio buttons",
					Description = "IsSelected is polled each frame so the group state can live anywhere.",
				}{
					kit.Group(radios, {ChildGap = "L"}),
					ui.Text{
						Text = "Selected: " .. OPTIONS[selected],
						Color = "text_disabled",
						IgnoreMouseInput = true,
					},
				},
			}
		end
	),
}
