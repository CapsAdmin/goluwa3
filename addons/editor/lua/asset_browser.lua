local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local react = import("goluwa/render2d/ui/react.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local Tree = react.Element(import("goluwa/render2d/ui/widgets/tree.lua"))
local Button = react.Element(import("goluwa/render2d/ui/widgets/button.lua"))
local TabBar = react.Element(import("goluwa/render2d/ui/widgets/tab_bar.lua"))
local Icon = react.Element(import("goluwa/render2d/ui/elements/icon.lua"))
local Splitter = react.Element(import("goluwa/render2d/ui/elements/splitter.lua"))
local ScrollablePanel = react.Element(import("goluwa/render2d/ui/elements/scrollable_panel.lua"))
local VirtualGrid = react.Element(import("goluwa/render2d/ui/elements/virtual_grid.lua"))
local Slider = react.Element(import("goluwa/render2d/ui/elements/slider.lua"))
local Column = react.Element(import("goluwa/render2d/ui/elements/column.lua"))
local Row = react.Element(import("goluwa/render2d/ui/elements/row.lua"))
local Frame = react.Element(import("goluwa/render2d/ui/elements/frame.lua"))
local Text = react.Element(import("goluwa/render2d/ui/elements/text.lua"))
local TextEdit = react.Element(import("goluwa/render2d/ui/elements/text_edit.lua"))
local Clickable = react.Element(import("goluwa/render2d/ui/elements/clickable.lua"))
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local ErrorBoundary = react.ErrorBoundary
local TextureViewer = import("lua/texture_viewer.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local asset_info = import("lua/asset_info.lua")
local prefab_tools = import("lua/prefab_tools.lua")
local editor_history = import("lua/editor_history.lua")
local picker = import("lua/picker.lua")
local kit = import("lua/editor_kit.lua")
local ViewerWindow = kit.ViewerWindow
local Canvas = kit.Canvas
local DEFAULT_CATEGORIES = {"models", "textures", "materials", "prefabs", "components"}
local CATEGORY_ICONS = {
	models = "cube",
	textures = "image",
	materials = "material",
	prefabs = "layers",
	components = "component",
}
local PICK_MODES = {models = "model", prefabs = "prefab", materials = "material", textures = "texture"}
local WINDOW_SIZE = Vec2(1280, 760)
local folder_icon_box = Vec2()
local WORLD_PREVIEW = {status = "loading"}
local LABEL_HEIGHT = 36
local DETAIL_PREVIEW_SIZE = 320
local CHANNEL_SIZE = 64
local open_windows = 0
local colors = {}

local function refresh_colors()
	local active = theme.active

	if colors.theme == active then return end

	colors.theme = active
	colors.text = active:GetColor("text")
	colors.text_disabled = active:GetColor("text_disabled")
	colors.primary = active:GetColor("primary")
	colors.surface = active:GetColor("surface")
	colors.surface_alt = active:GetColor("surface_alt")
	colors.border = active:GetColor("border")
	colors.negative = active:GetColor("negative")
	colors.folder = active:GetColor("yellow")
	colors.preview_background = {r = 0.2, g = 0.21, b = 0.24, a = 1}
	colors.preview_text = {r = 0.78, g = 0.79, b = 0.82, a = 1}
	colors.white = {r = 1, g = 1, b = 1, a = 1}
	colors.icon = Color(0.78, 0.79, 0.82, 1)
	colors.tile_fill = {
		r = colors.surface_alt.r,
		g = colors.surface_alt.g,
		b = colors.surface_alt.b,
		a = 0.7,
	}
	colors.tile_fill_hover = {
		r = colors.surface_alt.r,
		g = colors.surface_alt.g,
		b = colors.surface_alt.b,
		a = 1,
	}
	colors.badge_fill = {r = 0, g = 0, b = 0, a = 0.55}
	colors.pulse = {r = colors.text.r, g = colors.text.g, b = colors.text.b, a = 0.15}
	colors.font = active:GetFont("body", "S")
	colors.font_strong = active:GetFont("body_strong", "S")
	colors.font_small = active:GetFont("body", "XS")
end

local function draw_text(font, text, x, y, color)
	render2d.SetTexture(nil)
	render2d.PushColor(color.r, color.g, color.b, 1)
	render2d.PushAlphaMultiplier(color.a)
	font:DrawText(text, x, y, 0)
	render2d.PopAlphaMultiplier()
	render2d.PopColor()
end

local function draw_centered_text(font, text, x, y, w, h, color)
	local tw, th = font:GetTextSize(text)
	draw_text(font, text, x + (w - tw) / 2, y + (h - th) / 2, color)
end

local function get_folder_icon(node, expanded)
	return expanded and "folder_open" or "folder"
end

local function get_selected_object()
	local target = _G.SELECTED_OBJECT

	if target and target.IsValid and target:IsValid() then return target end
end

local function get_selected_entity()
	local target = _G.SELECTED_OBJECT

	if
		target and
		target.IsValid and
		target:IsValid() and
		target.transform and
		not target.transform.Is2D
	then
		return target
	end
end

-- the components an object can have are virtual assets, the registry depends on what is edited (3D entity or 2D panel)
local function sync_component_assets(target, hide_present)
	for path in pairs(assets.virtual_assets) do
		if path:starts_with("components/") then assets.UnregisterVirtualAsset(path) end
	end

	for name, meta in pairs(target and target:GetValidComponents() or Entity.GetValidComponents()) do
		if not (hide_present and target:HasComponent(name)) then
			assets.RegisterVirtualAsset(
				assets.categories.components.get_path(name),
				{
					category = "components",
					kind = "component",
					load = function()
						return meta
					end,
				}
			)
		end
	end

	assets.InvalidateIndex("components")
end

local function prepare_category(name, props)
	if name == "textures" then assets.RefreshInternalTextures() end

	if name == "components" then
		sync_component_assets(props.ComponentTarget ?? get_selected_object(), props.ComponentTarget ~= nil)
	end
end

local function spawn_model(entry)
	local camera = render3d.GetCamera()
	local entity = Entity.New{Name = entry.name}
	entity:AddComponent("transform"):SetPosition(camera:GetPosition() + camera:GetRotation():GetForward() * 3)
	entity:AddComponent("model", {ModelPath = entry.path})
	editor_history.RecordCreate("spawn " .. entry.name, entity)
	event.Call("EditorSelect", entity)
	return entity
end

local function apply_model(target, entry)
	editor_history.Begin("use " .. entry.name .. " as model of " .. target:GetName())

	if target:HasComponent("model") then
		editor_history.SetProperty(target.model, "ModelPath", entry.path)
	else
		editor_history.SetProperty(editor_history.EnsureComponent(target, "visual"), "ModelPath", entry.path)
	end

	editor_history.End()
end

local function apply_material(target, entry)
	editor_history.Begin("apply " .. entry.name .. " to " .. target:GetName())
	editor_history.SetProperty(editor_history.EnsureComponent(target, "visual"), "MaterialOverridePath", entry.path)
	editor_history.End()
end

local function place_prefab(entry)
	local entity = prefab_tools.Place(entry.name)
	event.Call("EditorSelect", entity)
	return entity
end

-- only an entity that already is a prefab instance can switch prefab
local function get_selected_instance()
	local target = get_selected_entity()
	return target and target.prefab and target or nil
end

local function get_folder_node_chain(folder)
	local chain = {folder}
	local text = folder.name

	while #folder.entries == 0 and #folder.folders == 1 do
		folder = folder.folders[1]
		chain[#chain + 1] = folder
		text = text .. "/" .. folder.name
	end

	return chain, text
end

-- the material the selected asset's preview loaded, so the viewers and the debug info do not load it again
local function get_detail_material(view, entry)
	local detail = view.detail

	if detail and detail.entry == entry then return detail.material end
end

local function is_viewable_model(entry)
	return entry.category == "models" and RENDER_3D and entry.extension ~= ".bsp"
end

local function open_model_viewer(entry)
	import("lua/model_viewer.lua")(entry)
end

local function open_material_viewer(entry, view)
	import("lua/material_viewer.lua")(
		entry.material or
			get_detail_material(view, entry) or
			previews.LoadMaterial(entry),
		entry.name
	)
end

local function open_texture_viewer(entry)
	local texture = assets.GetTexture(entry.path)

	if texture then TextureViewer(texture, entry.path) end
end

local SourceViewer = react.Component(|props| -> ViewerWindow{Title = props.Title, Size = Vec2(760, 560)}{
	TextEdit{
		Text = props.Source,
		Editable = false,
		Wrap = false,
		ScrollX = true,
		ScrollY = true,
		Size = Vec2(720, 500),
		MinSize = Vec2(100, 100),
		MaxSize = Vec2(0, 0),
		layout = {GrowWidth = 1, GrowHeight = 1},
	},
})

local function open_source_viewer(entry)
	local source = asset_info.ReadSource(entry)

	if not source then return end

	kit.OpenOnce(
		"AssetSourceViewer/" .. entry.path,
		|| -> react.Mount(SourceViewer{Title = entry.path:upper(), Source = source}, Panel.World):GetEntity()
	)
end

-- api is what the browser hands to its callbacks: picking, pick(entry), navigate(folder) and view (the detail view)
local function activate_item(item, api)
	if item.is_folder then
		api.navigate(item.folder)

		return
	end

	if api.picking then return api.pick(item) end

	if is_viewable_model(item) then return open_model_viewer(item) end

	if item.category == "textures" then open_texture_viewer(item) end

	if item.category == "materials" then open_material_viewer(item, api.view) end
end

local function open_context_menu(item, api)
	if item.is_folder then
		Panel.OpenContextMenu(
			{
				OnClose = function(self)
					self:Remove()
				end,
			},
			{
				MenuItem{
					Text = "Open",
					Icon = "folder_open",
					OnClick = function()
						api.navigate(item.folder)
					end,
				},
				MenuItem{
					Text = "Copy path",
					Icon = "copy",
					OnClick = function()
						clipboard.Set(item.folder.path)
					end,
				},
			}
		)
		return
	end

	local entry = item
	Panel.OpenContextMenu(
		{
			OnClose = function(self)
				self:Remove()
			end,
		},
		{
			api.picking and
			MenuItem{
				Text = "Select",
				Icon = "check",
				OnClick = function()
					api.pick(entry)
				end,
			} or
			nil,
			MenuItem{
				Text = "Copy path",
				Icon = "copy",
				OnClick = function()
					clipboard.Set(entry.path)
				end,
			},
			MenuItem{
				Text = "Copy name",
				Icon = "copy",
				OnClick = function()
					clipboard.Set(entry.name)
				end,
			},
			(
				entry.kind == "lua" or
				entry.extension == ".vmt" or
				entry.extension == ".mtl"
			)
			and
			MenuItem{
				Text = "View source",
				Icon = "code",
				OnClick = function()
					open_source_viewer(entry)
				end,
			} or
			nil,
			entry.category == "textures" and
			MenuItem{
				Text = "Open in texture viewer",
				Icon = "image",
				OnClick = function()
					open_texture_viewer(entry)
				end,
			} or
			nil,
			is_viewable_model(entry) and
			MenuItem{
				Text = "Open in model viewer",
				Icon = "cube",
				OnClick = function()
					open_model_viewer(entry)
				end,
			} or
			nil,
			is_viewable_model(entry) and
			MenuItem{
				Text = "Spawn in front of camera",
				Icon = "place",
				OnClick = function()
					spawn_model(entry)
				end,
			} or
			nil,
			entry.category == "models" and
			get_selected_entity() and
			MenuItem{
				Text = "Use as model of selected entity",
				Icon = "arrow_right",
				OnClick = function()
					apply_model(get_selected_entity(), entry)
				end,
			} or
			nil,
			entry.category == "materials" and
			get_selected_entity() and
			MenuItem{
				Text = "Apply to selected entity",
				Icon = "arrow_right",
				OnClick = function()
					apply_material(get_selected_entity(), entry)
				end,
			} or
			nil,
			entry.category == "prefabs" and
			MenuItem{
				Text = "Place in front of camera",
				Icon = "place",
				OnClick = function()
					place_prefab(entry)
				end,
			} or
			nil,
			entry.category == "prefabs" and
			get_selected_instance() and
			MenuItem{
				Text = "Use as prefab of selected instance",
				Icon = "arrow_right",
				OnClick = function()
					editor_history.SetProperty(get_selected_instance().prefab, "Path", entry.name)
				end,
			} or
			nil,
			entry.preview and
			entry.preview.status == "failed" and
			MenuItem{
				Text = "Retry preview",
				Icon = "refresh",
				OnClick = function()
					previews.Release(entry)
				end,
			} or
			nil,
			MenuSpacer{},
			MenuItem{
				Text = "Debug info",
				Icon = "info",
				Items = function()
					local debug_items = {}

					for _, section in ipairs(asset_info.Get(entry, get_detail_material(api.view, entry))) do
						debug_items[#debug_items + 1] = MenuItem{Text = "-- " .. section.title .. " --", Disabled = true}

						for _, row in ipairs(section.rows) do
							local label, value = row[1], row[2]
							debug_items[#debug_items + 1] = MenuItem{
								Text = (label ~= "" and (label .. ": ") or "") .. value,
								OnClick = function()
									clipboard.Set(value)
								end,
							}
						end
					end

					return debug_items
				end,
			},
		}
	)
end

local function draw_item(item, index, x, y, w, h, selected, hovered)
	refresh_colors()
	render2d.DrawBox(
		x,
		y,
		w,
		h,
		6,
		hovered and colors.tile_fill_hover or colors.tile_fill,
		selected and colors.primary or colors.border,
		selected and -2 or -1
	)
	local inset = 4
	local px, py, pw = x + inset, y + inset, w - inset * 2
	local label_y = y + h - LABEL_HEIGHT + 2
	local width = w - 8

	if item.label_width ~= width then
		item.label = colors.font:ElideText(item.name, width)
		item.label_width = width
		item.sub_label = item.is_folder and
			(
				"%d assets"
			):format(item.folder.count) or
			item.extension:sub(2)
	end

	if item.is_folder then
		local icon_size = pw * 0.62
		folder_icon_box.x = icon_size
		folder_icon_box.y = icon_size
		render2d.PushMatrix()
		render2d.Translatef(px + (pw - icon_size) / 2, py + (pw - icon_size) / 2)
		theme.active:DrawIcon("folder", folder_icon_box, {color = colors.folder, inset = 0})
		render2d.PopMatrix()
	elseif item.category == "components" then
		local icon_size = pw * 0.5
		folder_icon_box.x = icon_size
		folder_icon_box.y = icon_size
		render2d.DrawBox(px, py, pw, pw, 4, colors.preview_background)
		render2d.PushMatrix()
		render2d.Translatef(px + (pw - icon_size) / 2, py + (pw - icon_size) / 2)
		theme.active:DrawIcon("component", folder_icon_box, {color = colors.icon, inset = 0})
		render2d.PopMatrix()
	else
		local preview = previews.Request(item)
		render2d.DrawBox(px, py, pw, pw, 4, colors.preview_background)

		if preview.status == "ready" then
			previews.Draw(preview, px, py, pw, pw)

			if preview.width and item.category == "textures" then
				local badge = preview.badge

				if not badge then
					badge = preview.width .. "x" .. preview.height
					preview.badge = badge
				end

				local bw, bh = colors.font_small:GetTextSize(badge)
				render2d.DrawBox(px + pw - bw - 8, py + pw - bh - 6, bw + 6, bh + 2, 3, colors.badge_fill)
				draw_text(colors.font_small, badge, px + pw - bw - 5, py + pw - bh - 5, colors.white)
			end
		elseif preview.status == "failed" then
			draw_centered_text(colors.font_strong, "!", px, py, pw, pw - 12, colors.negative)
			draw_centered_text(colors.font_small, "failed", px, py + 14, pw, pw, colors.preview_text)
		elseif preview.status == "none" then
			draw_centered_text(colors.font_strong, item.sub_label:upper(), px, py, pw, pw, colors.preview_text)
		else
			colors.pulse.a = 0.12 + 0.08 * math.sin(system.GetElapsedTime() * 5 + index)
			render2d.DrawBox(px + pw * 0.3, py + pw * 0.45, pw * 0.4, pw * 0.1, 3, colors.pulse)
		end
	end

	local tw = colors.font:GetTextSize(item.label)
	draw_text(colors.font, item.label, x + (w - tw) / 2, label_y, colors.text)
	local sw = colors.font_small:GetTextSize(item.sub_label)
	draw_text(colors.font_small, item.sub_label, x + (w - sw) / 2, label_y + 16, colors.text_disabled)
end

-- the folders and assets the grid shows, a search narrows the previous result while the query only gets longer
local function list_items(category, index, folder, query, recursive, cache)
	query = query:match("^%s*(.-)%s*$")
	local items

	if query ~= "" then
		local scope = folder.path ~= "" and folder.path or nil
		local source

		if
			cache.results and
			cache.folder == folder and
			cache.version == index.version and
			query:starts_with(cache.query)
		then
			source = cache.results
		end

		items = assets.Search(category, query, {prefix = scope, entries = source})
		cache.query = query
		cache.results = items
		cache.folder = folder
		cache.version = index.version
	else
		cache.results = nil
		items = {}
		local prefix = folder.path:lower()

		if recursive then
			for _, entry in ipairs(index.entries) do
				if prefix == "" or entry.lower_path:starts_with(prefix) then
					items[#items + 1] = entry
				end
			end
		else
			for _, child in ipairs(folder.folders) do
				items[#items + 1] = {is_folder = true, folder = child, name = child.name}
			end

			for _, entry in ipairs(folder.entries) do
				items[#items + 1] = entry
			end
		end
	end

	return items
end

local function make_folder_node(folder)
	local chain, text = get_folder_node_chain(folder)
	local tail = chain[#chain]
	local lookup = {}

	for _, chain_folder in ipairs(chain) do
		lookup[chain_folder] = true
	end

	local node = {
		Key = tail.path,
		Text = ("%s  (%d)"):format(text, tail.count),
		Icon = get_folder_icon,
		Folder = tail,
		Chain = lookup,
		Children = {__lazy = true},
		ChildrenLoaded = false,
	}

	if #tail.folders == 0 then
		node.Children = {}
		node.ChildrenLoaded = true
	end

	return node
end

local function ensure_children(node)
	if node.ChildrenLoaded then return false end

	node.ChildrenLoaded = true
	node.Children = {}

	for _, child in ipairs(node.Folder.folders) do
		node.Children[#node.Children + 1] = make_folder_node(child)
	end

	return true
end

local function make_root_node(category, root)
	local node = {
		Key = category,
		Text = ("%s  (%d)"):format(category, root.count),
		Icon = CATEGORY_ICONS[category] or "folder",
		Folder = root,
		Chain = {[root] = true},
		Children = {__lazy = true},
		ChildrenLoaded = false,
	}
	ensure_children(node)
	return node
end

-- opens the branches down to folder and selects it, a folder the tree already shows is left alone
local function reveal_in_tree(tree, items, expanded, root, folder)
	local ancestors = {}
	local current = folder

	while current do
		table.insert(ancestors, 1, current)

		if current == root then break end

		current = current.parent
	end

	local node = items[1]
	local changed = false

	for i = 2, #ancestors do
		if ensure_children(node) then changed = true end

		if not expanded[node.Key] then
			expanded[node.Key] = true
			changed = true
		end

		local found

		for _, child in ipairs(node.Children) do
			if child.Chain[ancestors[i]] then
				found = child

				break
			end
		end

		if not found then break end

		node = found
	end

	if not changed and tree:GetSelectedKey() == node.Key then return end

	tree:Rebuild(true)
	tree:SetSelectedKey(node.Key)
	tree:EnsureVisible(node.Key)
end

-- the folders of a category, branches are built when they open
local FolderTree = react.Component(|props| -> do
	local tree = react.UseRef()
	local expanded = react.UseRef({})
	local items = react.UseMemo(|| -> do
		local root_node = make_root_node(props.Category, props.Root)
		expanded.current[root_node.Key] = true
		return {root_node}
	end, {props.Index, props.Root})

	react.UseEffect(
		|| -> reveal_in_tree(tree.current, items, expanded.current, props.Root, props.Folder),
		{props.Folder, items}
	)

	return Tree{
		Ref = tree,
		Items = items,
		LabelGrow = true,
		layout = {GrowWidth = 1, FitHeight = true},
		OnIsExpanded = |node, path, key| -> expanded.current[key] == true,
		OnSelect = |node| -> do
			if node then props.OnNavigate(node.Folder) end
		end,
		OnToggle = |node, is_expanded, key| -> do
			expanded.current[key] = is_expanded == true

			if is_expanded and ensure_children(node) then tree.current:RefreshBranchForKey(key) end
		end,
	}
end)
local Breadcrumb = react.Component(|props| -> do
	local root = props.Root
	local chain = react.UseMemo(|| -> do
		local result = {}
		local folder = props.Folder

		while folder do
			table.insert(result, 1, folder)

			if folder == root then break end

			folder = folder.parent
		end

		return result
	end, {root, props.Folder})
	local crumbs = {}

	for i, crumb in ipairs(chain) do
		if i > 1 then
			crumbs[#crumbs + 1] = Icon{Key = "separator/" .. i, Icon = "chevron_right", Size = "S", IconColor = "text_disabled"}
		end

		crumbs[#crumbs + 1] = Clickable{
			Key = "crumb/" .. i,
			Mode = "text",
			Padding = Rect(4, 2, 4, 2),
			OnClick = || -> props.OnNavigate(crumb),
			layout = {FitWidth = true, FitHeight = true},
		}{
			Text{
				Text = crumb == root and props.Category or crumb.name,
				Font = i == #chain and "body_strong S" or "body S",
				IgnoreMouseInput = true,
			},
		}
	end

	return Row{layout = {GrowWidth = 1, ChildGap = 2, AlignmentY = "center"}}{crumbs}
end)
-- hovering changes on every mouse move, so the status bar keeps it and nothing above it renders
local StatusBar = react.Component(|props| -> do
	local hovered, set_hovered = react.UseState()
	props.HoverRef.current = set_hovered
	local entry = hovered ?? props.Selected
	local text

	if not entry then
		text = props.Folder.path ~= "" and props.Folder.path or props.Category
	elseif entry.is_folder then
		text = entry.folder.path
	else
		text = entry.path
	end

	return Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"}}{
		Text{Text = text, Color = "text_disabled", Elide = true, layout = {GrowWidth = 1, FitWidth = false}},
		props.Picking && Button{
			Key = "select",
			Text = "Select",
			Icon = "check",
			OnClick = || -> do
				if props.Selected then props.OnPick(props.Selected) end
			end,
		},
		props.Picking && Button{
			Key = "cancel",
			Text = "Cancel",
			Icon = "close",
			Mode = "outline",
			OnClick = props.OnCancel,
		},
	}
end)

local function start_detail_preview(entry)
	local detail = {entry = entry, ready = false}

	if entry.category == "models" and entry.extension ~= ".bsp" then
		detail.entity = previews.CreateModelEntity(entry.path)
		detail.owns_entity = detail.entity ~= nil
		detail.preview = ModelPreview.New{
			Width = DETAIL_PREVIEW_SIZE,
			Height = DETAIL_PREVIEW_SIZE,
			Padding = 1.1,
		}
	elseif entry.category == "prefabs" and RENDER_3D then
		detail.entity, detail.visuals = previews.CreatePrefabEntity(entry.name)
		detail.owns_entity = true
		detail.preview = ModelPreview.New{
			Width = DETAIL_PREVIEW_SIZE,
			Height = DETAIL_PREVIEW_SIZE,
			Padding = 1.1,
		}
	elseif entry.category == "materials" then
		detail.material = entry.material or previews.LoadMaterial(entry)

		if detail.material then
			detail.entity = previews.GetMaterialSphere()
			detail.preview = ModelPreview.New{
				Width = DETAIL_PREVIEW_SIZE,
				Height = DETAIL_PREVIEW_SIZE,
				Padding = 1.1,
			}
		end
	end

	return detail
end

local function stop_detail_preview(detail)
	if detail.owns_entity and detail.entity:IsValid() then detail.entity:Remove() end

	if detail.preview and detail.preview:IsValid() then detail.preview:Remove() end

	if detail.material and not detail.entry.material then
		previews.ReleaseMaterial(detail.material)
	end
end

local function update_detail_preview(detail, view, dt)
	local entity = detail.entity

	if not (entity and entity:IsValid() and detail.preview) then return end

	local visual = entity.visual

	if not detail.ready then
		if detail.material then
			detail.ready = previews.IsMaterialReady(detail.material)
		elseif detail.visuals then
			local ready, drawable = previews.ArePrefabVisualsReady(detail.visuals)
			detail.ready = ready and drawable
		else
			local entries = visual:GetRenderEntries()
			detail.ready = not visual.Loading and
				entries[1] ~= nil and
				previews.AreModelMaterialsReady(visual)
		end

		if not detail.ready then return end
	end

	if view.auto_rotate then view.orbit:Rotate(-dt * 60, 0) end

	detail.preview:SetViewOffset(view.orbit:GetViewOffset())

	if detail.visuals then
		detail.preview:SetTargets(detail.visuals)
		detail.preview:Refresh()
		detail.preview:SetTarget(nil)
		return
	end

	if detail.material then visual:SetMaterialOverride(detail.material) end

	detail.preview:SetTarget(visual)
	detail.preview:Refresh()
	detail.preview:SetTarget(nil)

	if detail.material then visual:SetMaterialOverride(nil) end
end

local function draw_checker(x, y, w, h)
	theme.active:DrawBoxShape(x, y, w, h, {fill = "actual_black", fill_alpha = 0.18})
	local step = 12

	for cy = 0, math.ceil(h / step) - 1 do
		for cx = 0, math.ceil(w / step) - 1 do
			if (cx + cy) % 2 == 0 then
				render2d.SetTexture(nil)
				render2d.SetColor(1, 1, 1, 0.10)
				render2d.DrawRect(
					x + cx * step,
					y + cy * step,
					math.min(step, w - cx * step),
					math.min(step, h - cy * step)
				)
			end
		end
	end
end

local function draw_detail_preview(self, entry, detail, view)
	refresh_colors()
	local size = self.Owner.transform:GetSize()
	theme.active:DrawBoxShape(0, 0, size.x, size.y, {fill = colors.preview_background, radius = 6})
	local pad = 8

	if entry.category == "components" then
		local icon_size = math.min(size.x, size.y) * 0.5
		folder_icon_box.x = icon_size
		folder_icon_box.y = icon_size
		render2d.PushMatrix()
		render2d.Translatef((size.x - icon_size) / 2, (size.y - icon_size) / 2)
		theme.active:DrawIcon("component", folder_icon_box, {color = colors.icon, inset = 0})
		render2d.PopMatrix()
		draw_centered_text(colors.font_strong, entry.name, 0, size.y - 30, size.x, 24, colors.preview_text)
		return
	end

	local preview = entry.material and WORLD_PREVIEW or previews.Request(entry)

	if entry.category == "textures" then
		if preview.status == "ready" then
			local scale = math.min((size.x - pad * 2) / preview.width, (size.y - pad * 2) / preview.height)
			local dw, dh = preview.width * scale, preview.height * scale
			local dx, dy = (size.x - dw) / 2, (size.y - dh) / 2
			draw_checker(dx, dy, dw, dh)
			previews.Draw(preview, dx, dy, dw, dh)
			draw_text(
				colors.font_small,
				preview.width .. " x " .. preview.height .. "  " .. tostring(preview.format),
				pad + 2,
				size.y - 18,
				colors.preview_text
			)
		else
			draw_centered_text(
				colors.font,
				preview.status == "failed" and (preview.error or "failed") or "loading...",
				0,
				0,
				size.x,
				size.y,
				colors.preview_text
			)
		end

		return
	end

	if detail.ready and detail.preview:IsValid() then
		detail.preview:Draw(pad, pad, size.x - pad * 2, size.y - pad * 2)
		draw_text(
			colors.font_small,
			view.auto_rotate and "drag to rotate" or "drag to rotate, click to spin",
			pad + 2,
			size.y - 18,
			colors.preview_text
		)
	elseif preview.status == "ready" then
		previews.Draw(preview, pad, pad, size.x - pad * 2, size.y - pad * 2)
	elseif preview.status == "failed" then
		draw_centered_text(colors.font, preview.error or "failed", 0, 0, size.x, size.y, colors.preview_text)
	elseif preview.status == "none" then
		draw_centered_text(
			colors.font_strong,
			entry.extension:sub(2):upper(),
			0,
			0,
			size.x,
			size.y,
			colors.preview_text
		)
	else
		draw_centered_text(colors.font, "loading...", 0, 0, size.x, size.y, colors.preview_text)
	end
end

local function draw_no_selection(self)
	refresh_colors()
	local size = self.Owner.transform:GetSize()
	theme.active:DrawBoxShape(0, 0, size.x, size.y, {fill = colors.preview_background, radius = 6})
	draw_centered_text(colors.font, "no selection", 0, 0, size.x, size.y, colors.preview_text)
end

local function detail_error(message)
	return Text{Text = "preview failed: " .. tostring(message), Wrap = true, Color = "negative", layout = {GrowWidth = 1}}
end

-- one of the textures a material uses
local ChannelTile = react.Component(|props| -> do
	local texture = props.Texture
	local draw = react.UseCallback(|self| -> do
		refresh_colors()
		local size = self.Owner.transform:GetSize()
		render2d.DrawBox(0, 0, size.x, size.y, 4, colors.preview_background)

		if texture:IsReady() then
			render2d.SetTexture(texture)
			render2d.SetColor(1, 1, 1, 1)
			render2d.DrawRect(2, 2, size.x - 4, size.y - 4)
		end
	end, {texture})
	local on_mouse_input = react.UseCallback(|self, button, press| -> do
		if button ~= "button_1" or not press then return end

		TextureViewer(texture, props.Title)

		return true
	end, {texture, props.Title})

	return Column{layout = {FitWidth = true, FitHeight = true, ChildGap = 2, AlignmentX = "start"}}{
		Canvas{
			Name = "AssetDetailChannel",
			Cursor = "hand",
			OnDraw = draw,
			OnMouseInput = on_mouse_input,
			layout = {
				MinSize = Vec2(CHANNEL_SIZE, CHANNEL_SIZE),
				MaxSize = Vec2(CHANNEL_SIZE, CHANNEL_SIZE),
				FitWidth = false,
				FitHeight = false,
			},
		},
		Text{Text = props.Label, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true, layout = {FitWidth = true}},
	}
end)
-- everything about the selected asset: the preview, the textures of a material, the actions and the facts of asset_info
local AssetDetails = react.Component(|props| -> do
	local entry = props.Entry
	local view = props.View
	local _, update = react.UseState(0)
	local detail = react.UseResource(|| -> do
		local started = start_detail_preview(entry)
		view.detail = started
		return started
	end, |started| -> do
		stop_detail_preview(started)

		if view.detail == started then view.detail = nil end
	end, {})

	react.UseEvent("Update", |dt| -> do
		if view.dragging then
			local x, y = system.GetWindow():GetMousePosition():Unpack()
			view.orbit:Rotate(x - view.drag_x, y - view.drag_y)
			view.drag_x, view.drag_y = x, y

			if math.abs(x - view.press_x) + math.abs(y - view.press_y) >= 3 then
				view.auto_rotate = false
			end
		end

		update_detail_preview(detail, view, dt)
	end)

	-- the preview loads and the model readies on their own, what the facts show depends on both
	local state = react.UsePoll(|| -> (entry.preview and entry.preview.status or "none") .. (detail.ready and "+" or "-"), 0.1)
	local sections = react.UseMemo(|| -> asset_info.Get(entry, detail.material), {entry, state})
	local channels = react.UseMemo(|| -> do
		local list = {}

		if detail.material and detail.ready then
			for _, info in ipairs(detail.material:GetTextures()) do
				list[#list + 1] = {texture = info.texture, label = info.name:lower()}
			end
		end

		return list
	end, {detail, state})
	local draw = react.UseCallback(|self| -> draw_detail_preview(self, entry, detail, view), {})
	local on_mouse_input = react.UseCallback(|self, button, press| -> do
		if button ~= "button_1" then return end

		if press then
			view.drag_x, view.drag_y = system.GetWindow():GetMousePosition():Unpack()
			view.press_x, view.press_y = view.drag_x, view.drag_y
			view.dragging = true
		else
			view.dragging = false
			local x, y = system.GetWindow():GetMousePosition():Unpack()

			if math.abs(x - view.press_x) + math.abs(y - view.press_y) < 3 then
				view.auto_rotate = not view.auto_rotate
			end
		end

		return true
	end, {})
	local actions = {}

	if props.Picking then
		actions[#actions + 1] = Button{
			Key = "select",
			Text = "Select",
			Icon = "check",
			OnClick = || -> props.OnPick(entry),
		}
	end

	actions[#actions + 1] = Button{
		Key = "copy",
		Text = "Copy path",
		Icon = "copy",
		Mode = "outline",
		OnClick = || -> clipboard.Set(entry.path),
	}

	if entry.category == "materials" then
		actions[#actions + 1] = Button{
			Key = "view",
			Text = "View",
			Icon = "cube",
			Mode = "outline",
			OnClick = || -> open_material_viewer(entry, view),
		}
	end

	if entry.category == "textures" then
		actions[#actions + 1] = Button{
			Key = "open",
			Text = "Open",
			Icon = "image",
			Mode = "outline",
			OnClick = || -> open_texture_viewer(entry),
		}
	end

	local target = entry.category == "components" and get_selected_object() or get_selected_entity()

	if is_viewable_model(entry) then
		actions[#actions + 1] = Button{
			Key = "view",
			Text = "View",
			Icon = "cube",
			Mode = "outline",
			OnClick = || -> open_model_viewer(entry),
		}
		actions[#actions + 1] = Button{
			Key = "spawn",
			Text = "Spawn",
			Icon = "place",
			Mode = "outline",
			OnClick = || -> spawn_model(entry),
		}

		if target then
			actions[#actions + 1] = Button{
				Key = "use",
				Text = "Use on selected",
				Icon = "arrow_right",
				Mode = "outline",
				OnClick = || -> apply_model(target, entry),
			}
		end
	elseif entry.category == "materials" and target and not entry.material then
		actions[#actions + 1] = Button{
			Key = "use",
			Text = "Apply to selected",
			Icon = "arrow_right",
			Mode = "outline",
			OnClick = || -> apply_material(target, entry),
		}
	elseif entry.category == "components" and not props.Picking and target and not target:HasComponent(entry.name) then
		actions[#actions + 1] = Button{
			Key = "use",
			Text = "Add to selected",
			Icon = "plus",
			Mode = "outline",
			OnClick = || -> do
				editor_history.AddComponent(target, entry.name)
				update(|n| -> n + 1)
			end,
		}
	elseif entry.category == "prefabs" then
		actions[#actions + 1] = Button{
			Key = "place",
			Text = "Place",
			Icon = "place",
			Mode = "outline",
			OnClick = || -> place_prefab(entry),
		}

		if get_selected_instance() then
			actions[#actions + 1] = Button{
				Key = "use",
				Text = "Use on selected",
				Icon = "arrow_right",
				Mode = "outline",
				OnClick = || -> editor_history.SetProperty(get_selected_instance().prefab, "Path", entry.name),
			}
		end
	end

	local tiles = {}

	for i, channel in ipairs(channels) do
		tiles[i] = ChannelTile{
			Key = channel.label,
			Texture = channel.texture,
			Label = channel.label,
			Title = entry.name .. " " .. channel.label,
		}
	end

	local facts = {}

	for _, section in ipairs(sections) do
		facts[#facts + 1] = Text{
			Key = "section/" .. section.title,
			Text = section.title:upper(),
			Font = "body_strong S",
			Color = "text_disabled",
			layout = {FitWidth = true, Margin = Rect(0, 8, 0, 2)},
		}

		for i, row in ipairs(section.rows) do
			facts[#facts + 1] = Row{Key = section.title .. "/" .. i, layout = {GrowWidth = 1, AlignmentY = "start", ChildGap = 8}}{
				Text{
					Text = row[1],
					Font = "body S",
					Color = "text_disabled",
					layout = {MinSize = Vec2(92, 0), MaxSize = Vec2(92, 0), FitWidth = false},
				},
				Text{Text = row[2], Font = "body S", Wrap = true, layout = {GrowWidth = 1}},
			}
		end
	end

	return Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = 6, AlignmentX = "stretch"}}{
		Canvas{
			Name = "AssetDetailPreview",
			Cursor = "sizeall",
			OnDraw = draw,
			OnMouseInput = on_mouse_input,
			layout = {GrowWidth = 1, MinSize = Vec2(0, 320), MaxSize = Vec2(0, 320)},
		},
		#tiles > 0 && Row{layout = {GrowWidth = 1, ChildGap = 8, WrapChildren = true, Margin = Rect(0, 0, 0, 12)}}{tiles},
		Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = 4, AlignmentX = "stretch"}}{
			Text{Text = entry.name .. entry.extension, Font = "body_strong M", Wrap = true, layout = {GrowWidth = 1}},
			Text{Text = entry.path, Font = "body S", Color = "text_disabled", Wrap = true, layout = {GrowWidth = 1}},
			Row{layout = {GrowWidth = 1, ChildGap = 6, WrapChildren = true}}{actions},
			facts,
		},
	}
end)
-- what picker.Start hands over for the current tab: a model path, a prefab name, a material and its hit or a texture and its name
local function select_picked(api, value, extra)
	local category = api.category

	local function select_asset(name, matches)
		if category ~= name then api.change_category(name) end

		for _, entry in pairs(assets.GetIndex(name).by_path) do
			if matches(entry) then
				api.select(entry)

				return true
			end
		end

		return false
	end

	if category == "models" then
		return select_asset("models", function(entry)
			return entry.path:lower() == extra:lower()
		end)
	end

	if category == "prefabs" then
		return select_asset("prefabs", function(entry)
			return entry.name == extra
		end)
	end

	if category == "textures" then
		-- a texture path is the mounted file, an absolute path into a vpk for source textures, the index has the part below the mount
		local lower = value.config.path and value.config.path:lower()
		local start = 1
		local entry

		while lower and start and not entry do
			entry = assets.GetIndex("textures").by_path[lower:sub(start)]
			start = lower:find("/", start, true)
			start = start and start + 1
		end

		if entry then
			api.select(entry)
		else
			print("the " .. extra .. " texture is not an asset in the browser")
		end

		return
	end

	local paths = {}

	for _, path in ipairs(previews.GetMaterialPaths(value)) do
		paths[path:lower()] = true
	end

	if
		select_asset("materials", function(entry)
			return paths[entry.path:lower()]
		end)
	then
		return
	end

	local name = value.Name ~= "" and value.Name or "picked material"
	api.select_transient{
		category = "materials",
		name = name,
		extension = "",
		path = name,
		kind = "material",
		source = "world",
		root = "world",
		material = value,
		hit = extra,
	}
end

local AssetBrowser = react.Component(|props| -> do
	local categories = react.UseMemo(|| -> props.PickerCategory ? {props.PickerCategory} : DEFAULT_CATEGORIES, {})
	local picking = props.OnPick ~= nil
	local api = react.UseRef({}).current
	local window = react.UseRef()
	local filter = react.UseRef()
	local hover = react.UseRef()
	local world_pick = react.UseRef({})
	-- the asset the browser opens on
	local start = react.UseMemo(|| -> do
		prepare_category(categories[1], props)
		local path = props.SelectedPath

		if path and path ~= "" then
			return assets.GetIndex(categories[1]).by_path[path:lower()]
		end
	end, {})
	local category, set_category = react.UseState(categories[1])
	local folder_state, set_folder = react.UseState(start && start.folder)
	local selected_item, set_selected_item = react.UseState(start)
	local query, set_query = react.UseState("")
	local recursive, set_recursive = react.UseState(false)
	local zoom, set_zoom = react.UseState(128)
	local refresh, set_refresh = react.UseState(0)
	local world_picking, set_world_picking = react.UseState(false)
	local applied_query = react.UseDebounce(query, 0.12)
	local search = react.UseRef({})
	-- the orbit camera of the detail preview stays when another asset is selected
	local view = react.UseMemo(|| -> do
		local orbit = OrbitCamera.New()
		orbit:SetYaw(math.pi / 4)
		orbit:SetPitch(-math.asin(1 / math.sqrt(3)))
		return {orbit = orbit, auto_rotate = true}
	end, {})
	local index = react.UseMemo(|| -> assets.GetIndex(category), {category, refresh})
	local root = react.UseMemo(|| -> do
		local top = index.root

		while #top.entries == 0 and #top.folders == 1 do
			top = top.folders[1]
		end

		return top
	end, {index})
	local folder = folder_state ?? root
	local items = react.UseMemo(
		|| -> list_items(category, index, folder, applied_query, recursive, search.current),
		{category, index, index.version, folder, applied_query, recursive}
	)
	local count_text = react.UseMemo(|| -> do
		local asset_count = 0
		local folder_count = 0

		for _, item in ipairs(items) do
			if item.is_folder then
				folder_count += 1
			else
				asset_count += 1
			end
		end

		if folder_count > 0 then
			return ("%d folders, %d assets"):format(folder_count, asset_count)
		end

		return ("%d assets"):format(asset_count)
	end, {items})
	local selected

	if selected_item and not selected_item.is_folder then selected = selected_item end

	local close = props.Close
	local navigate = |target| -> do
		if target.path:lower():starts_with("textures/internals/") then
			assets.RefreshInternalTextures()
		end

		set_folder(target)
		set_selected_item(nil)
	end
	local change_category = |name| -> do
		prepare_category(name, props)

		if world_pick.current.owns then picker.Stop() end

		set_category(name)
		set_folder(nil)
		set_selected_item(nil)
	end
	local pick = |entry| -> do
		if props.OnPick(entry) ~= false then close() end
	end
	api.picking = picking
	api.pick = pick
	api.navigate = navigate
	api.change_category = change_category
	api.category = category
	api.view = view
	api.select = |entry| -> do
		set_folder(entry.folder)
		set_selected_item(entry)
	end
	api.select_transient = set_selected_item

	local start_pick = || -> do
		if world_pick.current.owns then return picker.Stop() end

		world_pick.current.owns = true
		set_world_picking(true)
		window.current.visual:SetVisible(false)
		picker.Start{
			mode = PICK_MODES[category],
			hide_desktop = true,
			entity_blacklist = (category == "models" or category == "prefabs") and {_G.PLAYER_RIG} or nil,
			on_pick = |value, extra| -> select_picked(api, value, extra),
			on_stop = || -> do
				world_pick.current.owns = false
			end,
			on_done = || -> do
				if not window.current:IsValid() then return end

				set_world_picking(false)
				window.current.visual:SetVisible(true)
				window.current:BringToFront()
			end,
		}
	end

	react.UseEffect(|| -> do
		open_windows += 1
		filter.current:GetTextPanel():RequestFocus()

		return || -> do
			if world_pick.current.owns then picker.Stop() end

			open_windows -= 1

			if open_windows == 0 then previews.Clear() end
		end
	end, {})

	local input_height = theme.active:GetInputHeight("M")
	local details

	if selected then
		details = ErrorBoundary{Key = selected.path, Fallback = detail_error}{
			AssetDetails{Entry = selected, View = view, Picking = picking, OnPick = pick},
		}
	else
		details = Column{layout = {GrowWidth = 1, FitHeight = true, ChildGap = 6, AlignmentX = "stretch"}}{
			Canvas{
				Name = "AssetDetailPreview",
				OnDraw = draw_no_selection,
				layout = {GrowWidth = 1, MinSize = Vec2(0, 320), MaxSize = Vec2(0, 320)},
			},
			Text{
				Text = picking and "Select an asset, then press Select." or "Select an asset to see details.",
				Wrap = true,
				Color = "text_disabled",
				layout = {GrowWidth = 1},
			},
		}
	end

	return ViewerWindow{
		Ref = window,
		Title = picking and ("PICK " .. categories[1]:upper()) or "ASSET BROWSER",
		Size = WINDOW_SIZE,
		layout = {FitHeight = false, FitWidth = false},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
				FitHeight = false,
				AlignmentX = "stretch",
				ChildGap = 6,
				Padding = Rect() + 8,
			},
		}{
			#categories > 1 && TabBar{
				Tabs = categories,
				Icons = CATEGORY_ICONS,
				Value = category,
				OnChange = change_category,
			},
			Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center"}}{
				TextEdit{
					Ref = filter,
					Hint = "search names and paths in the selected folder",
					Size = Vec2(0, input_height),
					MinSize = Vec2(160, input_height),
					MaxSize = Vec2(0, input_height),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnTextChanged = |_, text| -> set_query(text),
					layout = {GrowWidth = 1},
				},
				Text{Text = count_text, Color = "text_disabled", layout = {FitWidth = true, MinSize = Vec2(80, 0)}},
				Slider{
					Mode = "horizontal",
					Min = 72,
					Max = 240,
					Value = zoom,
					OnChange = |value| -> set_zoom(math.floor(value)),
					Tooltip = "tile size",
					layout = {MinSize = Vec2(110, 16), MaxSize = Vec2(110, 16), FitWidth = false},
				},
				Button{
					Text = "Subfolders",
					Icon = "tree",
					Mode = "outline",
					Active = recursive,
					Tooltip = "list every asset below the selected folder",
					OnClick = || -> set_recursive(!recursive),
				},
				RENDER_3D && category ~= "components" && table.has_value(categories, "materials") && Button{
					Key = "pick",
					Text = "Pick",
					Icon = "target",
					Mode = "outline",
					Active = world_picking,
					Tooltip = "pick from the world: the material of a surface, the model or the prefab of an entity depending on the tab. escape cancels",
					OnClick = start_pick,
				},
				Button{
					Text = "Refresh",
					Icon = "refresh",
					Mode = "outline",
					OnClick = || -> do
						assets.InvalidateIndex(category)
						prepare_category(category, props)
						set_folder(nil)
						set_selected_item(nil)
						set_refresh(|n| -> n + 1)
					end,
				},
			},
			Splitter{InitialSize = 260, layout = {GrowWidth = 1, GrowHeight = 1}}{
				ScrollablePanel{
					Padding = Rect(),
					ScrollX = false,
					ScrollY = true,
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					FolderTree{Index = index, Category = category, Root = root, Folder = folder, OnNavigate = navigate},
				},
				Column{
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						FitHeight = false,
						AlignmentX = "stretch",
						ChildGap = 4,
					},
				}{
					Breadcrumb{Category = category, Root = root, Folder = folder, OnNavigate = navigate},
					Row{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							ChildGap = 6,
							FitHeight = false,
							AlignmentY = "stretch",
						},
					}{
						VirtualGrid{
							Items = items,
							SelectedItem = selected_item,
							CellWidth = zoom,
							ExtraHeight = LABEL_HEIGHT,
							Gap = 8,
							ContentPadding = 6,
							OnDrawItem = draw_item,
							OnSelect = set_selected_item,
							OnActivate = |item| -> activate_item(item, api),
							OnContextMenu = |item| -> open_context_menu(item, api),
							OnHoverItem = |item| -> hover.current(item),
							layout = {GrowWidth = 1, GrowHeight = 1},
						},
						Frame{
							Padding = Rect() + 6,
							layout = {
								MinSize = Vec2(344, 0),
								MaxSize = Vec2(344, 0),
								FitWidth = false,
								GrowHeight = 1,
								FitHeight = false,
								Direction = "y",
								ChildGap = 6,
								AlignmentX = "stretch",
							},
						}{
							ScrollablePanel{
								Padding = Rect(),
								ScrollX = false,
								ScrollY = true,
								layout = {GrowWidth = 1, GrowHeight = 1},
							}{details},
						},
					},
				},
			},
			StatusBar{
				HoverRef = hover,
				Folder = folder,
				Category = category,
				Selected = selected,
				Picking = picking,
				OnPick = pick,
				OnCancel = close,
			},
		},
	}
end)

return function(props)
	props = props or {}

	return kit.OpenOnce(props.Key, || -> do
		local root

		root = react.Mount(
			AssetBrowser{
				PickerCategory = props.PickerCategory,
				SelectedPath = props.SelectedPath,
				ComponentTarget = props.ComponentTarget,
				OnPick = props.OnPick,
				Close = || -> root:Unmount(),
			},
			Panel.World
		)

		return root:GetEntity()
	end)
end
