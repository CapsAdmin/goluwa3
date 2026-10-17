local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")

local function mount(name)
	local page = import("lua/gallery/" .. name .. ".lua")
	local scroll = ScrollablePanel{Size = Vec2(900, 700), layout = {GrowWidth = 1, GrowHeight = 1}}
	local root = react.Mount(page.View{}, scroll)

	return root, scroll
end

local function find_all(root, type_name)
	local found = {}

	for _, child in ipairs(root:GetChildrenList()) do
		if child.Type == type_name then found[#found + 1] = child end
	end

	return found
end

local function button(root, text)
	for _, candidate in ipairs(find_all(root, "panel_button")) do
		if candidate:GetText() == text then return candidate end
	end
end

local function click(root, text)
	button(root, text):CallLocalEvent("OnClick")
	react.Flush()
end

local function has_text(root, text)
	for _, candidate in ipairs(find_all(root, "panel_text")) do
		if candidate.text:GetText() == text then return true end
	end

	return false
end

T.Test2D("gallery buttons page counts presses and remounts the preview when the layout changes", function()
	local root, scroll = mount("buttons")
	click(scroll, "Pressed 0 times")
	click(scroll, "Pressed 1 times")
	T(button(scroll, "Pressed 2 times") ~= nil)["=="](true)
	local first = button(scroll, "primary action")
	local fill = find_all(scroll, "panel_checkbox")[1]
	fill.OnChange(false, fill)
	react.Flush()
	T(first:IsValid())["=="](false)
	T(button(scroll, "primary action") ~= nil)["=="](true)
	root:Unmount()
	scroll:Remove()
end)

T.Test2D("gallery selection and text input pages show what the controls report", function()
	local root, scroll = mount("selection")
	T(has_text(scroll, "Checkbox value: true"))["=="](true)
	T(has_text(scroll, "Selected: Low"))["=="](true)
	local boxes = find_all(scroll, "panel_checkbox")
	boxes[2].OnChange(false, boxes[2])
	react.Flush()
	T(has_text(scroll, "Checkbox value: false"))["=="](true)
	local radios = find_all(scroll, "panel_radio_button")
	radios[3]:CallLocalEvent("OnClick")
	react.Flush()
	T(has_text(scroll, "Selected: High"))["=="](true)
	T(radios[3]:IsChecked())["=="](true)
	T(radios[1]:IsChecked())["=="](false)
	root:Unmount()
	scroll:Remove()
	local text_root, text_scroll = mount("text_input")
	T(has_text(text_scroll, "0 characters"))["=="](true)
	local edit = find_all(text_scroll, "panel_text_edit")[1]
	edit:SetText("hello")
	edit.OnTextChanged(edit, "hello")
	react.Flush()
	T(has_text(text_scroll, "5 characters"))["=="](true)
	text_root:Unmount()
	text_scroll:Remove()
end)

T.Test2D("gallery tabs page changes its bars through state", function()
	local root, scroll = mount("tabs")
	local bars = find_all(scroll, "panel_tab_bar")
	local dynamic = bars[3]
	T(#dynamic.Tabs)["=="](2)
	click(scroll, "Add tab")
	T(#dynamic.Tabs)["=="](3)
	T(dynamic.Value)["=="]("Tab 3")
	click(scroll, "Remove tab")
	click(scroll, "Remove tab")
	T(#dynamic.Tabs)["=="](1)
	T(dynamic.Value)["=="]("Tab 1")
	local bar = bars[2]
	T(bar.Value)["=="]("Hierarchy")
	click(scroll, "Next")
	T(bar.Value)["=="]("Console")
	T(has_text(scroll, "SetValue(Console) does not fire OnChange"))["=="](true)
	click(scroll, "Next")
	T(bar.Value)["=="]("Inspector")
	click(scroll, "Previous")
	T(bar.Value)["=="]("Console")
	root:Unmount()
	scroll:Remove()
end)

T.Test2D("gallery containers page collapses and expands through state and follows clicks", function()
	local root, scroll = mount("containers")
	local sections = find_all(scroll, "panel_collapsible")
	T(sections[1].Collapsed)["=="](false)
	T(sections[2].Collapsed)["=="](true)
	click(scroll, "Collapse all")
	T(sections[1].Collapsed)["=="](true)
	click(scroll, "Expand all")
	T(sections[1].Collapsed)["=="](false)
	T(sections[2].Collapsed)["=="](false)
	T(sections[3].Collapsed)["=="](true)
	T(sections[4].Collapsed)["=="](false)
	sections[1]:SetCollapsed(true)
	react.Flush()
	T(has_text(scroll, "OnToggle(true)"))["=="](true)
	click(scroll, "Expand all")
	T(sections[1].Collapsed)["=="](false)
	root:Unmount()
	scroll:Remove()
end)

T.Test2D("gallery breadcrumb and dropdown pages report through state", function()
	local root, scroll = mount("breadcrumb")
	local dynamic = find_all(scroll, "panel_breadcrumb")[3]
	T(#dynamic.Items)["=="](3)
	click(scroll, "Go deeper")
	T(#dynamic.Items)["=="](4)
	T(dynamic.Items[4])["=="]("level 4")
	dynamic.OnSelect(2, dynamic)
	react.Flush()
	T(#dynamic.Items)["=="](2)
	T(has_text(scroll, "OnSelect(2)"))["=="](true)
	root:Unmount()
	scroll:Remove()
	local drop_root, drop_scroll = mount("dropdowns")
	local dropdown = find_all(drop_scroll, "panel_dropdown")[2]
	dropdown.OnSelect("spacious", "Spacious", 3, dropdown)
	react.Flush()
	T(has_text(drop_scroll, "OnSelect(spacious, \"Spacious\", 3)"))["=="](true)
	drop_root:Unmount()
	drop_scroll:Remove()
end)

T.Test2D("gallery windows page opens windows into the world and closing removes them from the state", function()
	local root, scroll = mount("windows")
	local before = #Panel.World:GetChildren()
	click(scroll, "Open a window")
	click(scroll, "Open a window")
	click(scroll, "Open with custom OnClose")
	T(#Panel.World:GetChildren())["=="](before + 3)
	local windows = find_all(Panel.World, "panel_window")
	local opened = {}

	for _, window in ipairs(windows) do
		if window.Title:starts_with("WINDOW") or window.Title == "CONFIRM" then opened[#opened + 1] = window end
	end

	T(#opened)["=="](3)
	opened[1].OnClose(opened[1])
	react.Flush()
	T(opened[1]:IsValid())["=="](false)
	T(opened[2]:IsValid())["=="](true)
	click(scroll, "Open a window")
	T(#Panel.World:GetChildren())["=="](before + 3)
	root:Unmount()
	T(#Panel.World:GetChildren())["=="](before)
	scroll:Remove()
end)

T.Test2D("gallery sliders page follows the controls", function()
	local root, scroll = mount("sliders")
	T(has_text(scroll, "volume = 0.40"))["=="](true)
	local sliders = find_all(scroll, "panel_slider")
	sliders[1].OnChange(0.75, sliders[1])
	react.Flush()
	T(has_text(scroll, "volume = 0.75"))["=="](true)
	local step = find_all(scroll, "panel_step_number_value")[1]
	step.OnChange(8, 5, step)
	react.Flush()
	T(has_text(scroll, "value = 8"))["=="](true)
	root:Unmount()
	scroll:Remove()
end)

T.Test2D("gallery icons, svg and color picker pages follow their controls", function()
	local icons_root, icons_scroll = mount("icons")
	T(has_text(icons_scroll, "Icon size: 40"))["=="](true)
	local tiles = find_all(icons_scroll, "panel_icon")
	T(#tiles)[">"](20)
	T(tiles[1].transform:GetSize().x)["=="](40)
	local slider = find_all(icons_scroll, "panel_slider")[1]
	slider.OnChange(72.2, slider)
	react.Flush()
	T(has_text(icons_scroll, "Icon size: 72"))["=="](true)
	T(tiles[1].transform:GetSize().x)["=="](72)
	icons_root:Unmount()
	icons_scroll:Remove()
	local svg_root, svg_scroll = mount("svg")
	local svgs = find_all(svg_scroll, "panel_svg")
	local custom = svgs[#svgs]
	local edit = find_all(svg_scroll, "panel_text_edit")[1]
	local markup = [[<svg viewBox="0 0 24 24"><path d="M2 2L22 2L12 22z"/></svg>]]
	edit:SetText(markup)
	edit.OnTextChanged(edit, markup)
	react.Flush()
	click(svg_scroll, "Load")
	T(custom.Source)["=="](markup)
	svg_root:Unmount()
	svg_scroll:Remove()
	local Color = import("goluwa/structs/color.lua")
	local picker_root, picker_scroll = mount("color_picker")
	T(has_text(picker_scroll, "RGBA 54, 199, 255, 214"))["=="](true)
	local picker = find_all(picker_scroll, "panel_color_picker")[1]
	picker.OnChange(Color.FromBytes(10, 20, 30, 255), picker.Value, picker)
	react.Flush()
	T(has_text(picker_scroll, "RGBA 10, 20, 30, 255"))["=="](true)
	local before = #Panel.World:GetChildren()
	click(picker_scroll, "Open in window")
	T(#Panel.World:GetChildren())["=="](before + 1)
	picker_root:Unmount()
	T(#Panel.World:GetChildren())["=="](before)
	picker_scroll:Remove()
end)

T.Test2D("gallery tree page moves nodes on a drop, follows the selection and swaps the items", function()
	local root, scroll = mount("tree")
	local tree = find_all(scroll, "panel_tree")[1]
	T(has_text(scroll, "tree.lua"))["=="](true)
	T(tree:GetSelectedKey())["=="]("project/ui/elements/tree.lua")
	tree.OnSelect({Text = "case_1.lua", Kind = "file", Key = "project/tests/case_1.lua", Description = "A test case #1"}, "project/tests/case_1.lua")
	react.Flush()
	T(has_text(scroll, "case_1.lua"))["=="](true)
	T(has_text(scroll, "A test case #1"))["=="](true)
	local handled = tree.OnDrop{
		source_key = "project/tests/case_1.lua",
		target_key = "project/assets",
		position = "inside",
		source_node = {Text = "case_1.lua"},
		target_node = {Text = "assets"},
	}
	react.Flush()
	T(handled)["=="](true)
	T(has_text(scroll, "Moved case_1.lua into assets."))["=="](true)
	T(tree:GetSelectedKey())["=="]("project/tests/case_1.lua")
	local assets
	local function find(nodes, key)
		for _, node in ipairs(nodes) do
			if node.Key == key then assets = node end

			if node.Children then find(node.Children, key) end
		end
	end
	find(tree:GetItems(), "project/assets")
	local moved = false

	for _, child in ipairs(assets.Children) do
		if child.Key == "project/tests/case_1.lua" then moved = true end
	end

	T(moved)["=="](true)
	T(tree.OnDrop{source_key = "missing", target_key = "project/assets", position = "inside"})["=="](false)
	local hidden = find_all(scroll, "panel_checkbox")[1]
	hidden.OnChange(true, hidden)
	react.Flush()
	local names = {}

	for _, node in ipairs(tree:GetItems()[1].Children) do
		names[#names + 1] = node.Text
	end

	T(table.concat(names, ","))["=="]("ui,tests,assets,.gitignore,.editorconfig")
	root:Unmount()
	scroll:Remove()
end)

T.Test2D("gallery entity tree and scrolling pages", function()
	local Entity = import("goluwa/entities/entity.lua")
	local root, scroll = mount("entity_tree")
	T(has_text(scroll, "Nothing selected"))["=="](true)
	local entity = Entity.New{Name = "Gallery Thing"}
	local tree = find_all(scroll, "panel_entity_tree")[1]
	tree.OnSelect({Entity = entity})
	react.Flush()
	T(has_text(scroll, "Gallery Thing"))["=="](true)
	T(has_text(scroll, "GUID: " .. entity:GetGUID()))["=="](true)
	entity:Remove()
	tree.OnSelect(nil)
	react.Flush()
	T(has_text(scroll, "Nothing selected"))["=="](true)
	root:Unmount()
	scroll:Remove()
	local scroll_root, scroll_page = mount("scrolling")
	local panels = find_all(scroll_page, "panel_scrollable_panel")
	local vertical = panels[2]
	local buttons = find_all(scroll_page, "panel_checkbox")
	local before = vertical.ScrollbarButtons
	buttons[1].OnChange(true, buttons[1])
	react.Flush()
	T(vertical.ScrollbarButtons)["=="](true)
	buttons[1].OnChange(false, buttons[1])
	react.Flush()
	T(vertical.ScrollbarButtons)["=="](false)
	click(scroll_page, "Last row")
	click(scroll_page, "Bottom right")
	click(scroll_page, "End")
	T(before == nil or before == false)["=="](true)
	scroll_root:Unmount()
	scroll_page:Remove()
end)

T.Test2D("gallery input assist, layout and property editor pages", function()
	local assist_root, assist_scroll = mount("input_assist")
	local lists = find_all(Panel.World, "panel_autocomplete_list")
	T(#lists)[">="](4)
	local edits = find_all(assist_scroll, "panel_text_edit")
	local history_edit = edits[2]
	history_edit:SetText("a brand new command")
	T(history_edit.OnKeyInput(history_edit, "enter", true))["=="](true)
	react.Flush()
	T(has_text(assist_scroll, "submitted: a brand new command"))["=="](true)
	T(has_text(assist_scroll, "draft (5 entries)"))["=="](true)
	assist_root:Unmount()
	assist_scroll:Remove()
	T(#find_all(Panel.World, "panel_autocomplete_list"))["<"](#lists)
	local layout_root, layout_scroll = mount("layout")
	local rows = find_all(layout_scroll, "panel_row")
	local host

	for _, row in ipairs(rows) do
		if row.layout.WrapChildren and #row:GetChildren() > 5 then host = row end
	end

	T(#host:GetChildren())["=="](14)
	local sliders = find_all(layout_scroll, "panel_slider")
	sliders[1].OnChange(5, sliders[1])
	react.Flush()
	T(#host:GetChildren())["=="](5)
	local dropdowns = find_all(layout_scroll, "panel_dropdown")
	dropdowns[1].OnSelect("y", "Column (y)", 2, dropdowns[1])
	react.Flush()
	T(host.layout.Direction)["=="]("y")
	layout_root:Unmount()
	layout_scroll:Remove()
	local editor_root, editor_scroll = mount("property_editor")
	local editors = find_all(editor_scroll, "panel_property_editor")
	local hand_built = editors[1]
	T(has_text(editor_scroll, "Live state"))["=="](true)
	hand_built:GetItems()[1].Children[1].OnChange(nil, "Renamed Drone")
	react.Flush()
	local function state_view()
		for _, edit in ipairs(find_all(editor_scroll, "panel_text_edit")) do
			if edit.Editable == false then return edit end
		end
	end
	T(state_view():GetText():find("name = Renamed Drone", 1, true) ~= nil)["=="](true)
	hand_built:GetItems()[3].Children[2].OnAction()
	react.Flush()
	T(hand_built:IsValid())["=="](false)
	T(state_view():GetText():find("name = Beacon Drone", 1, true) ~= nil)["=="](true)
	editor_root:Unmount()
	editor_scroll:Remove()
end)

T.Test2D("gallery menus page reports the picked item", function()
	local root, scroll = mount("menus")
	T(has_text(scroll, "Open a menu and pick an item."))["=="](true)
	local bar = find_all(scroll, "panel_menu_bar")[1]
	local menu = bar.Items[1].Items()
	menu[1]:CallLocalEvent("OnClick")
	react.Flush()
	T(has_text(scroll, "Selected: File > New file"))["=="](true)

	for _, item in ipairs(menu) do
		item:Remove()
	end

	root:Unmount()
	scroll:Remove()
end)
