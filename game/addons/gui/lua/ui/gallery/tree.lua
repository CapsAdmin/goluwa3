local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("../widgets/button.lua")
local Checkbox = import("../elements/checkbox.lua")
local Column = import("../elements/column.lua")
local Frame = import("../elements/frame.lua")
local Row = import("../elements/row.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Splitter = import("../elements/splitter.lua")
local SVG = import("../elements/svg.lua")
local Text = import("../elements/text.lua")
local Tree = import("../widgets/tree.lua")
local ICON_SOURCES = {
	folder = "https://api.iconify.design/ic/baseline-folder.svg",
	file = "https://api.iconify.design/ic/round-insert-drive-file.svg",
}

local function make_demo_files(prefix, label_prefix, count, description_prefix)
	local out = {}

	for i = 1, count do
		out[i] = {
			Key = prefix .. "/" .. label_prefix .. i .. ".lua",
			Text = label_prefix .. i .. ".lua",
			Kind = "file",
			Description = description_prefix .. " " .. i .. ".",
		}
	end

	return out
end

local function make_demo_pngs(prefix, label_prefix, count, description_prefix)
	local out = {}

	for i = 1, count do
		out[i] = {
			Key = prefix .. "/" .. label_prefix .. i .. ".png",
			Text = label_prefix .. i .. ".png",
			Kind = "file",
			Description = description_prefix .. " " .. i .. ".",
		}
	end

	return out
end

local function build_demo_items(show_hidden)
	local hidden_nodes = show_hidden and
		{
			{
				Key = "project/.gitignore",
				Text = ".gitignore",
				Kind = "file",
				Description = "Ignored paths for generated assets, logs, and temporary captures.",
			},
			{
				Key = "project/.editorconfig",
				Text = ".editorconfig",
				Kind = "file",
				Description = "Formatting defaults shared across the GUI addon and the rest of the repo.",
			},
		} or
		{}
	local extra_element_files = make_demo_files(
		"project/lua/ui/elements",
		"inspector_panel_",
		10,
		"Additional element fixture used to make the tree demo tall enough to scroll"
	)
	local extra_gallery_files = make_demo_files(
		"project/lua/ui/gallery",
		"stress_case_",
		8,
		"Additional gallery page fixture used to produce more descendants in the tree demo"
	)
	local extra_test_files = make_demo_files("project/lua/tests", "tree_case_", 14, "Extra tree coverage fixture")
	local extra_icon_files = make_demo_pngs(
		"project/assets/icons",
		"folder_variant_",
		12,
		"Extra icon fixture for the scrolling tree preview"
	)
	return {
		{
			Key = "project",
			Text = "gui-addon",
			Kind = "folder",
			Expanded = true,
			Description = "Sample project tree for the gallery. Selection updates the inspector, and branch expansion state is preserved by key.",
			Children = {
				{
					Key = "project/lua",
					Text = "lua",
					Kind = "folder",
					Expanded = true,
					Description = "Runtime Lua sources for the addon.",
					Children = {
						{
							Key = "project/lua/ui",
							Text = "ui",
							Kind = "folder",
							Expanded = true,
							Description = "UI toolkit code and gallery pages.",
							Children = {
								{
									Key = "project/lua/ui/elements",
									Text = "elements",
									Kind = "folder",
									Expanded = true,
									Description = "Reusable UI controls such as buttons, splitters, editors, and now tree views.",
									Children = {
										{
											Key = "project/lua/ui/elements/tree.lua",
											Text = "tree.lua",
											Kind = "file",
											Description = "The new data-driven tree element with keyed expansion, selection, and rebuild helpers.",
										},
										{
											Key = "project/lua/ui/elements/collapsible.lua",
											Text = "collapsible.lua",
											Kind = "file",
											Description = "Animated container used as a reference for disclosure-style interactions.",
										},
										unpack(extra_element_files),
									},
								},
								{
									Key = "project/lua/ui/gallery",
									Text = "gallery",
									Kind = "folder",
									Expanded = true,
									Description = "Example pages used by the in-engine UI gallery browser.",
									Children = {
										{
											Key = "project/lua/ui/gallery/tree.lua",
											Text = "tree.lua",
											Kind = "file",
											Description = "This demo page. It shows selection, expansion, hidden-node refresh, and programmatic focus.",
										},
										unpack(extra_gallery_files),
									},
								},
							},
						},
						{
							Key = "project/lua/tests",
							Text = "tests",
							Kind = "folder",
							Description = "Widget and interaction coverage for the addon.",
							Children = {
								{
									Key = "project/lua/tests/tree_spec.lua",
									Text = "tree_spec.lua",
									Kind = "file",
									Description = "Placeholder test target for tree-specific behavior such as expansion and selection.",
								},
								unpack(extra_test_files),
							},
						},
					},
				},
				{
					Key = "project/assets",
					Text = "assets",
					Kind = "folder",
					Description = "Artwork, icons, and sound references used by the demo.",
					Children = {
						{
							Key = "project/assets/icons",
							Text = "icons",
							Kind = "folder",
							Description = "Shared icon atlases and glyph textures.",
							Children = {
								{
									Key = "project/assets/icons/disclosure.png",
									Text = "disclosure.png",
									Kind = "file",
									Description = "A stand-in asset matching the expand/collapse affordance used by the tree rows.",
								},
								unpack(extra_icon_files),
							},
						},
					},
				},
				unpack(hidden_nodes),
			},
		},
	}
end

local function find_node_by_key(nodes, key)
	for _, node in ipairs(nodes or {}) do
		if node.Key == key then return node end

		local found = find_node_by_key(node.Children, key)

		if found then return found end
	end

	return nil
end

local function find_node_location(nodes, key, parent)
	for index, node in ipairs(nodes or {}) do
		if node.Key == key then return nodes, index, node, parent end

		local found_nodes, found_index, found_node, found_parent = find_node_location(node.Children, key, node)

		if found_nodes then return found_nodes, found_index, found_node, found_parent end
	end

	return nil
end

local function move_node(nodes, drop_info)
	local source_nodes, source_index, source_node = find_node_location(nodes, drop_info.source_key)

	if not source_nodes or not source_node then return false end

	table.remove(source_nodes, source_index)
	local _, target_index, target_node = find_node_location(nodes, drop_info.target_key)

	if not target_node then
		table.insert(source_nodes, source_index, source_node)
		return false
	end

	if drop_info.position == "inside" then
		target_node.Children = target_node.Children or {}
		target_node.Expanded = true
		target_node.Children[#target_node.Children + 1] = source_node
		return true
	end

	local target_nodes
	target_nodes, target_index = find_node_location(nodes, drop_info.target_key)

	if not target_nodes then
		table.insert(source_nodes, source_index, source_node)
		return false
	end

	local insert_index = target_index + (drop_info.position == "after" and 1 or 0)
	table.insert(target_nodes, insert_index, source_node)
	return true
end

local function format_drop_message(drop_info)
	local source_label = drop_info.source_node and drop_info.source_node.Text or drop_info.source_key
	local target_label = drop_info.target_node and drop_info.target_node.Text or drop_info.target_key

	if drop_info.position == "inside" then
		return string.format("Moved %s into %s.", source_label, target_label)
	end

	return string.format("Moved %s %s %s.", source_label, drop_info.position, target_label)
end

local function set_text(panel, value)
	if panel and panel:IsValid() then panel.text:SetText(value or "") end
end

return {
	Name = "tree",
	Create = function()
		local state = {
			show_hidden = false,
			selected_key = "project/lua/ui/elements/tree.lua",
			items = build_demo_items(false),
			last_drop = "Drag rows by their labels. Drop near an edge to place before or after, or in the middle of a folder to move into it.",
		}
		local tree_view
		local detail_title
		local detail_meta
		local detail_body
		local drag_status

		local function refresh_details(node)
			node = node or find_node_by_key(state.items, state.selected_key) or state.items[1]
			state.selected_key = node.Key
			local child_count = #(node.Children or {})
			local meta = string.upper(node.Kind or "item") .. "  |  " .. node.Key

			if child_count > 0 then
				meta = meta .. "  |  " .. child_count .. " child" .. (child_count == 1 and "" or "ren")
			end

			set_text(detail_title, node.Text)
			set_text(detail_meta, meta)
			set_text(detail_body, node.Description)
		end

		local function rebuild_tree()
			state.items = build_demo_items(state.show_hidden)

			if not find_node_by_key(state.items, state.selected_key) then
				state.selected_key = "project"
			end

			if tree_view and tree_view:IsValid() then
				tree_view:SetItems(state.items)
				tree_view:ExpandToKey(state.selected_key)
				tree_view:SetSelectedKey(state.selected_key)
			end

			refresh_details(find_node_by_key(state.items, state.selected_key))
			set_text(drag_status, state.last_drop)
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 10,
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Tree Widget",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "This demo shows a keyed tree view with expandable branches, selection, programmatic focus, live item replacement, and drag-and-drop moves. Drag a row by its label. Drop on the middle of a folder to move into it, or near the top or bottom edge of any row to place before or after it.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
					AlignmentX = "stretch",
				},
			}{
				Button{
					Text = "Expand All",
					OnClick = function()
						if tree_view and tree_view:IsValid() then tree_view:ExpandAll() end
					end,
				},
				Button{
					Text = "Collapse All",
					Mode = "outline",
					OnClick = function()
						if tree_view and tree_view:IsValid() then tree_view:CollapseAll() end
					end,
				},
				Button{
					Text = "Focus tree.lua",
					Mode = "outline",
					OnClick = function()
						state.selected_key = "project/lua/ui/elements/tree.lua"

						if tree_view and tree_view:IsValid() then
							tree_view:ExpandToKey(state.selected_key)
							tree_view:SetSelectedKey(state.selected_key)
						end

						refresh_details(find_node_by_key(state.items, state.selected_key))
					end,
				},
				Row{
					layout = {
						FitWidth = true,
						ChildGap = 8,
						AlignmentY = "center",
						GrowWidth = 1,
					},
				}{
					Checkbox{
						Value = state.show_hidden,
						OnChange = function(value)
							state.show_hidden = value
							rebuild_tree()
						end,
					},
					Text{
						Text = "Show hidden files",
						IgnoreMouseInput = true,
					},
				},
			},
			Text{
				Ref = function(self)
					drag_status = self
					set_text(self, state.last_drop)
				end,
				Text = "",
				Color = "text_disabled",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Splitter{
				InitialSize = 280,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 360),
					MaxSize = Vec2(0, 360),
				},
			}{
				Frame{
					Padding = "XS",
					layout = {
						GrowHeight = 1,
						GrowWidth = 1,
					},
				}{
					ScrollablePanel{
						layout = {
							GrowHeight = 1,
							GrowWidth = 1,
						},
						Padding = "XXS",
					}{
						Tree{
							Items = state.items,
							SelectedKey = state.selected_key,
							GetNodePanel = function(node, path, key, selected, has_children)
								return SVG{
									Source = has_children and ICON_SOURCES.folder or ICON_SOURCES.file,
									Color = selected and "text_on_accent" or "text",
									Padding = Rect() + 1,
									Size = Vec2(16, 16),
									MinSize = Vec2(16, 16),
									MaxSize = Vec2(16, 16),
									layout = {
										SelfAlignmentY = "center",
									},
									mouse_input = {
										IgnoreMouseInput = true,
									},
								}
							end,
							Ref = function(self)
								tree_view = self
								rebuild_tree()
							end,
							OnSelect = function(node, key)
								state.selected_key = key
								refresh_details(node)
							end,
							CanDropInside = function(node)
								return node.Kind == "folder"
							end,
							OnDrop = function(drop_info)
								if not move_node(state.items, drop_info) then return false end

								state.selected_key = drop_info.source_key
								state.last_drop = format_drop_message(drop_info)

								if tree_view and tree_view:IsValid() then
									tree_view:SetItems(state.items)
									tree_view:ExpandToKey(state.selected_key)
									tree_view:SetSelectedKey(state.selected_key)
								end

								refresh_details(find_node_by_key(state.items, state.selected_key))
								set_text(drag_status, state.last_drop)
								return true
							end,
							layout = {
								GrowWidth = 1,
								FitHeight = true,
							},
						},
					},
				},
				Frame{
					Padding = "S",
					layout = {
						GrowHeight = 1,
						GrowWidth = 1,
					},
				}{
					Column{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							AlignmentX = "stretch",
							ChildGap = 8,
						},
					}{
						Text{
							Ref = function(self)
								detail_title = self
								refresh_details(find_node_by_key(state.items, state.selected_key))
							end,
							Text = "",
							Font = "body_strong S",
							IgnoreMouseInput = true,
						},
						Text{
							Ref = function(self)
								detail_meta = self
								refresh_details(find_node_by_key(state.items, state.selected_key))
							end,
							Text = "",
							Color = "text_disabled",
							IgnoreMouseInput = true,
							layout = {
								GrowWidth = 1,
							},
						},
						Text{
							Text = "Inspector",
							Font = "body_strong S",
							IgnoreMouseInput = true,
						},
						Text{
							Ref = function(self)
								detail_body = self
								refresh_details(find_node_by_key(state.items, state.selected_key))
							end,
							Text = "",
							Wrap = true,
							IgnoreMouseInput = true,
							layout = {
								GrowWidth = 1,
							},
						},
						Text{
							Text = "Integration Notes",
							Font = "body_strong S",
							IgnoreMouseInput = true,
						},
						Text{
							Text = "Use stable keys if you want expansion state to survive item replacement. The element exposes SetItems, SetSelectedKey, ExpandAll, CollapseAll, ExpandToKey, Rebuild, and OnDrop for host-controlled rearrangement.",
							Wrap = true,
							IgnoreMouseInput = true,
							layout = {
								GrowWidth = 1,
							},
						},
					},
				},
			},
		}
	end,
}
