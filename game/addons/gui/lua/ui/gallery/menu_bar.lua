local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local MenuBar = import("../widgets/menu_bar.lua")
local MenuItem = import("../elements/context_menu_item.lua")
local MenuSpacer = import("../elements/menu_spacer.lua")
local Text = import("../elements/text.lua")
local theme = import("../theme.lua")
return {
	Name = "menu_bar",
	Create = function()
		local status_text = NULL
		local status = "Use the menu bar above. Hover across top-level buttons while a menu is open to switch menus, and follow the nested arrows for submenus."

		local function set_status(text)
			status = text

			if status_text:IsValid() then status_text.text:SetText(status) end
		end

		local function leaf(text)
			return function()
				set_status("Selected: " .. text)
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
								Text = "ui_gallery.scene",
								OnClick = leaf("File > Open Recent > ui_gallery.scene"),
							},
							MenuItem{
								Text = "prototype.layout",
								OnClick = leaf("File > Open Recent > prototype.layout"),
							},
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
				MenuSpacer(),
				MenuItem{Text = "Quit", OnClick = leaf("File > Quit")},
			}
		end

		local function build_edit_menu()
			return {
				MenuItem{Text = "Undo", OnClick = leaf("Edit > Undo")},
				MenuItem{Text = "Redo", OnClick = leaf("Edit > Redo")},
				MenuSpacer(),
				MenuItem{
					Text = "Selection",
					Items = function()
						return {
							MenuItem{Text = "Expand", OnClick = leaf("Edit > Selection > Expand")},
							MenuItem{Text = "Shrink", OnClick = leaf("Edit > Selection > Shrink")},
							MenuItem{
								Text = "Convert To",
								Items = function()
									return {
										MenuItem{Text = "Group", OnClick = leaf("Edit > Selection > Convert To > Group")},
										MenuItem{Text = "Prefab", OnClick = leaf("Edit > Selection > Convert To > Prefab")},
									}
								end,
							},
						}
					end,
				},
			}
		end

		local function build_view_menu()
			return {
				MenuItem{Text = "Zoom In", OnClick = leaf("View > Zoom In")},
				MenuItem{Text = "Zoom Out", OnClick = leaf("View > Zoom Out")},
				MenuItem{
					Text = "Panels",
					Items = function()
						return {
							MenuItem{Text = "Inspector", OnClick = leaf("View > Panels > Inspector")},
							MenuItem{Text = "Profiler", OnClick = leaf("View > Panels > Profiler")},
							MenuItem{Text = "Console", OnClick = leaf("View > Panels > Console")},
						}
					end,
				},
			}
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
				Text = "Menubar buttons are outlined, open context menus on click, switch to siblings on hover while a root menu is open, and support nested submenus to arbitrary depth.",
				Wrap = true,
				WrapToParent = true,
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
				MenuBar{
					Items = {
						{Text = "File", Items = build_file_menu},
						{Text = "Edit", Items = build_edit_menu},
						{Text = "View", Items = build_view_menu},
						{
							Text = "Help",
							Items = function()
								return {
									MenuItem{Text = "Documentation", OnClick = leaf("Help > Documentation")},
									MenuItem{Text = "Report Issue", OnClick = leaf("Help > Report Issue")},
								}
							end,
						},
					},
					GrowWidth = false,
				},
				Text{
					Ref = function(self)
						status_text = self
						self.text:SetText(status)
					end,
					Text = status,
					Wrap = true,
					WrapToParent = true,
					layout = {
						GrowWidth = 1,
					},
				},
			},
		}
	end,
}
