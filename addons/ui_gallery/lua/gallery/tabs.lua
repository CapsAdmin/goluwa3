local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local BAR_TABS = {"Inspector", "Hierarchy", "Console"}

local function page(name, children)
	return ui.Column{
		Key = name,
		Tab = name,
		layout = {ChildGap = "S", Padding = "M", AlignmentX = "stretch"},
	}{children}
end

local function readout(text)
	return ui.Text{Text = text, Color = "text_disabled", IgnoreMouseInput = true}
end

return {
	Name = "tabs",
	Section = "Containers",
	Order = 3,
	View = react.Component(
		||-> do
			local tabs_readout, set_tabs_readout = react.UseState("OnChange has not fired yet")
			local bar_value, set_bar_value = react.UseState("Hierarchy")
			local bar_readout, set_bar_readout = react.UseState("OnChange has not fired yet")
			local dynamic_tabs, set_dynamic_tabs = react.UseState({"Tab 1", "Tab 2"})
			local dynamic_value, set_dynamic_value = react.UseState("Tab 1")
			local dynamic_readout, set_dynamic_readout = react.UseState("SetTabs rebuilds the tabs only when the list changed")

			local function step_bar(step)
				local index = 1

				for i, name in ipairs(BAR_TABS) do
					if name == bar_value then index = i end
				end

				local name = BAR_TABS[(index - 1 + step) % #BAR_TABS + 1]
				set_bar_value(name)
				set_bar_readout("SetValue(" .. name .. ") does not fire OnChange")
			end

			return kit.Page{
				Title = "Tabs",
				Description = "A tab bar and a container that shows one page at a time.",
			}{
				kit.Section{
					Title = "Tabs",
					Description = "Children carrying a Tab name become the pages, in order. Value picks the page that is shown, the first one by default.",
				}{
					ui.Tabs{OnChange = |name|->set_tabs_readout("OnChange(" .. name .. ")")}{
						page("Overview", {kit.Paragraph(kit.Lorem)}),
						page(
							"Settings",
							{
								ui.Checkbox{Text = "Enable shadows", Value = true},
								ui.Checkbox{Text = "Show the grid"},
								ui.Slider{Value = 0.6, layout = {GrowWidth = 1, MinSize = Vec2(200, 16)}},
							}
						),
						page(
							"About",
							{
								ui.Text{
									Text = "Only the page of the active tab takes part in layout.",
									IgnoreMouseInput = true,
								},
								kit.Group{ui.Button{Text = "A button on the page", Mode = "outline"}},
							}
						),
					},
					readout(tabs_readout),
				},
				kit.Section{
					Title = "Tab bar",
					Description = "The row of tabs on its own, for content that is managed elsewhere. OnChange(name, bar) fires when a tab is clicked, SetValue changes the tab without it.",
				}{
					ui.TabBar{
						Tabs = BAR_TABS,
						Value = bar_value,
						OnChange = |name|-> do
							set_bar_value(name)
							set_bar_readout("OnChange(" .. name .. ")")
						end,
					},
					kit.Group{
						ui.Button{Text = "Previous", Mode = "outline", OnClick = ||->step_bar(-1)},
						ui.Button{Text = "Next", Mode = "outline", OnClick = ||->step_bar(1)},
					},
					readout(bar_readout),
				},
				kit.Section{Title = "Changing the tabs", Description = "SetTabs takes a list of names."}{
					ui.TabBar{
						Tabs = dynamic_tabs,
						Value = dynamic_value,
						OnChange = |name|-> do
							set_dynamic_value(name)
							set_dynamic_readout("OnChange(" .. name .. ")")
						end,
					},
					kit.Group{
						ui.Button{
							Text = "Add tab",
							Mode = "outline",
							OnClick = ||-> do
								local tabs = table.shallow_copy(dynamic_tabs)
								tabs[#tabs + 1] = "Tab " .. (#tabs + 1)
								set_dynamic_tabs(tabs)
								set_dynamic_value(tabs[#tabs])
							end,
						},
						ui.Button{
							Text = "Remove tab",
							Mode = "outline",
							OnClick = ||-> do
								local tabs = table.shallow_copy(dynamic_tabs)
								tabs[#tabs] = nil
								set_dynamic_tabs(tabs)
								set_dynamic_value(tabs[#tabs])
							end,
						},
					},
					readout(dynamic_readout),
				},
				kit.Section{
					Title = "Font size",
					Description = "FontSize sizes the labels, the tabs grow with it.",
				}{
					kit.Group(
						list.map(
							{"S", "M", "L"},
							|size|->kit.Labeled(
								"FontSize = " .. size,
								ui.TabBar{
									Key = size,
									Tabs = {"Models", "Textures", "Materials"},
									Value = "Textures",
									FontSize = size,
									layout = {MinSize = Vec2(320, 0), GrowWidth = 0},
								}
							)
						),
						{AlignmentY = "start", WrapChildren = true}
					),
				},
			}
		end
	),
}
