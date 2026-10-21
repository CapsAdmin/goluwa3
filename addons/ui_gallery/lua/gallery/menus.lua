local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function build_file_menu(report)
	local function leaf(text, path)
		return MenuItem{Text = text, OnClick = ||->report(path)}
	end

	return {
		leaf("New file", "File > New file"),
		leaf("Open...", "File > Open"),
		MenuItem{
			Text = "Open recent",
			Items = function()
				return {
					leaf("ui_gallery.scene", "File > Open recent > ui_gallery.scene"),
					leaf("objects.layout", "File > Open recent > objects.layout"),
					MenuSpacer{},
					MenuItem{
						Text = "Archived",
						Items = function()
							return {
								leaf("winter_build_01", "File > Open recent > Archived > winter_build_01"),
								leaf("winter_build_02", "File > Open recent > Archived > winter_build_02"),
							}
						end,
					},
				}
			end,
		},
		MenuSpacer{},
		leaf("Save", "File > Save"),
		MenuItem{Text = "Save as... (disabled)", Disabled = true},
		MenuSpacer{},
		leaf("Quit", "File > Quit"),
	}
end

local function build_edit_menu(report)
	return {
		MenuItem{Text = "Undo", OnClick = ||->report("Edit > Undo")},
		MenuItem{Text = "Redo", OnClick = ||->report("Edit > Redo")},
		MenuSpacer{},
		MenuItem{
			Text = "Selection",
			Items = function()
				return {
					MenuItem{Text = "Expand", OnClick = ||->report("Edit > Selection > Expand")},
					MenuItem{Text = "Shrink", OnClick = ||->report("Edit > Selection > Shrink")},
				}
			end,
		},
	}
end

local function open_context_menu(report)
	Panel.OpenContextMenu(
		{},
		{
			MenuItem{Text = "Copy", OnClick = ||->report("Context > Copy")},
			MenuItem{Text = "Paste", OnClick = ||->report("Context > Paste")},
			MenuSpacer{},
			MenuItem{
				Text = "Transform",
				Items = function()
					return {
						MenuItem{Text = "Rotate", OnClick = ||->report("Context > Transform > Rotate")},
						MenuItem{Text = "Scale", OnClick = ||->report("Context > Transform > Scale")},
					}
				end,
			},
			MenuItem{Text = "Delete (disabled)", Disabled = true},
		}
	)
end

return {
	Name = "menus",
	Section = "Overlays",
	Order = 1,
	View = react.Component(
		||-> do
			local status, set_status = react.UseState("Open a menu and pick an item.")
			local report = react.UseCallback(|path|->set_status("Selected: " .. path), {})
			local bar_items = react.UseMemo(
				||->{
					{Text = "File", Items = ||->build_file_menu(report)},
					{Text = "Edit", Items = ||->build_edit_menu(report)},
					{Text = "Disabled", Disabled = true},
				},
				{}
			)
			return kit.Page{
				Title = "Menus",
				Description = "Menu bars open context menus. Context menus nest to any depth, close on outside click or Escape, and stay on screen.",
			}{
				kit.Section{
					Title = "Menu bar",
					Description = "Hover across the top level buttons while a menu is open to switch menus.",
				}{
					ui.MenuBar{Items = bar_items, layout = {GrowWidth = 0}},
					ui.Text{
						Text = status,
						Color = "text_disabled",
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
				kit.Section{
					Title = "Context menu",
					Description = "Panel.OpenContextMenu(props, items). Right click the surface or use the button.",
				}{
					kit.Group{
						ui.Button{
							Text = "Open context menu",
							Mode = "outline",
							OnClick = ||->open_context_menu(report),
						},
					},
					ui.Frame{
						Padding = "L",
						layout = {GrowWidth = 1, MinSize = Vec2(0, 96)},
						OnMouseInput = |_,button,press|-> do
							if button == "button_2" and press then
								open_context_menu(report)
								return true
							end
						end,
					}{
						ui.Text{
							Text = "Right click anywhere in this frame",
							Color = "text_disabled",
							IgnoreMouseInput = true,
						},
					},
				},
			}
		end
	),
}
