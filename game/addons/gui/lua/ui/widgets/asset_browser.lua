local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Panel = import("goluwa/ecs/panel.lua")
local assets = import("goluwa/assets.lua")
local Window = import("../widgets/window.lua")
local Splitter = import("../elements/splitter.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Clickable = import("../elements/clickable.lua")
local Column = import("../elements/column.lua")
local Row = import("../elements/row.lua")
local Frame = import("../elements/frame.lua")
local Text = import("../elements/text.lua")
local TextEdit = import("../elements/text_edit.lua")
local Tree = import("../widgets/tree.lua")
local theme = import("../theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Material = import("goluwa/render3d/material.lua")
local ModelPreview = import("game/addons/gui/lua/model_preview.lua")
local DEFAULT_CATEGORY_ORDER = {
	{name = "models", label = "models"},
	{name = "textures", label = "textures"},
}
local MODEL_COLUMNS = 3
local TEXTURE_COLUMNS = 4
local MATERIAL_TEXTURE_GETTERS = {
	"GetAlbedoTexture",
	"GetNormalTexture",
	"GetMetallicRoughnessTexture",
	"GetAmbientOcclusionTexture",
	"GetEmissiveTexture",
	"GetAlbedo2Texture",
	"GetNormal2Texture",
	"GetBlendTexture",
	"GetMetallicTexture",
	"GetRoughnessTexture",
}

local function build_category_order(props)
	if props.Categories and props.Categories[1] then
		local out = {}

		for _, name in ipairs(props.Categories) do
			out[#out + 1] = {
				name = name,
				label = name,
			}
		end

		return out
	end

	if props.PickerCategory then
		return {
			{
				name = props.PickerCategory,
				label = props.PickerCategory,
			},
		}
	end

	return DEFAULT_CATEGORY_ORDER
end

local function update_layout_now(entity)
	if not entity or not entity:IsValid() or not entity.layout then return end

	entity.layout:InvalidateLayout()
	local root = entity.layout
	local parent = entity:GetParent()

	while parent and parent:IsValid() and parent.layout do
		root = parent.layout
		parent = parent:GetParent()
	end

	root:UpdateLayout()
end

local function normalize_query(query)
	query = tostring(query or "")
	query = query:gsub("^%s+", "")
	query = query:gsub("%s+$", "")
	return query:lower()
end

local function split_path(path)
	return path:split("/")
end

local function asset_matches_query(entry, query)
	if query == "" then return true end

	local name = (entry.name or ""):lower()
	local path = (entry.path or ""):lower()
	return name:find(query, 1, true) ~= nil or path:find(query, 1, true) ~= nil
end

local function make_lazy_children()
	return {__lazy = true}
end

local function make_folder_node(category_name, path, text)
	return {
		Key = category_name .. "|" .. path,
		Text = text,
		Category = category_name,
		Prefix = path,
		Children = make_lazy_children(),
		ChildrenLoaded = false,
	}
end

local function build_tree_items(category_order)
	local items = {}

	for _, category_info in ipairs(category_order) do
		items[#items + 1] = {
			Key = category_info.name,
			Text = category_info.label,
			Category = category_info.name,
			Prefix = nil,
			Children = make_lazy_children(),
			ChildrenLoaded = false,
		}
	end

	return items
end

local function ensure_tree_children(node)
	if not node or node.ChildrenLoaded then return false end

	node.ChildrenLoaded = true
	node.Children = {}

	for _, entry in ipairs(assets.EnumerateFolders(node.Category, {prefix = node.Prefix})) do
		node.Children[#node.Children + 1] = make_folder_node(node.Category, entry.path, entry.name)
	end

	return true
end

local function find_first_node(items)
	for _, node in ipairs(items or {}) do
		return node
	end

	return nil
end

local function find_tree_node(items, key)
	for _, item in ipairs(items or {}) do
		if item.Key == key then return item end

		local found = find_tree_node(item.Children, key)

		if found then return found end
	end

	return nil
end

local function create_preview_entity_from_descriptor(descriptor)
	local entity = Entity.New{Name = descriptor.name or "asset_browser_model"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:SetVisible(false)

	for index, primitive in ipairs(descriptor.create_primitives({})) do
		local primitive_entity = Entity.New{
			Name = (descriptor.name or "asset_browser_model") .. "_primitive_" .. index,
			Parent = entity,
		}
		primitive_entity:AddComponent("transform")
		local visual_primitive = primitive_entity:AddComponent("visual_primitive")
		visual_primitive:SetPolygon3D(primitive.mesh or primitive.polygon3d or primitive)

		if primitive.material then visual_primitive:SetMaterial(primitive.material) end
	end

	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity
end

local function load_material_asset(path)
	local resolved = assets.ResolvePath(path, "materials")
	local virtual_asset = resolved and assets.virtual_assets and assets.virtual_assets[resolved] or nil

	if virtual_asset and type(virtual_asset.load) == "function" then
		local ok, result = xpcall(function()
			return virtual_asset.load(resolved)
		end, debug.traceback)

		if ok and result ~= nil then
			if type(result) == "table" and result.Type == "render3d_material" then
				return result
			end

			if type(result) == "table" then return Material.New(result) end
		end
	end

	local extension = path:match("(%.[^./]+)$")

	if extension and extension:lower() == ".vmt" then
		return Material.FromVMT(path)
	end

	local ok, result = xpcall(function()
		return import(path)
	end, debug.traceback)

	if not ok or result == nil then return nil end

	if type(result) == "function" then
		ok, result = xpcall(function()
			return result()
		end, debug.traceback)

		if not ok then return nil end
	end

	if type(result) == "table" and result.Type == "render3d_material" then
		return result
	end

	if type(result) == "table" then return Material.New(result) end

	return nil
end

local function get_material_preview_texture(material)
	if not material then return nil end

	local texture = material.GetAlbedoTexture and material:GetAlbedoTexture() or nil

	if texture and texture.IsReady and not texture:IsReady() then return nil end

	return texture
end

local function create_preview_entity_for_model(path)
	local entry = assets.GetModel(path)

	if entry and entry.value and type(entry.value.create_primitives) == "function" then
		return create_preview_entity_from_descriptor(entry.value)
	end

	if path:ends_with(".lua") then return nil end

	local entity = Entity.New{Name = path}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual:SetVisible(false)
	entity.visual:SetUseOcclusionCulling(false)
	entity.visual:SetModelPath(path)
	return entity
end

local function material_is_ready(material)
	if not material then return true end

	if material.vmt_path and not material.vmt then return false end

	for _, getter_name in ipairs(MATERIAL_TEXTURE_GETTERS) do
		local getter = material[getter_name]

		if getter then
			local texture = getter(material)

			if texture and texture.IsReady and not texture:IsReady() then return false end
		end
	end

	return true
end

local function model_materials_are_ready(model)
	local material_override = model:GetMaterialOverride()

	if not material_is_ready(material_override) then return false end

	local primitives = model:GetRenderEntries()

	for _, primitive in ipairs(primitives) do
		local material = model:GetResolvedMaterial(primitive)

		if not material_is_ready(material) then return false end
	end

	return true
end

local function build_model_tile(entry, scheduler)
	local entity
	local preview
	local preview_panel
	local render_complete = false
	local render_requested = true
	local load_started = false
	local base_angles = Ang3(0.18, 0.72, 0.06)

	local function is_panel_visible()
		if not (preview_panel and preview_panel.IsValid and preview_panel:IsValid()) then
			return false
		end

		local x1, y1, x2, y2 = preview_panel.transform:GetVisibleLocalRect(
			0,
			0,
			preview_panel.transform:GetWidth(),
			preview_panel.transform:GetHeight()
		)
		return x1 ~= nil and x2 > x1 and y2 > y1
	end

	local function cleanup_entity()
		if entity and entity.IsValid and entity:IsValid() then entity:Remove() end

		entity = nil
		load_started = false
	end

	local function ensure_preview_texture()
		if render_complete then return true end

		if preview and preview.IsValid and preview:IsValid() and not render_requested then
			return true
		end

		if not is_panel_visible() then
			if not render_complete then cleanup_entity() end

			return false
		end

		if not entity then
			if not scheduler:ConsumePreviewStep() then return false end

			entity = create_preview_entity_for_model(entry.path)
			load_started = entity ~= nil

			if entity and entity.transform then entity.transform:SetAngles(base_angles) end

			return false
		end

		if not (entity and entity.IsValid and entity:IsValid()) then return false end

		local target = entity.visual

		if not target then return false end

		local primitives = target:GetRenderEntries()

		if not (primitives and primitives[1]) then return false end

		if target.IsLoading and target:IsLoading() then return false end

		if not model_materials_are_ready(target) then return false end

		preview = ModelPreview.New{
			Padding = 1.12,
			AmbientStrength = 0.34,
			LightStrength = 0.95,
		}
		preview:SetTarget(target)
		render_requested = true

		if not scheduler:ConsumePreviewStep() then return false end

		preview:Refresh()
		render_requested = false
		render_complete = true
		cleanup_entity()
		return true
	end

	local function cleanup()
		if preview and preview.IsValid and preview:IsValid() then preview:Remove() end

		cleanup_entity()
		preview = nil
		render_complete = false
		render_requested = true
	end

	return Frame{
		Padding = Rect() + 12,
		layout = {
			FitWidth = true,
			FitHeight = true,
			SelfAlignmentY = "start",
			MinSize = Vec2(188, 240),
		},
	}{
		Column{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				layout = {
					Size = Vec2(164, 164),
					MinSize = Vec2(164, 164),
					MaxSize = Vec2(164, 164),
				},
				OnRemove = cleanup,
				Ref = function(self)
					preview_panel = self
					self:AddGlobalEvent("Update")
				end,
				OnUpdate = function()
					ensure_preview_texture()
				end,
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					theme.active:DrawPreviewTileFrame(size)

					if preview and preview.IsValid and preview:IsValid() then
						render2d.SetTexture(preview:GetTexture())
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(6, 6, size.x - 12, size.y - 12)
					elseif load_started then
						theme.active:DrawPreviewTileFrame(
							size,
							{
								inset = 18,
								radius = 12,
								fill_alpha = 0,
								outline_alpha = 0,
								inset_outline_alpha = 0.4,
							}
						)
					end
				end,
			},
			Text{
				Text = entry.name,
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = entry.path,
				Wrap = true,
				WrapToParent = false,
				Size = Vec2(164, 0),
				IgnoreMouseInput = true,
				Color = "text_disabled",
				layout = {
					MinSize = Vec2(164, 0),
					MaxSize = Vec2(164, 0),
				},
			},
		},
	}
end

local function build_texture_tile(entry, on_pick)
	local preview_texture = assets.GetTexture(entry.path, {config = {srgb = true}})
	local texture = assets.GetTexture(entry.path)
	return Clickable{
		Padding = Rect() + 12,
		Mode = "filled",
		Color = "surface",
		OnClick = on_pick and function()
			return on_pick(entry, texture)
		end or nil,
		layout = {
			FitWidth = true,
			FitHeight = true,
			SelfAlignmentY = "start",
			MinSize = Vec2(164, 216),
		},
	}{
		Column{
			mouse_input = {
				IgnoreMouseInput = true,
			},
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				layout = {
					Size = Vec2(136, 136),
					MinSize = Vec2(136, 136),
					MaxSize = Vec2(136, 136),
				},
				mouse_input = {
					IgnoreMouseInput = true,
				},
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					theme.active:DrawPreviewTileFrame(size)

					if preview_texture and preview_texture.IsReady and preview_texture:IsReady() then
						render2d.SetTexture(preview_texture)
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(8, 8, size.x - 16, size.y - 16)
					end
				end,
			},
			Text{
				Text = entry.name,
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = entry.path,
				Wrap = true,
				WrapToParent = false,
				Size = Vec2(136, 0),
				IgnoreMouseInput = true,
				Color = "text_disabled",
				layout = {
					MinSize = Vec2(136, 0),
					MaxSize = Vec2(136, 0),
				},
			},
		},
	}
end

local function build_material_tile(entry, on_pick)
	local material = load_material_asset(entry.path)
	return Clickable{
		Padding = Rect() + 12,
		Mode = "filled",
		Color = "surface",
		OnClick = on_pick and function()
			return on_pick(entry, material)
		end or nil,
		layout = {
			FitWidth = true,
			FitHeight = true,
			SelfAlignmentY = "start",
			MinSize = Vec2(164, 216),
		},
	}{
		Column{
			mouse_input = {
				IgnoreMouseInput = true,
			},
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				ChildGap = 10,
			},
		}{
			Panel.New{
				transform = true,
				rect = true,
				layout = {
					Size = Vec2(136, 136),
					MinSize = Vec2(136, 136),
					MaxSize = Vec2(136, 136),
				},
				mouse_input = {
					IgnoreMouseInput = true,
				},
				OnDraw = function(self)
					local size = self.transform.Size + self.transform.DrawSizeOffset
					local texture = get_material_preview_texture(material)
					theme.active:DrawPreviewTileFrame(size)

					if texture then
						render2d.SetTexture(texture)
						render2d.SetColor(1, 1, 1, 1)
						render2d.DrawRect(8, 8, size.x - 16, size.y - 16)
					end
				end,
			},
			Text{
				Text = entry.name,
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = entry.path,
				Wrap = true,
				WrapToParent = false,
				Size = Vec2(136, 0),
				IgnoreMouseInput = true,
				Color = "text_disabled",
				layout = {
					MinSize = Vec2(136, 0),
					MaxSize = Vec2(136, 0),
				},
			},
		},
	}
end

local function build_tile(entry, scheduler, on_pick)
	if entry.category == "models" then return build_model_tile(entry, scheduler) end

	if entry.category == "materials" then
		return build_material_tile(entry, on_pick)
	end

	return build_texture_tile(entry, on_pick)
end

local function build_grid_rows(entries, columns, scheduler, on_pick)
	local rows = {}

	for index = 1, #entries, columns do
		local children = {}

		for child_index = index, math.min(index + columns - 1, #entries) do
			children[#children + 1] = build_tile(entries[child_index], scheduler, on_pick)
		end

		rows[#rows + 1] = Row{
			layout = {
				GrowWidth = 1,
				FitHeight = true,
				AlignmentX = "stretch",
				AlignmentY = "start",
				ChildGap = 12,
			},
		}(children)
	end

	return rows
end

return function(props)
	props = props or {}
	local category_order = build_category_order(props)
	local default_category = category_order[1] and category_order[1].name or "models"
	local asset_index = {}
	local asset_index_loaded = {}
	local tree_items = build_tree_items(category_order)
	local expanded_keys = {}

	for _, category_info in ipairs(category_order) do
		expanded_keys[category_info.name] = false
	end

	local state = {
		query = "",
		selected_key = props.SelectedKey or default_category,
		selected_category = default_category,
		selected_prefix = nil,
		selected_asset_path = nil,
		last_filter_text = nil,
	}
	local tree_view
	local filter_edit
	local grid_column
	local header_text
	local window
	local scheduler = {
		preview_steps_remaining = 0,
	}

	function scheduler:BeginFrame()
		self.preview_steps_remaining = 1
	end

	function scheduler:ConsumePreviewStep()
		if self.preview_steps_remaining <= 0 then return false end

		self.preview_steps_remaining = self.preview_steps_remaining - 1
		return true
	end

	local function ensure_category_index(category_name)
		if asset_index_loaded[category_name] then return false end

		asset_index[category_name] = assets.Enumerate(category_name, {recursive = true})
		asset_index_loaded[category_name] = true
		return true
	end

	local function get_visible_assets()
		ensure_category_index(state.selected_category)
		local visible = {}
		local query = normalize_query(state.query)

		for _, entry in ipairs(asset_index[state.selected_category] or {}) do
			local matches_scope = false

			if state.selected_asset_path then
				matches_scope = entry.path == state.selected_asset_path
			elseif state.selected_prefix then
				matches_scope = entry.path:starts_with(state.selected_prefix)
			else
				matches_scope = true
			end

			if matches_scope and asset_matches_query(entry, query) then
				visible[#visible + 1] = entry
			end
		end

		list.sort(visible, function(a, b)
			return a.path:lower() < b.path:lower()
		end)

		return visible
	end

	local function should_show_grid_tiles()
		if props.ShowGridByDefault then return true end

		if state.selected_asset_path then return true end

		if state.selected_prefix then return true end

		return normalize_query(state.query) ~= ""
	end

	local function refresh_grid()
		if not (grid_column and grid_column:IsValid()) then return end

		grid_column:RemoveChildren()
		local show_tiles = should_show_grid_tiles()
		local visible = show_tiles and get_visible_assets() or {}
		local columns = state.selected_category == "models" and MODEL_COLUMNS or TEXTURE_COLUMNS

		if header_text and header_text:IsValid() then
			local scope = state.selected_asset_path or state.selected_prefix or state.selected_category

			if show_tiles then
				header_text.text:SetText(string.format("%s  |  %d assets", scope, #visible))
			else
				header_text.text:SetText(scope)
			end
		end

		if not show_tiles then
			grid_column:AddChild(
				Text{
					Text = "Select a folder in the tree or type a filter to load asset tiles.",
					Wrap = true,
					Color = "text_disabled",
					layout = {
						GrowWidth = 1,
					},
				}
			)
		elseif visible[1] == nil then
			grid_column:AddChild(
				Text{
					Text = "No assets match the current tree selection and filter.",
					Wrap = true,
					Color = "text_disabled",
					layout = {
						GrowWidth = 1,
					},
				}
			)
		else
			local on_pick = props.OnPickAsset and
				function(entry, material)
					return props.OnPickAsset(entry, material, window)
				end or
				nil

			for _, row in ipairs(build_grid_rows(visible, columns, scheduler, on_pick)) do
				grid_column:AddChild(row)
			end
		end

		update_layout_now(grid_column)
	end

	local function rebuild_tree()
		if not (tree_view and tree_view:IsValid()) then return end

		local selected = find_tree_node(tree_items, state.selected_key) or find_first_node(tree_items)

		if selected then
			state.selected_key = selected.Key
			state.selected_category = selected.Category
			state.selected_prefix = selected.Prefix
			state.selected_asset_path = selected.AssetPath
		end

		tree_view:SetItems(tree_items)
		tree_view:SetSelectedKey(state.selected_key)
		refresh_grid()
	end

	local function sync_filter_from_edit()
		if not (filter_edit and filter_edit:IsValid()) then return end

		local text = filter_edit:GetText()

		if text == state.last_filter_text then return end

		state.last_filter_text = text
		state.query = text
		refresh_grid()
	end

	window = Window{
		Key = props.Key or "AssetBrowserWindow",
		Title = props.Title or
			(
				props.PickerCategory and
				(
					"PICK " .. props.PickerCategory:upper()
				)
				or
				"ASSET BROWSER"
			),
		Size = props.Size or Vec2(1080, 720),
		Padding = "none",
		Position = props.Position or (Panel.World.transform:GetSize() - Vec2(1080, 720)) / 2,
		layout = {
			FitHeight = false,
			FitWidth = false,
		},
	}{
		Splitter{
			InitialSize = 260,
		}{
			Column{
				layout = {
					GrowHeight = 1,
					GrowWidth = 1,
					FitHeight = false,
					AlignmentX = "stretch",
					ChildGap = 8,
					Padding = Rect() + theme.GetPadding("XS"),
				},
			}{
				TextEdit{
					Ref = function(self)
						filter_edit = self
						self:SetText(props.Filter or "")
						state.last_filter_text = self:GetText()
						state.query = state.last_filter_text
					end,
					Text = props.Filter or "",
					Size = Vec2(0, 38),
					MinSize = Vec2(100, 38),
					MaxSize = Vec2(0, 38),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					layout = {
						GrowWidth = 1,
					},
				},
				ScrollablePanel{
					Padding = Rect(),
					ScrollX = false,
					ScrollY = true,
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					Tree{
						Ref = function(self)
							tree_view = self
						end,
						Items = tree_items,
						SelectedKey = state.selected_key,
						LabelGrow = true,
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
						IsExpanded = function(node, path, key)
							return expanded_keys[key] == true
						end,
						OnSelect = function(node)
							if not node then return end

							state.selected_key = node.Key
							state.selected_category = node.Category
							state.selected_prefix = node.Prefix
							state.selected_asset_path = node.AssetPath
							refresh_grid()
						end,
						OnToggle = function(node, expanded, key)
							if expanded then ensure_tree_children(node) end

							expanded_keys[key] = expanded == true
						end,
					},
				},
			},
			Column{
				layout = {
					GrowHeight = 1,
					GrowWidth = 1,
					FitHeight = false,
					AlignmentX = "stretch",
					ChildGap = 8,
					Padding = Rect() + theme.GetPadding("XS"),
				},
			}{
				Text{
					Ref = function(self)
						header_text = self
					end,
					Text = "",
					Font = "body_strong S",
					layout = {
						GrowWidth = 1,
						FitHeight = true,
					},
				},
				ScrollablePanel{
					Padding = Rect() + theme.GetPadding("XS"),
					ScrollX = false,
					ScrollY = true,
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					Column{
						Ref = function(self)
							grid_column = self
						end,
						layout = {
							Direction = "y",
							FitHeight = true,
							GrowWidth = 1,
							ChildGap = 12,
							AlignmentX = "stretch",
						},
					}{},
				},
			},
		},
	}
	window:AddGlobalEvent("Update")

	function window:OnUpdate()
		scheduler:BeginFrame()
		sync_filter_from_edit()
	end

	rebuild_tree()
	return window
end
