local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")

local function report(path)
	return function(item)
		item.Status.text:SetText("Selected: " .. path)
	end
end

local function build_file_menu(status)
	local function leaf(text, path)
		return MenuItem{Status = status, Text = text, OnClick = report(path)}
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

local function build_edit_menu(status)
	return {
		MenuItem{Status = status, Text = "Undo", OnClick = report("Edit > Undo")},
		MenuItem{Status = status, Text = "Redo", OnClick = report("Edit > Redo")},
		MenuSpacer{},
		MenuItem{
			Text = "Selection",
			Items = function()
				return {
					MenuItem{Status = status, Text = "Expand", OnClick = report("Edit > Selection > Expand")},
					MenuItem{Status = status, Text = "Shrink", OnClick = report("Edit > Selection > Shrink")},
				}
			end,
		},
	}
end

local function open_context_menu(button)
	local status = button.Status
	Panel.OpenContextMenu(
		{},
		{
			MenuItem{Status = status, Text = "Copy", OnClick = report("Context > Copy")},
			MenuItem{Status = status, Text = "Paste", OnClick = report("Context > Paste")},
			MenuSpacer{},
			MenuItem{
				Text = "Transform",
				Items = function()
					return {
						MenuItem{
							Status = status,
							Text = "Rotate",
							OnClick = report("Context > Transform > Rotate"),
						},
						MenuItem{
							Status = status,
							Text = "Scale",
							OnClick = report("Context > Transform > Scale"),
						},
					}
				end,
			},
			MenuItem{Text = "Delete (disabled)", Disabled = true},
		}
	)
end

local function on_surface_mouse_input(surface, button, press)
	if button == "button_2" and press then
		open_context_menu(surface)
		return true
	end
end

return {
	Name = "menus",
	Section = "Overlays",
	Order = 1,
	Create = function()
		local status = Text{
			Text = "Open a menu and pick an item.",
			Color = "text_disabled",
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		return kit.Page{
			Title = "Menus",
			Description = "Menu bars open context menus. Context menus nest to any depth, close on outside click or Escape, and stay on screen.",
		}{
			kit.Section{
				Title = "Menu bar",
				Description = "Hover across the top level buttons while a menu is open to switch menus.",
			}{
				MenuBar{
					Items = {
						{
							Text = "File",
							Items = function()
								return build_file_menu(status)
							end,
						},
						{
							Text = "Edit",
							Items = function()
								return build_edit_menu(status)
							end,
						},
						{Text = "Disabled", Disabled = true},
					},
					layout = {GrowWidth = 0},
				},
				status,
			},
			kit.Section{
				Title = "Context menu",
				Description = "Panel.OpenContextMenu(props, items). Right click the surface or use the button.",
			}{
				kit.Group{
					Button{
						Status = status,
						Text = "Open context menu",
						Mode = "outline",
						OnClick = open_context_menu,
					},
				},
				Frame{
					Status = status,
					Padding = "L",
					layout = {GrowWidth = 1, MinSize = Vec2(0, 96)},
					OnMouseInput = on_surface_mouse_input,
				}{
					Text{
						Text = "Right click anywhere in this frame",
						Color = "text_disabled",
						IgnoreMouseInput = true,
					},
				},
			},
		}
	end,
}
