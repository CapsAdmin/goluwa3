local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Column = import("../elements/column.lua")
local ContextMenu = import("../elements/context_menu.lua")
local Frame = import("../elements/frame.lua")
local MenuBar = import("../widgets/menu_bar.lua")
local MenuItem = import("../elements/context_menu_item.lua")
local MenuSpacer = import("../elements/menu_spacer.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Row = import("../elements/row.lua")
local Text = import("../elements/text.lua")
local Dropdown = import("../widgets/dropdown.lua")
local theme = import("../theme.lua")

local function leaf(text)
	return function()
		print("Selected: " .. text)
	end
end

local function build_file_menu()
	return {
		MenuItem{Text = "New File", OnClick = leaf("File > New File")},
		MenuItem{Text = "Open...", OnClick = leaf("File > Open")},
		MenuItem{
			Text = "Open Recent",
			Items = function()
				return {
					MenuItem{
						Text = "project_scene.lua",
						OnClick = leaf("File > Open Recent > project_scene.lua"),
					},
					MenuItem{Text = "config.json", OnClick = leaf("File > Open Recent > config.json")},
					MenuSpacer(),
					MenuItem{
						Text = "Archived",
						Items = function()
							return {
								MenuItem{
									Text = "winter_build_01",
									OnClick = leaf("File > Open Recent > Archived > winter_build_01"),
								},
								MenuItem{
									Text = "winter_build_02",
									OnClick = leaf("File > Open Recent > Archived > winter_build_02"),
								},
							}
						end,
					},
				}
			end,
		},
		MenuSpacer(),
		MenuItem{Text = "Save", OnClick = leaf("File > Save")},
		MenuItem{Text = "Save As...", OnClick = leaf("File > Save As")},
		MenuItem{Text = "Exit", OnClick = leaf("File > Exit"), Disabled = true},
	}
end

return {
	Name = "menus",
	Create = function()
		local status_text
		local context_target
		local context_menu_ref

		local function build_edit_menu()
			return {
				MenuItem{Text = "Undo", OnClick = leaf("Edit > Undo"), Key = "Z"},
				MenuItem{Text = "Redo", OnClick = leaf("Edit > Redo"), Key = "Shift+Z"},
				MenuSpacer(),
				MenuItem{Text = "Cut", OnClick = leaf("Edit > Cut"), Key = "X"},
				MenuItem{Text = "Copy", OnClick = leaf("Edit > Copy"), Key = "C"},
				MenuItem{Text = "Paste", OnClick = leaf("Edit > Paste"), Key = "V"},
			}
		end

		local function build_view_menu()
			return {
				MenuItem{Text = "Zoom In", OnClick = leaf("View > Zoom In")},
				MenuItem{Text = "Zoom Out", OnClick = leaf("View > Zoom Out")},
				MenuItem{Text = "Reset Zoom", OnClick = leaf("View > Reset Zoom")},
				MenuSpacer(),
				MenuItem{
					Text = "Panels",
					Items = function()
						return {
							MenuItem{Text = "Inspector", OnClick = leaf("View > Panels > Inspector")},
							MenuItem{Text = "Console", OnClick = leaf("View > Panels > Console")},
							MenuItem{Text = "Output", OnClick = leaf("View > Panels > Output")},
						}
					end,
				},
				MenuItem{Text = "Toggle Fullscreen", OnClick = leaf("View > Toggle Fullscreen")},
			}
		end

		local function build_help_menu()
			return {
				MenuItem{Text = "Documentation", OnClick = leaf("Help > Documentation")},
				MenuItem{Text = "Keyboard Shortcuts", OnClick = leaf("Help > Keyboard Shortcuts")},
				MenuSpacer(),
				MenuItem{Text = "About", OnClick = leaf("Help > About")},
			}
		end

		local function show_context_menu(panel)
			if context_menu_ref and context_menu_ref:IsValid() then
				context_menu_ref:Remove()
			end

			local world_panel = Panel.World
			context_menu_ref = world_panel:Ensure(
				ContextMenu{
					Key = "DemoContextMenu",
					Position = Vec2(100, 100),
					Anchor = panel,
					AnchorPlacement = "right_top",
					OnClose = function(ent)
						ent:Remove()
						context_menu_ref = nil
					end,
				}{
					MenuItem{Text = "Open", OnClick = leaf("Context > Open")},
					MenuItem{Text = "Properties", OnClick = leaf("Context > Properties")},
					MenuSpacer(),
					MenuItem{Text = "Duplicate", OnClick = leaf("Context > Duplicate")},
					MenuItem{Text = "Delete", OnClick = leaf("Context > Delete"), Disabled = true},
				}
			)
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 14,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Menu Container Demo",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "All menus share a consistent container with padding, border, and background. The context menu below shows right-click interaction. Hover over context items to see the hover state and follow submenus.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Frame{
				Padding = Rect() + theme.GetPadding("S"),
				layout = {
					Direction = "y",
					GrowWidth = 1,
					FitHeight = true,
					ChildGap = 12,
					AlignmentX = "stretch",
				},
			}{
				Text{
					Text = "Context Menu (right-click the panel below)",
					Font = "body_strong S",
					IgnoreMouseInput = true,
				},
				Panel.New{
					Ref = function(self)
						context_target = self
						self:SetState("theme_role", "property_preview")
						self:SetState("preview_fill", "surface_alt")
						self:SetState("preview_outline", "border")
						self:SetState("preview_outline_alpha", 1)
						self:SetState("preview_radius", theme.GetRadius(XS))
					end,
					transform = {
						Size = Vec2(0, 60),
					},
					layout = {
						GrowWidth = 1,
						MinSize = Vec2(0, 60),
					},
					gui_element = {
						OnDraw = function(self)
							theme.active:Draw(self.Owner)
						end,
					},
					mouse_input = {
						OnMouseInput = function(self, button, press)
							if button == "button_2" and press then
								show_context_menu(self)
								return true
							end

							return false
						end,
					},
				}{
					Text{
						Text = "Right-click me for a context menu",
						IgnoreMouseInput = true,
						Color = "text_disabled",
						layout = {
							GrowWidth = 1,
							FitHeight = true,
							AlignmentX = "center",
							AlignmentY = "center",
						},
					},
				},
				Text{
					Text = "Menu Bar with File, Edit, View, and Help menus",
					Font = "body_strong S",
					IgnoreMouseInput = true,
				},
				MenuBar{
					Items = {
						{Text = "File", Items = build_file_menu},
						{Text = "Edit", Items = build_edit_menu},
						{Text = "View", Items = build_view_menu},
						{Text = "Help", Items = build_help_menu},
					},
					GrowWidth = false,
				},
				Text{
					Text = "Dropdown with searchable options",
					Font = "body_strong S",
					IgnoreMouseInput = true,
				},
				Dropdown{
					Text = "Select an option...",
					Options = {
						{Text = "Apple", Value = "apple"},
						{Text = "Banana", Value = "banana"},
						{Text = "Cherry", Value = "cherry"},
						{Text = "Date", Value = "date"},
						{Text = "Elderberry", Value = "elderberry"},
						{Text = "Fig", Value = "fig"},
						{Text = "Grape", Value = "grape"},
						{Text = "Honeydew", Value = "honeydew"},
						{Text = "Kiwi", Value = "kiwi"},
						{Text = "Lemon", Value = "lemon"},
						{Text = "Mango", Value = "mango"},
						{Text = "Nectarine", Value = "nectarine"},
						{Text = "Orange", Value = "orange"},
						{Text = "Papaya", Value = "papaya"},
						{Text = "Quince", Value = "quince"},
						{Text = "Raspberry", Value = "raspberry"},
						{Text = "Strawberry", Value = "strawberry"},
						{Text = "Tomato", Value = "tomato"},
						{Text = "Ugli Fruit", Value = "ugli"},
						{Text = "Watermelon", Value = "watermelon"},
					},
					Searchable = true,
					OnSelect = function(val, text)
						print("Selected: " .. text)
					end,
					layout = {
						GrowWidth = 1,
					},
					Padding = "XS",
				},
			},
		}
	end,
}
