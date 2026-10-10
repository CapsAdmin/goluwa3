local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local clipboard = import("goluwa/bindings/clipboard.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local utf8 = import("goluwa/string/utf8.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local Tree = import("goluwa/render2d/ui/widgets/tree.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local VirtualGrid = import("goluwa/render2d/ui/elements/virtual_grid.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local Clickable = import("goluwa/render2d/ui/elements/clickable.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local TextureViewer = import("lua/texture_viewer.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local OrbitCamera = import("goluwa/render3d/orbit_camera.lua")
local previews = import("lua/asset_preview.lua")
local asset_info = import("lua/asset_info.lua")
local prefab_tools = import("lua/prefab_tools.lua")
local DEFAULT_CATEGORIES = {"models", "textures", "materials", "prefabs"}
local LABEL_HEIGHT = 36
local DETAIL_PREVIEW_SIZE = 320
local CHANNEL_SIZE = 64
local CHANNEL_GAP = 8
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

local function elide(font, text, max_width)
	if font:GetTextSize(text) <= max_width then return text end

	local length = utf8.length(text)
	local low, high = 1, length - 1
	local best = "..."

	while low <= high do
		local keep = math.floor((low + high) / 2)
		local head = math.ceil(keep * 0.6)
		local candidate = utf8.sub(text, 1, head) .. "..." .. utf8.sub(text, length - (keep - head) + 1, length)

		if font:GetTextSize(candidate) <= max_width then
			best = candidate
			low = keep + 1
		else
			high = keep - 1
		end
	end

	return best
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

local function draw_folder_icon(x, y, w, h, color)
	local iw = w * 0.62
	local ih = iw * 0.76
	local ix = x + (w - iw) / 2
	local iy = y + (h - ih) / 2
	render2d.DrawBox(ix, iy - ih * 0.12, iw * 0.42, ih * 0.3, 3, color)
	render2d.DrawBox(ix, iy, iw, ih, 4, color)
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

local function spawn_model(entry)
	local camera = render3d.GetCamera()
	local entity = Entity.New{Name = entry.name}
	entity:AddComponent("transform"):SetPosition(camera:GetPosition() + camera:GetRotation():GetForward() * 3)
	entity:AddComponent("model", {ModelPath = entry.path})
	event.Call("EditorSelect", entity)
	return entity
end

local function apply_model(target, entry)
	if target:HasComponent("model") then
		target.model:SetModelPath(entry.path)
	else
		target:EnsureComponent("visual"):SetModelPath(entry.path)
	end
end

local function apply_material(target, entry)
	target:EnsureComponent("visual"):SetMaterialOverridePath(entry.path)
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

return function(props)
	props = props or {}
	local categories = props.Categories or
		(
			props.PickerCategory and
			{props.PickerCategory} or
			DEFAULT_CATEGORIES
		)
	local picking = props.OnPick ~= nil
	local state = {
		category = categories[1],
		root = nil,
		folder = nil,
		query = props.Filter or "",
		recursive = false,
		selected = nil,
		hovered = nil,
		zoom = props.Zoom or 128,
		search_deadline = nil,
		items = {},
	}
	local expanded = {}
	local window
	local window_navigate
	local grid
	local tree_view
	local filter_edit
	local count_text
	local status_text
	local breadcrumb
	local details_column
	local details_scroll
	-- the view the thumbnails are drawn from, until it is dragged
	local detail = {orbit = OrbitCamera.New(), auto_rotate = true}
	detail.orbit:SetYaw(math.pi / 4)
	detail.orbit:SetPitch(-math.asin(1 / math.sqrt(3)))
	local tab_buttons = {}
	local details_entry
	local details_status
	local last_search_query = ""
	local last_search_results
	local last_search_folder
	local last_search_version

	local function get_index()
		return assets.GetIndex(state.category)
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

	local function build_tree_items()
		local index = get_index()
		state.root = index.root

		while #state.root.entries == 0 and #state.root.folders == 1 do
			state.root = state.root.folders[1]
		end

		local root = {
			Key = state.category,
			Text = ("%s  (%d)"):format(state.category, state.root.count),
			Folder = state.root,
			Chain = {[state.root] = true},
			Children = {__lazy = true},
			ChildrenLoaded = false,
		}
		ensure_children(root)
		expanded[root.Key] = true
		return {root}
	end

	local function reveal_in_tree(folder)
		local items = tree_view:GetItems()
		local ancestors = {}
		local current = folder

		while current do
			table.insert(ancestors, 1, current)

			if current == state.root then break end

			current = current.parent
		end

		local node = items[1]

		for i = 2, #ancestors do
			ensure_children(node)
			expanded[node.Key] = true
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

		tree_view:Rebuild(true)
		tree_view:SetSelectedKey(node.Key)
		tree_view:EnsureVisible(node.Key)
	end

	local function update_status()
		if not (status_text and status_text:IsValid()) then return end

		local entry = state.hovered or state.selected
		local text = ""

		if entry then
			text = entry.is_folder and entry.folder.path or entry.path
		else
			text = state.folder.path ~= "" and state.folder.path or state.category
		end

		status_text.text:SetText(text)
	end

	local function rebuild_breadcrumb()
		breadcrumb:RemoveChildren()
		local folder = state.folder
		local chain = {}

		while folder do
			table.insert(chain, 1, folder)

			if folder == state.root then break end

			folder = folder.parent
		end

		for i, crumb in ipairs(chain) do
			if i > 1 then
				breadcrumb:AddChild(Text{Text = "/", Color = "text_disabled", layout = {FitWidth = true}})
			end

			local target = crumb
			breadcrumb:AddChild(
				Clickable{
					Mode = "text",
					Padding = Rect(4, 2, 4, 2),
					OnClick = function()
						window_navigate(target, true)
					end,
					layout = {FitWidth = true, FitHeight = true},
				}{
					Text{
						Text = crumb == state.root and state.category or crumb.name,
						Font = i == #chain and "body_strong S" or "body S",
						IgnoreMouseInput = true,
					},
				}
			)
		end
	end

	local function refresh_items(keep_scroll)
		local index = get_index()
		local folder = state.folder
		local query = state.query:match("^%s*(.-)%s*$")
		local items

		if query ~= "" then
			local scope = folder.path ~= "" and folder.path or nil
			local source

			if
				last_search_results and
				last_search_folder == folder and
				last_search_version == index.version and
				query:starts_with(last_search_query)
			then
				source = last_search_results
			end

			items = assets.Search(state.category, query, {prefix = scope, entries = source})
			last_search_query = query
			last_search_results = items
			last_search_folder = folder
			last_search_version = index.version
		else
			last_search_results = nil
			items = {}
			local prefix = folder.path:lower()

			if state.recursive then
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

		state.items = items
		grid:SetItems(items, keep_scroll)

		if state.selected then grid:SelectItem(state.selected) end

		local asset_count = 0
		local folder_count = 0

		for _, item in ipairs(items) do
			if item.is_folder then
				folder_count = folder_count + 1
			else
				asset_count = asset_count + 1
			end
		end

		count_text.text:SetText(
			folder_count > 0 and
				(
					"%d folders, %d assets"
				):format(folder_count, asset_count) or
				(
					"%d assets"
				):format(asset_count)
		)
		update_status()
	end

	local function select_item(item)
		state.selected = item and not item.is_folder and item or nil
		update_status()
	end

	window_navigate = function(folder, reveal)
		if folder.path:lower():starts_with("textures/internals/") then
			assets.RefreshInternalTextures()
		end

		state.folder = folder
		state.selected = nil
		rebuild_breadcrumb()

		if reveal then reveal_in_tree(folder) end

		refresh_items()
		select_item(nil)
	end

	local function set_category(name)
		if name == "textures" then assets.RefreshInternalTextures() end

		state.category = name
		state.selected = nil
		last_search_results = nil

		for category_name, button in pairs(tab_buttons) do
			button:SetState("active", category_name == name)
		end

		tree_view:SetItems(build_tree_items())
		tree_view:SetSelectedKey(name)
		window_navigate(state.root, false)
	end

	local function pick(entry)
		if props.OnPick(entry, window) ~= false then window:Remove() end
	end

	local function open_source_viewer(entry)
		local source = asset_info.ReadSource(entry)

		if not source then return end

		Panel.World:Ensure(
			Window{
				Key = "AssetSourceViewer/" .. entry.path,
				Title = entry.path:upper(),
				Size = Vec2(760, 560),
				Position = Vec2(220, 120),
			}{
				TextEdit{
					Text = source,
					Editable = false,
					Wrap = false,
					ScrollX = true,
					ScrollY = true,
					Size = Vec2(720, 500),
					MinSize = Vec2(100, 100),
					MaxSize = Vec2(0, 0),
					layout = {GrowWidth = 1, GrowHeight = 1},
				},
			}
		)
	end

	local function is_viewable_model(entry)
		return entry.category == "models" and RENDER_3D and entry.extension ~= ".bsp"
	end

	local function open_model_viewer(entry)
		import("lua/model_viewer.lua")(entry)
	end

	local function activate_item(item)
		if item.is_folder then
			window_navigate(item.folder, true)
			return
		end

		if picking then return pick(item) end

		if is_viewable_model(item) then return open_model_viewer(item) end

		if item.category == "textures" then
			local texture = assets.GetTexture(item.path)

			if texture then TextureViewer(texture, item.path) end
		end
	end

	local function open_context_menu(item)
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
						OnClick = function()
							window_navigate(item.folder, true)
						end,
					},
					MenuItem{
						Text = "Copy path",
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
				picking and
				MenuItem{
					Text = "Select",
					OnClick = function()
						pick(entry)
					end,
				} or
				nil,
				MenuItem{
					Text = "Copy path",
					OnClick = function()
						clipboard.Set(entry.path)
					end,
				},
				MenuItem{
					Text = "Copy name",
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
					OnClick = function()
						open_source_viewer(entry)
					end,
				} or
				nil,
				entry.category == "textures" and
				MenuItem{
					Text = "Open in texture viewer",
					OnClick = function()
						activate_item(entry)
					end,
				} or
				nil,
				is_viewable_model(entry) and
				MenuItem{
					Text = "Open in model viewer",
					OnClick = function()
						open_model_viewer(entry)
					end,
				} or
				nil,
				is_viewable_model(entry) and
				MenuItem{
					Text = "Spawn in front of camera",
					OnClick = function()
						spawn_model(entry)
					end,
				} or
				nil,
				entry.category == "models" and
				get_selected_entity() and
				MenuItem{
					Text = "Use as model of selected entity",
					OnClick = function()
						apply_model(get_selected_entity(), entry)
					end,
				} or
				nil,
				entry.category == "materials" and
				get_selected_entity() and
				MenuItem{
					Text = "Apply to selected entity",
					OnClick = function()
						apply_material(get_selected_entity(), entry)
					end,
				} or
				nil,
				entry.category == "prefabs" and
				MenuItem{
					Text = "Place in front of camera",
					OnClick = function()
						place_prefab(entry)
					end,
				} or
				nil,
				entry.category == "prefabs" and
				get_selected_instance() and
				MenuItem{
					Text = "Use as prefab of selected instance",
					OnClick = function()
						get_selected_instance().prefab:SetPath(entry.name)
					end,
				} or
				nil,
				entry.preview and
				entry.preview.status == "failed" and
				MenuItem{
					Text = "Retry preview",
					OnClick = function()
						previews.Release(entry)
					end,
				} or
				nil,
				MenuSpacer{},
				MenuItem{
					Text = "Debug info",
					Items = function()
						local debug_items = {}

						for _, section in ipairs(asset_info.Get(entry)) do
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
			item.label = elide(colors.font, item.name, width)
			item.label_width = width
			item.sub_label = item.is_folder and
				(
					"%d assets"
				):format(item.folder.count) or
				item.extension:sub(2)
		end

		if item.is_folder then
			draw_folder_icon(px, py, pw, pw, colors.folder)
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

	local function stop_detail_preview()
		if detail.owns_entity and detail.entity:IsValid() then detail.entity:Remove() end

		if detail.preview and detail.preview:IsValid() then detail.preview:Remove() end

		if detail.material then previews.ReleaseMaterial(detail.material) end

		detail.entity = nil
		detail.owns_entity = false
		detail.preview = nil
		detail.material = nil
		detail.visuals = nil
		detail.ready = false
		detail.entry = nil
	end

	local function start_detail_preview(entry)
		stop_detail_preview()
		detail.entry = entry

		if entry.category == "models" and entry.extension ~= ".bsp" then
			detail.entity = previews.CreateModelEntity(entry.path)
			detail.owns_entity = detail.entity ~= nil
			detail.preview = ModelPreview.New{
				Width = DETAIL_PREVIEW_SIZE,
				Height = DETAIL_PREVIEW_SIZE,
				Padding = 1.1,
			}
		elseif entry.category == "prefabs" and RENDER_3D then
			local ok, entity, visuals = pcall(previews.CreatePrefabEntity, entry.name)

			if ok then
				detail.entity = entity
				detail.visuals = visuals
				detail.owns_entity = true
				detail.preview = ModelPreview.New{
					Width = DETAIL_PREVIEW_SIZE,
					Height = DETAIL_PREVIEW_SIZE,
					Padding = 1.1,
				}
			end
		elseif entry.category == "materials" then
			local ok, material = xpcall(previews.LoadMaterial, debug.traceback, entry)

			if ok and material then
				detail.material = material
				detail.entity = previews.GetMaterialSphere()
				detail.preview = ModelPreview.New{
					Width = DETAIL_PREVIEW_SIZE,
					Height = DETAIL_PREVIEW_SIZE,
					Padding = 1.1,
				}
			end
		end
	end

	local function update_detail_preview(dt)
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

		if detail.auto_rotate then detail.orbit:Rotate(-dt * 60, 0) end

		detail.preview:SetViewOffset(detail.orbit:GetViewOffset())

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
		local th = theme.active
		th:DrawBoxShape(x, y, w, h, {fill = "actual_black", fill_alpha = 0.18})
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

	local function draw_detail_preview(self)
		refresh_colors()
		local th = theme.active
		local size = self.Owner.transform:GetSize()
		th:DrawBoxShape(0, 0, size.x, size.y, {fill = colors.preview_background, radius = 6})
		local entry = state.selected

		if not entry then
			draw_centered_text(colors.font, "no selection", 0, 0, size.x, size.y, colors.preview_text)
			return
		end

		local preview = previews.Request(entry)
		local pad = 8

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

		if detail.entry == entry and detail.ready and detail.preview:IsValid() then
			detail.preview:Draw(pad, pad, size.x - pad * 2, size.y - pad * 2)
			draw_text(
				colors.font_small,
				detail.auto_rotate and "drag to rotate" or "drag to rotate, click to spin",
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

	local channels_panel
	local channel_textures = {}
	local channel_labels = {}
	local channel_count = 0
	local channel_rows = 0

	local function collect_channels()
		channel_count = 0
		local material = detail.material

		if not (material and detail.ready) then return end

		for _, info in ipairs(material:GetTextures()) do
			channel_count = channel_count + 1
			channel_textures[channel_count] = info.texture
			channel_labels[channel_count] = info.name:lower()
		end
	end

	local function get_channel_at(x, y)
		local per_row = math.max(
			1,
			math.floor((channels_panel.transform:GetWidth() + CHANNEL_GAP) / (CHANNEL_SIZE + CHANNEL_GAP))
		)
		local column = math.floor(x / (CHANNEL_SIZE + CHANNEL_GAP))
		local row = math.floor(y / (CHANNEL_SIZE + 18 + CHANNEL_GAP))

		if column >= per_row or x - column * (CHANNEL_SIZE + CHANNEL_GAP) > CHANNEL_SIZE then
			return
		end

		local index = row * per_row + column + 1

		if index <= channel_count then return index end
	end

	local function draw_channels(self)
		refresh_colors()
		local per_row = math.max(
			1,
			math.floor((self.Owner.transform:GetWidth() + CHANNEL_GAP) / (CHANNEL_SIZE + CHANNEL_GAP))
		)

		for i = 1, channel_count do
			local x = ((i - 1) % per_row) * (CHANNEL_SIZE + CHANNEL_GAP)
			local y = math.floor((i - 1) / per_row) * (CHANNEL_SIZE + 18 + CHANNEL_GAP)
			render2d.DrawBox(x, y, CHANNEL_SIZE, CHANNEL_SIZE, 4, colors.preview_background)

			if channel_textures[i]:IsReady() then
				render2d.SetTexture(channel_textures[i])
				render2d.SetColor(1, 1, 1, 1)
				render2d.DrawRect(x + 2, y + 2, CHANNEL_SIZE - 4, CHANNEL_SIZE - 4)
			end

			draw_text(colors.font_small, channel_labels[i], x, y + CHANNEL_SIZE + 2, colors.text_disabled)
		end
	end

	local channels_source = false

	local function update_channels()
		local source = detail.ready and detail.material or false

		if source == channels_source then return end

		channels_source = source
		collect_channels()
		local per_row = math.max(
			1,
			math.floor((channels_panel.transform:GetWidth() + CHANNEL_GAP) / (CHANNEL_SIZE + CHANNEL_GAP))
		)
		local rows = math.ceil(channel_count / per_row)
		channel_rows = rows
		local height = rows * (CHANNEL_SIZE + 18 + CHANNEL_GAP)
		channels_panel.visual:SetVisible(rows > 0)
		channels_panel.layout:SetMinSize(Vec2(0, height))
		channels_panel.layout:SetMaxSize(Vec2(0, height))
	end

	local detail_drag_x
	local detail_drag_y

	local function rebuild_details()
		details_column:RemoveChildren()
		local entry = state.selected
		details_entry = entry
		details_status = entry and entry.preview and entry.preview.status or "none"

		if not entry then
			details_column:AddChild(
				Text{
					Text = picking and
						"Select an asset, then press Select." or
						"Select an asset to see details.",
					Wrap = true,
					Color = "text_disabled",
					layout = {GrowWidth = 1},
				}
			)
			return
		end

		details_column:AddChild(
			Text{
				Text = entry.name .. entry.extension,
				Font = "body_strong M",
				Wrap = true,
				layout = {GrowWidth = 1},
			}
		)
		details_column:AddChild(
			Text{
				Text = entry.path,
				Font = "body S",
				Color = "text_disabled",
				Wrap = true,
				layout = {GrowWidth = 1},
			}
		)
		local actions = {}

		if picking then
			actions[#actions + 1] = Button{
				Text = "Select",
				OnClick = function()
					pick(entry)
				end,
			}
		end

		actions[#actions + 1] = Button{
			Text = "Copy path",
			Mode = "outline",
			OnClick = function()
				clipboard.Set(entry.path)
			end,
		}

		if entry.category == "textures" then
			actions[#actions + 1] = Button{
				Text = "Open",
				Mode = "outline",
				OnClick = function()
					activate_item(entry)
				end,
			}
		end

		local target = get_selected_entity()

		if is_viewable_model(entry) then
			actions[#actions + 1] = Button{
				Text = "View",
				Mode = "outline",
				OnClick = function()
					open_model_viewer(entry)
				end,
			}
			actions[#actions + 1] = Button{
				Text = "Spawn",
				Mode = "outline",
				OnClick = function()
					spawn_model(entry)
				end,
			}

			if target then
				actions[#actions + 1] = Button{
					Text = "Use on selected",
					Mode = "outline",
					OnClick = function()
						apply_model(target, entry)
					end,
				}
			end
		elseif entry.category == "materials" and target then
			actions[#actions + 1] = Button{
				Text = "Apply to selected",
				Mode = "outline",
				OnClick = function()
					apply_material(target, entry)
				end,
			}
		elseif entry.category == "prefabs" then
			actions[#actions + 1] = Button{
				Text = "Place",
				Mode = "outline",
				OnClick = function()
					place_prefab(entry)
				end,
			}

			if get_selected_instance() then
				actions[#actions + 1] = Button{
					Text = "Use on selected",
					Mode = "outline",
					OnClick = function()
						get_selected_instance().prefab:SetPath(entry.name)
					end,
				}
			end
		end

		details_column:AddChild(Row{layout = {GrowWidth = 1, ChildGap = 6, WrapChildren = true}}(actions))

		for _, section in ipairs(asset_info.Get(entry)) do
			details_column:AddChild(
				Text{
					Text = section.title:upper(),
					Font = "body_strong S",
					Color = "text_disabled",
					layout = {FitWidth = true, Margin = Rect(0, 8, 0, 2)},
				}
			)

			for _, row in ipairs(section.rows) do
				details_column:AddChild(
					Row{layout = {GrowWidth = 1, AlignmentY = "start", ChildGap = 8}}{
						Text{
							Text = row[1],
							Font = "body S",
							Color = "text_disabled",
							layout = {MinSize = Vec2(92, 0), MaxSize = Vec2(92, 0), FitWidth = false},
						},
						Text{Text = row[2], Font = "body S", Wrap = true, layout = {GrowWidth = 1}},
					}
				)
			end
		end
	end

	local zoom_changed = false
	local recursive_button
	local toolbar_widgets = {}

	if #categories > 1 then
		for _, name in ipairs(categories) do
			toolbar_widgets[#toolbar_widgets + 1] = Button{
				Text = name,
				Mode = "outline",
				Active = name == state.category,
				Ref = function(self)
					tab_buttons[name] = self
				end,
				OnClick = function()
					set_category(name)
				end,
			}
		end
	end

	toolbar_widgets[#toolbar_widgets + 1] = TextEdit{
		Ref = function(self)
			filter_edit = self
		end,
		Text = state.query,
		Hint = "search names and paths in the selected folder",
		Size = Vec2(0, theme.active:GetInputHeight("M")),
		MinSize = Vec2(160, theme.active:GetInputHeight("M")),
		MaxSize = Vec2(0, theme.active:GetInputHeight("M")),
		Wrap = false,
		ScrollX = false,
		ScrollY = false,
		OnTextChanged = function(_, text)
			if text == state.query then return end

			state.query = text
			state.search_deadline = system.GetElapsedTime() + 0.12
		end,
		layout = {GrowWidth = 1},
	}
	toolbar_widgets[#toolbar_widgets + 1] = Text{
		Ref = function(self)
			count_text = self
		end,
		Text = "",
		Color = "text_disabled",
		layout = {FitWidth = true, MinSize = Vec2(80, 0)},
	}
	toolbar_widgets[#toolbar_widgets + 1] = Slider{
		Mode = "horizontal",
		Min = 72,
		Max = 240,
		Value = state.zoom,
		OnChange = function(value)
			state.zoom = math.floor(value)
			zoom_changed = true
		end,
		Tooltip = "tile size",
		layout = {MinSize = Vec2(110, 16), MaxSize = Vec2(110, 16), FitWidth = false},
	}
	toolbar_widgets[#toolbar_widgets + 1] = Button{
		Text = "Subfolders",
		Mode = "outline",
		Tooltip = "list every asset below the selected folder",
		Ref = function(self)
			recursive_button = self
		end,
		OnClick = function()
			state.recursive = not state.recursive
			recursive_button:SetActive(state.recursive)
			refresh_items()
		end,
	}
	toolbar_widgets[#toolbar_widgets + 1] = Button{
		Text = "Refresh",
		Mode = "outline",
		OnClick = function()
			assets.InvalidateIndex(state.category)
			set_category(state.category)
		end,
	}
	window = Window{
		Key = props.Key or "AssetBrowserWindow",
		Title = props.Title or
			(
				picking and
				(
					"PICK " .. categories[1]:upper()
				)
				or
				"ASSET BROWSER"
			),
		Size = props.Size or Vec2(1280, 760),
		Padding = "none",
		Position = props.Position or
			(
				Panel.World.transform:GetSize() - (
					props.Size or
					Vec2(1280, 760)
				)
			) / 2,
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
			Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center"}}(toolbar_widgets),
			Splitter{
				InitialSize = 260,
				layout = {GrowWidth = 1, GrowHeight = 1},
			}{
				ScrollablePanel{
					Padding = Rect(),
					ScrollX = false,
					ScrollY = true,
					layout = {GrowWidth = 1, GrowHeight = 1},
				}{
					Tree{
						Ref = function(self)
							tree_view = self
						end,
						Items = {},
						LabelGrow = true,
						layout = {GrowWidth = 1, FitHeight = true},
						OnIsExpanded = function(node, path, key)
							return expanded[key] == true
						end,
						OnSelect = function(node)
							if not node then return end

							window_navigate(node.Folder, false)
						end,
						OnToggle = function(node, is_expanded, key)
							expanded[key] = is_expanded == true

							if is_expanded and ensure_children(node) then
								tree_view:RefreshBranchForKey(key)
							end
						end,
					},
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
					Row{
						Ref = function(self)
							breadcrumb = self
						end,
						layout = {GrowWidth = 1, ChildGap = 2, AlignmentY = "center"},
					}{},
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
							Ref = function(self)
								grid = self
							end,
							CellWidth = state.zoom,
							ExtraHeight = LABEL_HEIGHT,
							Gap = 8,
							ContentPadding = 6,
							OnDrawItem = draw_item,
							OnSelect = select_item,
							OnActivate = activate_item,
							OnContextMenu = open_context_menu,
							OnHoverItem = function(item)
								state.hovered = item
								update_status()
							end,
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
							Panel.New{
								Name = "AssetDetailPreview",
								transform = true,
								layout = {
									GrowWidth = 1,
									MinSize = Vec2(0, 320),
									MaxSize = Vec2(0, 320),
								},
								visual = {OnDraw = draw_detail_preview},
								mouse_input = {Cursor = "sizeall"},
								OnMouseInput = function(self, button, press)
									if button ~= "button_1" then return end

									if press then
										detail_drag_x, detail_drag_y = system.GetWindow():GetMousePosition():Unpack()
										detail.press_x, detail.press_y = detail_drag_x, detail_drag_y
										detail.dragging = true
									else
										detail.dragging = false
										local x, y = system.GetWindow():GetMousePosition():Unpack()

										if math.abs(x - detail.press_x) + math.abs(y - detail.press_y) < 3 then
											detail.auto_rotate = not detail.auto_rotate
										end
									end

									return true
								end,
							},
							Panel.New{
								Name = "AssetDetailChannels",
								Ref = function(self)
									channels_panel = self
								end,
								transform = true,
								layout = {GrowWidth = 1, MinSize = Vec2(0, 1), MaxSize = Vec2(0, 1)},
								visual = {Visible = false, OnDraw = draw_channels},
								mouse_input = {Cursor = "hand"},
								OnMouseInput = function(self, button, press, local_pos)
									if button ~= "button_1" or not press then return end

									local index = get_channel_at(local_pos.x, local_pos.y)

									if index then
										TextureViewer(channel_textures[index], state.selected.name .. " " .. channel_labels[index])
									end

									return true
								end,
							},
							ScrollablePanel{
								Ref = function(self)
									details_scroll = self
								end,
								Padding = Rect(),
								ScrollX = false,
								ScrollY = true,
								layout = {GrowWidth = 1, GrowHeight = 1},
							}{
								Column{
									Ref = function(self)
										details_column = self
									end,
									layout = {GrowWidth = 1, FitHeight = true, ChildGap = 4, AlignmentX = "stretch"},
								}{},
							},
						},
					},
				},
			},
			Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"}}{
				Text{
					Ref = function(self)
						status_text = self
					end,
					Text = "",
					Color = "text_disabled",
					Elide = true,
					layout = {GrowWidth = 1, FitWidth = false},
				},
				picking and
				Button{
					Text = "Select",
					OnClick = function()
						if state.selected then pick(state.selected) end
					end,
				} or
				nil,
				picking and
				Button{
					Text = "Cancel",
					Mode = "outline",
					OnClick = function()
						window:Remove()
					end,
				} or
				nil,
			},
		},
	}
	window:AddGlobalEvent("Update")

	function window:SetCategory(name)
		set_category(name)
		return self
	end

	function window:Navigate(path)
		local folder = get_index().folders[path:lower()]

		if folder then window_navigate(folder, true) end

		return self
	end

	function window:Search(text)
		state.query = text
		filter_edit:SetText(text)
		refresh_items()
		return self
	end

	function window:SetRecursive(recursive)
		state.recursive = recursive
		refresh_items()
		return self
	end

	function window:SelectPath(path)
		local entry = get_index().by_path[path:lower()]

		if not entry then return self end

		window_navigate(entry.folder, true)
		grid:SelectItem(entry)
		return self
	end

	function window:PickSelected()
		if state.selected then pick(state.selected) end

		return self
	end

	function window:OpenContextMenu(entry)
		open_context_menu(entry)
		return self
	end

	function window:GetGrid()
		return grid
	end

	function window:GetBrowserState()
		return state
	end

	function window:OnUpdate(dt)
		if state.search_deadline and system.GetElapsedTime() >= state.search_deadline then
			state.search_deadline = nil
			refresh_items()
		end

		if zoom_changed then
			zoom_changed = false
			grid:SetCellWidth(state.zoom)
		end

		local entry = state.selected
		local status = entry and entry.preview and entry.preview.status or "none"

		if entry ~= details_entry or status ~= details_status then rebuild_details() end

		if detail.entry ~= entry then
			if entry then start_detail_preview(entry) else stop_detail_preview() end
		end

		if detail.dragging then
			local x, y = system.GetWindow():GetMousePosition():Unpack()
			detail.orbit:Rotate(x - detail_drag_x, y - detail_drag_y)
			detail_drag_x, detail_drag_y = x, y

			if math.abs(x - detail.press_x) + math.abs(y - detail.press_y) >= 3 then
				detail.auto_rotate = false
			end
		end

		update_detail_preview(dt)
		update_channels()
	end

	open_windows = open_windows + 1

	window:CallOnRemove(
		function()
			stop_detail_preview()
			open_windows = open_windows - 1

			if open_windows == 0 then previews.Clear() end
		end,
		"asset_browser_cleanup"
	)

	set_category(state.category)
	rebuild_details()
	filter_edit:GetTextPanel():RequestFocus()

	if props.SelectedPath and props.SelectedPath ~= "" then
		local index = get_index()
		local entry = index.by_path[props.SelectedPath:lower()]

		if entry then
			window_navigate(entry.folder, true)
			grid:SelectItem(entry)
		end
	end

	return window
end
