local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local TabBar = import("goluwa/render2d/ui/widgets/tab_bar.lua")
local Tabs = import("goluwa/render2d/ui/widgets/tabs.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function page(name, children)
	return Column{
		Tab = name,
		layout = {ChildGap = "S", Padding = "M", AlignmentX = "stretch"},
	}(children)
end

local function on_tabs_change(name, tabs)
	tabs.Readout.text:SetText("OnChange(" .. name .. ")")
end

local function on_bar_change(name, bar)
	bar.Readout.text:SetText("OnChange(" .. name .. ")")
end

local function step_bar(button)
	local bar = button.Bar
	local index = 1

	for i, name in ipairs(bar.Tabs) do
		if name == bar.Value then index = i end
	end

	local name = bar.Tabs[(index - 1 + button.Step) % #bar.Tabs + 1]
	bar:SetValue(name)
	bar.Readout.text:SetText("SetValue(" .. name .. ") does not fire OnChange")
end

local function add_tab(button)
	local bar = button.Bar
	local tabs = table.shallow_copy(bar.Tabs)
	tabs[#tabs + 1] = "Tab " .. (#tabs + 1)
	bar:SetTabs(tabs)
	bar:SetValue(tabs[#tabs])
end

local function remove_tab(button)
	local bar = button.Bar
	local tabs = table.shallow_copy(bar.Tabs)
	tabs[#tabs] = nil
	bar:SetTabs(tabs)
	bar:SetValue(tabs[#tabs])
end

return {
	Name = "tabs",
	Section = "Containers",
	Order = 3,
	Create = function()
		local tabs_readout = Text{
			Text = "OnChange has not fired yet",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local bar_readout = Text{
			Text = "OnChange has not fired yet",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local dynamic_readout = Text{
			Text = "SetTabs rebuilds the tabs only when the list changed",
			Color = "text_disabled",
			IgnoreMouseInput = true,
		}
		local bar = TabBar{
			Tabs = {"Inspector", "Hierarchy", "Console"},
			Value = "Hierarchy",
			Readout = bar_readout,
			OnChange = on_bar_change,
		}
		local dynamic = TabBar{
			Tabs = {"Tab 1", "Tab 2"},
			Value = "Tab 1",
			Readout = dynamic_readout,
			OnChange = on_bar_change,
		}
		local sizes = {}

		for _, size in ipairs{"S", "M", "L"} do
			sizes[#sizes + 1] = kit.Labeled(
				"FontSize = " .. size,
				TabBar{
					Tabs = {"Models", "Textures", "Materials"},
					Value = "Textures",
					FontSize = size,
					layout = {MinSize = Vec2(320, 0), GrowWidth = 0},
				}
			)
		end

		return kit.Page{
			Title = "Tabs",
			Description = "A tab bar and a container that shows one page at a time.",
		}{
			kit.Section{
				Title = "Tabs",
				Description = "Children carrying a Tab name become the pages, in order. Value picks the page that is shown, the first one by default.",
			}{
				Tabs{Readout = tabs_readout, OnChange = on_tabs_change}{
					page(
						"Overview",
						{
							kit.Paragraph(kit.Lorem),
						}
					),
					page(
						"Settings",
						{
							Checkbox{Text = "Enable shadows", Value = true},
							Checkbox{Text = "Show the grid"},
							Slider{Value = 0.6, layout = {GrowWidth = 1, MinSize = Vec2(200, 16)}},
						}
					),
					page(
						"About",
						{
							Text{Text = "Only the page of the active tab takes part in layout.", IgnoreMouseInput = true},
							kit.Group{Button{Text = "A button on the page", Mode = "outline"}},
						}
					),
				},
				tabs_readout,
			},
			kit.Section{
				Title = "Tab bar",
				Description = "The row of tabs on its own, for content that is managed elsewhere. OnChange(name, bar) fires when a tab is clicked, SetValue changes the tab without it.",
			}{
				bar,
				kit.Group{
					Button{Text = "Previous", Mode = "outline", Bar = bar, Step = -1, OnClick = step_bar},
					Button{Text = "Next", Mode = "outline", Bar = bar, Step = 1, OnClick = step_bar},
				},
				bar_readout,
			},
			kit.Section{
				Title = "Changing the tabs",
				Description = "SetTabs takes a list of names.",
			}{
				dynamic,
				kit.Group{
					Button{Text = "Add tab", Mode = "outline", Bar = dynamic, OnClick = add_tab},
					Button{Text = "Remove tab", Mode = "outline", Bar = dynamic, OnClick = remove_tab},
				},
				dynamic_readout,
			},
			kit.Section{
				Title = "Font size",
				Description = "FontSize sizes the labels, the tabs grow with it.",
			}{kit.Group(sizes, {AlignmentY = "start", WrapChildren = true})},
		}
	end,
}
