local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Tree = import("goluwa/render2d/ui/widgets/tree.lua")
local Checkbox = import("goluwa/render2d/ui/elements/checkbox.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local icons = {
	folder = "https://api.iconify.design/ic/baseline-folder.svg",
	file = "https://api.iconify.design/ic/round-insert-drive-file.svg",
}

local function files(prefix, name, extension, count, description)
	local out = {}

	for index = 1, count do
		out[index] = {
			Key = prefix .. "/" .. name .. index .. extension,
			Text = name .. index .. extension,
			Kind = "file",
			Description = description .. " #" .. index,
		}
	end

	return out
end

local function folder(key, text, description, children, expanded)
	return {
		Key = key,
		Text = text,
		Kind = "folder",
		Expanded = expanded,
		Description = description,
		Children = children,
	}
end

local function build_items(show_hidden)
	local elements = files("project/ui/elements", "element_", ".lua", 12, "A UI element source file")
	elements[#elements + 1] = {
		Key = "project/ui/elements/tree.lua",
		Text = "tree.lua",
		Kind = "file",
		Description = "The data driven tree widget with keyed expansion, selection, drag and drop and virtualized rows.",
	}
	local project = {
		folder(
			"project/ui",
			"ui",
			"UI toolkit sources.",
			{
				folder("project/ui/elements", "elements", "Reusable controls.", elements, true),
				folder(
					"project/ui/widgets",
					"widgets",
					"Composite widgets.",
					files("project/ui/widgets", "widget_", ".lua", 8, "A widget source file"),
					true
				),
			},
			true
		),
		folder(
			"project/tests",
			"tests",
			"Widget and interaction tests.",
			files("project/tests", "case_", ".lua", 10, "A test case")
		),
		folder(
			"project/assets",
			"assets",
			"Artwork and icons.",
			files("project/assets", "icon_", ".png", 12, "An icon")
		),
	}

	if show_hidden then
		project[#project + 1] = {
			Key = "project/.gitignore",
			Text = ".gitignore",
			Kind = "file",
			Description = "Ignored paths.",
		}
		project[#project + 1] = {
			Key = "project/.editorconfig",
			Text = ".editorconfig",
			Kind = "file",
			Description = "Editor settings.",
		}
	end

	return {
		folder(
			"project",
			"gui-addon",
			"The sample project. Selection updates the inspector and expansion is preserved by key.",
			project,
			true
		),
	}
end

local function find_location(nodes, key)
	for index, node in ipairs(nodes) do
		if node.Key == key then return nodes, index, node end

		local found_nodes, found_index, found_node = find_location(node.Children or {}, key)

		if found_nodes then return found_nodes, found_index, found_node end
	end
end

local function move_node(items, drop)
	local source_nodes, source_index, source = find_location(items, drop.source_key)

	if not source then return false end

	table.remove(source_nodes, source_index)
	local target_nodes, target_index, target = find_location(items, drop.target_key)

	if not target then
		table.insert(source_nodes, source_index, source)
		return false
	end

	if drop.position == "inside" then
		target.Children = target.Children or {}
		target.Expanded = true
		target.Children[#target.Children + 1] = source
	else
		table.insert(target_nodes, target_index + (drop.position == "after" and 1 or 0), source)
	end

	return true
end

local function show_node(page, node)
	local children = #(node.Children or {})
	page.title.text:SetText(node.Text)
	page.meta.text:SetText(
		string.upper(node.Kind) .. "  |  " .. node.Key .. (
				children > 0 and
				"  |  " .. children .. " children" or
				""
			)
	)
	page.body.text:SetText(node.Description)
end

local function node_icon(node, path, key, selected, has_children)
	return SVG{
		Source = has_children and icons.folder or icons.file,
		Color = selected and "text_on_accent" or "text",
		Size = Vec2(16, 16),
		MinSize = Vec2(16, 16),
		MaxSize = Vec2(16, 16),
		IgnoreMouseInput = true,
		layout = {SelfAlignmentY = "center"},
	}
end

return {
	Name = "tree",
	Section = "Data",
	Order = 1,
	Create = function()
		local page = {items = build_items(false), selected = "project/ui/elements/tree.lua"}
		page.title = Text{Text = "", Font = "body_strong M", IgnoreMouseInput = true}
		page.meta = Text{
			Text = "",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		page.body = Text{Text = "", Wrap = true, IgnoreMouseInput = true, layout = {GrowWidth = 1}}
		page.drag = Text{
			Text = "Drag a row by its label. Drop near an edge to place before or after, or in the middle of a folder to move into it.",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		page.tree = Tree{
			Items = page.items,
			SelectedKey = page.selected,
			OnGetNodePanel = node_icon,
			OnSelect = function(node, key)
				page.selected = key
				show_node(page, node)
			end,
			OnCanDropInside = function(node)
				return node.Kind == "folder"
			end,
			OnDrop = function(drop)
				if not move_node(page.items, drop) then return false end

				page.selected = drop.source_key
				page.drag.text:SetText(
					string.format(
						"Moved %s %s %s.",
						drop.source_node.Text,
						drop.position == "inside" and "into" or drop.position,
						drop.target_node.Text
					)
				)
				page.tree:SetItems(page.items)
				page.tree:ExpandToKey(page.selected)
				page.tree:SetSelectedKey(page.selected)
				show_node(page, drop.source_node)
				return true
			end,
		}
		local hidden = Checkbox{
			Text = "Show hidden files",
			Value = false,
			OnChange = function(value)
				page.items = build_items(value)
				page.tree:SetItems(page.items)
				page.tree:ExpandToKey(page.selected)
				page.tree:SetSelectedKey(page.selected)
			end,
		}
		page.tree:ExpandToKey(page.selected)
		local _, _, selected = find_location(page.items, page.selected)
		show_node(page, selected)
		return kit.Page{
			Title = "Tree",
			Description = "A keyed tree view with expandable branches, selection, programmatic focus, live item replacement and drag and drop. Rows are created lazily as they scroll into view.",
		}{
			kit.Section{
				Title = "File browser",
				Description = "Items are plain tables: Key, Text, Children, Expanded. Callbacks such as OnGetNodePanel, OnSelect and OnDrop customize it.",
			}{
				kit.Group{
					Button{
						Text = "Expand all",
						OnClick = function()
							page.tree:ExpandAll()
						end,
					},
					Button{
						Text = "Collapse all",
						Mode = "outline",
						OnClick = function()
							page.tree:CollapseAll()
						end,
					},
					Button{
						Text = "Focus tree.lua",
						Mode = "outline",
						OnClick = function()
							page.tree:ExpandToKey("project/ui/elements/tree.lua")
							page.tree:SetSelectedKey("project/ui/elements/tree.lua")
							page.tree:EnsureVisible("project/ui/elements/tree.lua")
						end,
					},
					hidden,
				},
				page.drag,
				Splitter{InitialSize = 300, layout = {MinSize = Vec2(0, 360), MaxSize = Vec2(0, 360)}}{
					Frame{Padding = "XS", layout = {GrowWidth = 1, GrowHeight = 1}}{
						ScrollablePanel{layout = {GrowWidth = 1, GrowHeight = 1}, Padding = "XXS"}{page.tree},
					},
					Frame{Padding = "S", layout = {GrowWidth = 1, GrowHeight = 1}}{
						Column{
							layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch", ChildGap = "XS"},
						}{
							page.title,
							page.meta,
							page.body,
						},
					},
				},
			},
		}
	end,
}
