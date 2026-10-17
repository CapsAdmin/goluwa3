local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local input = import("goluwa/input.lua")
local event = import("goluwa/event.lua")
local Quat = import("goluwa/structs/quat.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Gizmo = import("lua/gizmo.lua")
local highlight = import("lua/highlight.lua")
local brush_editor = import("lua/brush_editor.lua")
local Breadcrumb = import("goluwa/render2d/ui/widgets/breadcrumb.lua")
local IconButton = import("goluwa/render2d/ui/widgets/icon_button.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local nearby = import("lua/nearby.lua")
local scene = import("goluwa/entities/scene.lua")
local prefab = import("goluwa/entities/prefab.lua")
local prefab_tools = import("lua/prefab_tools.lua")
local network = import("goluwa/network/network.lua")
local scene_sync = import("goluwa/network/scene_sync.lua")
local name_prompt = import("lua/name_prompt.lua")
local AssetBrowser = import("lua/asset_browser.lua")
local vfs = import("goluwa/vfs.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local View = import("goluwa/render3d/view.lua")
local camera = import("lua/camera.lua")
local picker = import("lua/picker.lua")
local editor_history = import("lua/editor_history.lua")
local HistoryPanel = import("lua/history_panel.lua")
local history = editor_history.history
local MATERIAL_ROOT_KEY = "__editor_3d_materials__"
-- the order the components of an entity are listed in the property editor, the rest follows alphabetically
local COMPONENT_ORDER = {
	"prefab",
	"script",
	"transform",
	"model",
	"visual",
	"rigid_body",
	"network",
}
local NONVISUAL_HINT_TIME = 0.12

local function is_hidden(entity, editor_window)
	if entity == editor_window then return true end

	if entity.Type == "panel_context_menu" then return true end

	if entity:GetName() == "TooltipOverlay" then return true end

	if entity.visual_primitive then return true end

	return false
end

local function entity_tree_filter_callback(entity, editor_window)
	if is_hidden(entity, editor_window) then return true end

	local parent = entity:GetRoot(1) or NULL

	if parent:IsValid() and is_hidden(parent, editor_window) then return true end

	return false
end

return function(props)
	props = props or {}
	local initial_selected_guid = props.SelectedEntityGUID
	local tree_view = NULL
	local tree_scroll_container = NULL
	local property_scroll_container = NULL
	local property_editor = NULL
	local editor_window = NULL
	local pending_selection_sync = false
	local sync_debounce_time = props.SyncDebounceTime or 0.1
	local editor_ui_mutation_blocked = 0
	local picker_cancel_fn = nil
	local last_scene_name
	local pending_search
	local search_deadline = 0
	local SEARCH_DEBOUNCE = 0.25
	local NEARBY_COUNT = 10
	local NEARBY_SETTLE_TIME = 0.3
	local last_camera_position
	local camera_moved_time
	local nearby_dirty = true
	local show_transient = false
	local show_nearby = false
	picker.include_transient = false

	local function set_show_transient(show)
		show_transient = show
		picker.include_transient = show
		tree_view:Refresh(true)
	end

	-- prefab mode: the instances whose definition is edited, the last one is the one the tree is rooted on
	local edit_stack = {}
	local enter_prefab_edit
	local exit_prefab_edit

	-- what is inside an instance is only visible while that instance is edited, anything else selects the instance
	local function resolve_target(target)
		local editing = edit_stack[#edit_stack]
		local stop = editing and editing.prefab or nil

		while target.prefab_owner and target.prefab_owner ~= stop do
			target = target.prefab_owner.Owner
		end

		return target
	end

	local function set_selected_target(target)
		target = resolve_target(target)

		if not show_transient and target:IsRuntime() then set_show_transient(true) end

		Gizmo.EnableGizmo(target)
		prefab_tools.Watch(target)
		tree_view:SelectEntity(target)
		tree_view:ExpandToEntity(target)
		tree_view:EnsureEntityVisible(target)
		pending_selection_sync = true
	end

	local function flush_pending_editor_sync(force) end

	local function add_child_entity(entity, parent_entity, owner, name)
		local world_position = camera.GetPosition() + camera.GetRotation():GetForward() * 2
		entity:SetParent(parent_entity)

		if owner then entity:SetOwnedBy(owner) end

		if parent_entity.transform then
			entity.transform:SetPosition(parent_entity.transform:GetWorldMatrixInverse():TransformVector(world_position))
		else
			entity.transform:SetPosition(world_position)
		end

		editor_history.RecordCreate("create " .. name, entity)
		set_selected_target(entity)
	end

	local function create_child_entity(parent_entity, owner)
		local entity = Entity.New{Name = "entity", Transient = false}
		entity:AddComponent("transform")
		add_child_entity(entity, parent_entity, owner, "entity")
	end

	local function pick_child_prefab(parent_entity, owner)
		Panel.World:Ensure(
			AssetBrowser{
				Key = "AssetPicker",
				PickerCategory = "prefabs",
				OnPick = function(asset)
					local entity = Entity.New{Name = asset.name, prefab = {Path = asset.name}}
					entity:SetTransient(false)
					add_child_entity(entity, parent_entity, owner, asset.name)
				end,
			}
		)
	end

	local function get_focus_bounds(entity)
		local min_x, min_y, min_z = math.huge, math.huge, math.huge
		local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
		local found = false

		local function add(visual)
			local aabb = visual:GetWorldAABB()

			if aabb and aabb.min_x <= aabb.max_x then
				found = true
				min_x, min_y, min_z = math.min(min_x, aabb.min_x), math.min(min_y, aabb.min_y), math.min(min_z, aabb.min_z)
				max_x, max_y, max_z = math.max(max_x, aabb.max_x), math.max(max_y, aabb.max_y), math.max(max_z, aabb.max_z)
			end
		end

		if entity.visual then add(entity.visual) end

		for _, child in ipairs(entity:GetChildrenList()) do
			if child.visual then add(child.visual) end
		end

		if found then
			local dx, dy, dz = max_x - min_x, max_y - min_y, max_z - min_z
			return Vec3((min_x + max_x) / 2, (min_y + max_y) / 2, (min_z + max_z) / 2),
			math.sqrt(dx * dx + dy * dy + dz * dz) / 2
		end

		if entity.transform then return entity.transform:GetWorldPosition(), 0 end
	end

	local function view_from_front(entity)
		local center, radius = get_focus_bounds(entity)

		if not center then return end

		camera.ViewFromFront(
			center,
			math.max(radius * 2.2, 2),
			entity.transform:GetWorldMatrix():GetRotation()
		)
	end

	local function go_to_entity(entity)
		local center, radius = get_focus_bounds(entity)

		if not center then return end

		camera.SetPosition(center - camera.GetRotation():GetForward() * math.max(radius * 2.2, 2))
	end

	local function can_edit_components(entity)
		return entity ~= Entity.World and entity ~= Panel.World and not entity:GetSingleton()
	end

	-- the entity that was cut, it stays where it is until it is pasted so it can be taken across prefab mode and the scene
	local cut_entity

	local function can_cut(entity)
		return can_edit_components(entity) and entity ~= edit_stack[#edit_stack]
	end

	local function can_paste(target)
		if not (cut_entity and cut_entity:IsValid()) then return false end

		if target == cut_entity or target:ContainsParent(cut_entity) then return false end

		local root = cut_entity:GetRoot()

		return target == root or target:GetRoot() == root
	end

	local function cut_to_clipboard(entity)
		cut_entity = entity
	end

	local function paste_into(target, owner)
		if not can_paste(target) then return end

		local entity = cut_entity
		local old_parent = entity:GetParent()
		cut_entity = nil

		if old_parent == target and not owner then return end

		local transform = entity.transform
		local keep_world = transform and not transform.Is2D and target.transform and transform.Attachment == "root"
		local world_position, world_rotation

		if keep_world then
			world_position = transform:GetWorldPosition()
			world_rotation = transform:GetWorldMatrix():GetRotation()
		end

		entity.prefab_patch = nil
		entity:SetParent(target)

		if owner then entity:SetOwnedBy(owner) end

		if keep_world then
			transform:SetPosition(transform:WorldToLocalPosition(world_position))
			transform:SetRotation(target.transform:GetWorldMatrix():GetRotation():GetConjugated() * world_rotation)
		end

		editor_history.RecordReparent(entity, old_parent, target)
		set_selected_target(entity)
	end

	local prefab_bar = NULL

	local function apply_prefab_mode()
		local editing = edit_stack[#edit_stack]
		prefab.SetEditing(editing and editing.prefab or nil)

		if editing then
			local names = {"scene"}

			for i, entity in ipairs(edit_stack) do
				names[i + 1] = entity.prefab.Path
			end

			prefab_bar:SetItems(names)
			tree_view:SetGroupByOwner(false)
			tree_view:SetRootLabels({[editing] = editing:GetName()})
			tree_view:SetRootEntities({editing})
		else
			prefab_bar:SetItems({})
			tree_view:SetGroupByOwner(true)
			tree_view:SetRootLabels({[Entity.World] = "3D World", [Panel.World] = "2D World"})
			tree_view:SetRootEntities({Entity.World, Panel.World})
		end

		tree_view:ExpandRoots()
	end

	function enter_prefab_edit(entity)
		edit_stack[#edit_stack + 1] = entity
		apply_prefab_mode()
		set_selected_target(entity)
	end

	function exit_prefab_edit()
		local left = table.remove(edit_stack)

		if not left then return end

		apply_prefab_mode()

		if left:IsValid() then set_selected_target(left) end
	end

	local size = props.Size or Vec2(400, 540)
	local world_size = Panel.World.transform:GetSize()

	if not props.Size then size = Vec2(400, world_size.y) end

	local position = props.Position or Vec2(0, 0)
	editor_window = Window{
		Key = props.Key or "GameEditorWindow",
		RequestMouse = props.RequestMouse,
		Title = "ENTITY EDITOR",
		Name = "entity editor",
		Size = size,
		Position = position,
		Padding = Rect(),
		MinSize = Vec2(320, 320),
		OnClose = function(self)
			if props.OnClose then
				props.OnClose(self, tree_view:GetSelectedEntityGUID())
			else
				self:Remove()
			end
		end,
	}{
		MenuBar{
			MenuKey = "EditorMenuBarContextMenu",
			Items = {
				{
					Text = "FILE",
					Items = function()
						return {
							MenuItem{
								Text = "asset browser",
								Icon = "folder",
								OnClick = function()
									local AssetBrowser = import("lua/asset_browser.lua")
									Panel.World:Ensure(AssetBrowser({Key = "AssetBrowserWindow"}))
								end,
							},
							MenuItem{
								Text = "save scene",
								Icon = "save",
								OnClick = function()
									name_prompt{
										Title = "SAVE SCENE",
										Text = last_scene_name or "scene",
										OnSubmit = function(name)
											name = name:gsub("[^%w_%-%. ]", "_")
											last_scene_name = name
											logn("saved ", scene.Save(name), " root entities to ", scene.GetPath(name))
										end,
									}
								end,
							},
							MenuItem{
								Text = "load scene",
								Icon = "folder_open",
								Items = function()
									local items = {}

									for _, file_name in ipairs(vfs.Find(scene.GetDirectory()) or {}) do
										local name = file_name:match("^(.+)%.scene$")

										if name then
											items[#items + 1] = MenuItem{
												Text = name,
												Icon = "file",
												OnClick = function()
													last_scene_name = name
													editor_history.Barrier("a scene was loaded")
													scene.LoadAsync(name)
												end,
											}
										end
									end

									return items
								end,
							},
						}
					end,
				},
				{
					Text = "EDIT",
					Items = function()
						local entries = history:GetEntries()
						local undo_entry = entries[history:GetIndex()]
						local redo_entry = entries[history:GetIndex() + 1]
						return {
							MenuItem{
								Text = undo_entry and ("Undo " .. undo_entry.Name) or "Undo",
								Icon = "undo",
								Disabled = not undo_entry,
								OnClick = function()
									history:Undo()
								end,
							},
							MenuItem{
								Text = redo_entry and ("Redo " .. redo_entry.Name) or "Redo",
								Icon = "redo",
								Disabled = not redo_entry,
								OnClick = function()
									history:Redo()
								end,
							},
							MenuSpacer{},
							MenuItem{
								Text = "History",
								Icon = "menu",
								OnClick = function()
									Panel.World:Ensure(HistoryPanel{Key = "EditorHistoryWindow"})
								end,
							},
							MenuItem{
								Text = "Clear history",
								Icon = "trash",
								Disabled = #entries == 0,
								OnClick = function()
									history:Clear()
								end,
							},
						}
					end,
				},
				{
					Text = "GIZMO",
					Items = function()
						local function add_gizmo_menu_item(icon, label, setter, value, current)
							if value == current then label = label .. " (active)" end

							return MenuItem{
								Text = label,
								Icon = icon,
								OnClick = function()
									setter(value)
								end,
							}
						end

						return {
							add_gizmo_menu_item("move", "Move", Gizmo.SetMode, "move", Gizmo.GetMode()),
							add_gizmo_menu_item("rotate", "Rotate", Gizmo.SetMode, "rotate", Gizmo.GetMode()),
							add_gizmo_menu_item("scale", "Scale", Gizmo.SetMode, "scale", Gizmo.GetMode()),
							add_gizmo_menu_item("transform", "Combined", Gizmo.SetMode, "combined", Gizmo.GetMode()),
							MenuSpacer{},
							add_gizmo_menu_item("cube", "Local Space", Gizmo.SetSpace, "local", Gizmo.GetSpace()),
							add_gizmo_menu_item("world", "World Space", Gizmo.SetSpace, "world", Gizmo.GetSpace()),
						}
					end,
				},
				{
					Text = "OPTIONS",
					Items = function()
						local viewport_label = "Scale 3D Viewport"
						return {
							MenuItem{
								Text = "Show transient entities" .. (show_transient and " (on)" or " (off)"),
								Icon = "eye",
								OnClick = function()
									set_show_transient(not show_transient)
								end,
							},
							MenuItem{
								Text = "Show nearby" .. (show_nearby and " (on)" or " (off)"),
								Icon = "target",
								OnClick = function()
									show_nearby = not show_nearby
									nearby_dirty = true
									tree_view:SetNearbyRoot(show_nearby and Entity.World or nil)
								end,
							},
						}
					end,
				},
			},
			layout = {
				GrowWidth = 1,
			},
		},
		Splitter{
			InitialSize = props.TreeHeight or math.floor(size.y * 0.45),
			MinSplitSize = 120,
			Vertical = true,
			Padding = Rect(),
			layout = {
				GrowWidth = 1,
				GrowHeight = 1,
			},
		}{
			Column{
				layout = {
					Direction = "y",
					GrowWidth = 1,
					GrowHeight = 1,
					FitHeight = false,
					ChildGap = 2,
					AlignmentX = "stretch",
				},
			}{
				TextEdit{
					Hint = "search: name, model:path, name:text",
					Size = Vec2(0, 28),
					MinSize = Vec2(100, 28),
					MaxSize = Vec2(0, 28),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnTextChanged = function(_, text)
						pending_search = text
						search_deadline = system.GetElapsedTime() + SEARCH_DEBOUNCE
					end,
					layout = {
						GrowWidth = 1,
					},
				},
				Breadcrumb{
					Ref = function(self)
						prefab_bar = self
					end,
					Icons = {scene = "world"},
					OnSelect = function(index)
						while #edit_stack >= index do
							exit_prefab_edit()
						end
					end,
				},
				ScrollablePanel{
					Ref = function(self)
						tree_scroll_container = self
					end,
					ScrollX = false,
					ScrollY = true,
					Padding = Rect(),
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					EntityTree{
						Ref = function(self)
							tree_view = self
						end,
						RootEntities = {Entity.World, Panel.World},
						RootLabels = {
							[Entity.World] = "3D World",
							[Panel.World] = "2D World",
						},
						SelectedKey = initial_selected_guid,
						ShowVirtualChildren = true,
						GroupByOwner = true,
						FilterCallback = function(entity)
							if entity_tree_filter_callback(entity, editor_window) then return true end

							local editing = edit_stack[#edit_stack]

							if editing then
								return entity ~= editing and entity.prefab_owner ~= editing.prefab
							end

							return entity.prefab_owner ~= nil or
								(
									not show_transient and
									entity ~= Entity.World and
									entity ~= Panel.World and
									entity:IsRuntime()
								)
						end,
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
						OnSelect = function(node, key)
							local target = node and (node.Entity or node.Object) or objects.GetObjectByGUID(key)
							Gizmo.EnableGizmo(target)
							prefab_tools.Watch(target)
							pending_selection_sync = true
							_G.SELECTED_OBJECT = target
						end,
						OnNodeHover = function(node, key, path, row_info, hovered)
							local entity = node and node.Entity or nil
							highlight.SetEntity(hovered and entity or nil)
						end,
						OnIsNodeDimmed = function(node)
							return cut_entity ~= nil and node.Entity == cut_entity
						end,
						OnNodeDoubleClick = function(node)
							local entity = node.Entity

							if entity and entity.prefab and entity.prefab.definition and entity ~= edit_stack[#edit_stack] then
								enter_prefab_edit(entity)
								return true
							end
						end,
						OnNodeContextMenu = function(node)
							if node.OwnerGroup then
								if node.Root ~= Entity.World then return false end

								Panel.OpenContextMenu(
									{
										OnClose = function(self)
											self:Remove()
										end,
									},
									{
										MenuItem{
											Text = "Entity",
											Icon = "cube",
											OnClick = function()
												create_child_entity(node.Root, node.Owner)
											end,
										},
										MenuItem{
											Text = "Prefab",
											Icon = "layers",
											OnClick = function()
												pick_child_prefab(node.Root, node.Owner)
											end,
										},
										can_paste(node.Root) and
										MenuItem{
											Text = "Paste " .. cut_entity:GetName(),
											Icon = "paste",
											OnClick = function()
												paste_into(node.Root, node.Owner)
											end,
										} or
										nil,
									}
								)
								return true
							end

							local entity = node.Entity

							if not entity then return false end

							local can_create_shapes = entity:GetRoot() == Entity.World
							local is_edit_root = entity == edit_stack[#edit_stack]
							local can_remove = can_edit_components(entity) and not is_edit_root

							if not can_create_shapes and not can_remove then return false end

							local has_above_remove = can_create_shapes
							Panel.OpenContextMenu(
								{
									OnClose = function(self)
										self:Remove()
									end,
								},
								{
									can_create_shapes and
									MenuItem{
										Text = "Go to",
										Icon = "target",
										OnClick = function()
											go_to_entity(entity)
										end,
									} or
									nil,
									can_create_shapes and
									MenuSpacer{} or
									nil,
									is_edit_root and
									MenuItem{
										Text = "Exit prefab",
										Icon = "arrow_left",
										OnClick = function()
											exit_prefab_edit()
										end,
									} or
									nil,
									not is_edit_root and
									entity.prefab and
									entity.prefab.definition and
									MenuItem{
										Text = "Edit prefab",
										Icon = "layers",
										OnClick = function()
											enter_prefab_edit(entity)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									MenuItem{
										Text = "Cut",
										Icon = "move",
										OnClick = function()
											cut_to_clipboard(entity)
										end,
									} or
									nil,
									can_create_shapes and
									can_paste(entity) and
									MenuItem{
										Text = "Paste " .. cut_entity:GetName(),
										Icon = "paste",
										OnClick = function()
											paste_into(entity)
										end,
									} or
									nil,
									can_create_shapes and
									MenuItem{
										Text = "Entity",
										Icon = "cube",
										OnClick = function()
											create_child_entity(entity)
										end,
									} or
									nil,
									can_create_shapes and
									MenuItem{
										Text = "Prefab",
										Icon = "layers",
										OnClick = function()
											pick_child_prefab(entity)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									not scene.IsTransientEntity(entity) and
									MenuItem{
										Text = "Clone",
										Icon = "copy",
										OnClick = function()
											local clone = scene.Clone(entity)
											editor_history.RecordCreate("clone " .. entity:GetName(), clone)
											set_selected_target(clone)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									network.IsConnected() and
									MenuItem{
										Text = "Send to server",
										Icon = "upload",
										OnClick = function()
											scene_sync.Push(entity)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									network.IsConnected() and
									MenuItem{
										Text = "Remove on server",
										Icon = "trash",
										OnClick = function()
											scene_sync.RemoveOnServer(entity)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									prefab_tools.GetMenuItem(entity, set_selected_target) or
									nil,
									can_remove and
									has_above_remove and
									MenuSpacer{} or
									nil,
									can_remove and
									MenuItem{
										Text = "Remove",
										Icon = "trash",
										OnClick = function()
											local parent = entity:GetParent()

											if parent:IsValid() then set_selected_target(parent) end

											if entity:GetRoot() == Entity.World then
												editor_history.RemoveEntity(entity)
											else
												entity:Remove()
												prefab.MarkStructureDirty(parent)
												editor_history.Barrier("a 2D panel was removed")
											end
										end,
									} or
									nil,
								}
							)
							return true
						end,
					},
				},
			},
			ScrollablePanel{
				Ref = function(self)
					property_scroll_container = self
				end,
				ScrollX = false,
				ScrollY = true,
				Padding = "none",
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
				},
			}{
				Panel.New{
					Name = "PropertyEditorFrame",
					transform = true,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						MinSize = Vec2(size.x - 24, 0),
						Padding = Rect(2, 2, 2, 2),
					},
				}{
					PropertyEditor{
						Ref = function(self)
							property_editor = self
						end,
						OnPropertyEdited = editor_history.RecordProperty,
						CategoryOrder = COMPONENT_ORDER,
						OnContextActions = prefab_tools.GetPropertyActions,
						OnCategoryContextMenu = function(_, name, entity)
							if not entity.component_list or not can_edit_components(entity) then return end

							return {
								MenuItem{
									Text = "Remove",
									Icon = "trash",
									OnClick = function()
										editor_history.RemoveComponent(entity, name)
									end,
								},
							}
						end,
						OnGetCategoryBadge = prefab_tools.GetCategoryBadge,
						OnGetPropertyBadge = prefab_tools.GetPropertyBadge,
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							FitWidth = false,
							MinSize = Vec2(size.x - 28, 0),
						},
					},
				},
			},
		},
	}
	local picker_button = IconButton{
		Name = "PickerButton",
		Icon = "target",
		Size = Vec2(28, 28),
		Padding = "XXS",
		Mode = "outline",
		Tooltip = "pick an entity in the scene",
		layout = {
			Floating = true,
		},
		OnClick = function(self)
			if picker.IsActive() then
				if picker_cancel_fn then
					picker_cancel_fn()
					picker_cancel_fn = nil
				end
			else
				self.mouse_input:SetCursorOverride("crosshair")
				picker_cancel_fn = picker.Start{
					mode = "entity",
					on_pick = function(target)
						set_selected_target(target)
					end,
					on_stop = function()
						self.mouse_input:ClearCursorOverride()
						picker_cancel_fn = nil
					end,
				}
			end

			return true
		end,
		OnUpdate = function(self)
			self:SetActive(picker.IsActive())

			if tree_scroll_container:IsValid() then
				local _, _, x, y = tree_scroll_container.transform:GetWorldRectFast()
				local btn_size = self.transform:GetSize()
				self.transform:SetPosition(
					self:GetParent().transform:GlobalToLocal(Vec2(x - btn_size.x - 4, y - btn_size.y))
				)
			end
		end,
	}
	picker_button:AddGlobalEvent("Update")
	editor_window:AddChild(picker_button)
	local add_component_button = IconButton{
		Name = "AddComponentButton",
		Icon = "plus",
		Size = Vec2(28, 28),
		Padding = "XXS",
		Mode = "outline",
		Tooltip = "add a component to the selected entity",
		layout = {
			Floating = true,
		},
		OnClick = function()
			local entity = tree_view:GetSelectedEntity()

			if not entity or not can_edit_components(entity) then return true end

			Panel.World:Ensure(
				AssetBrowser{
					Key = "AssetPicker",
					PickerCategory = "components",
					ComponentTarget = entity,
					OnPick = function(asset)
						editor_history.AddComponent(entity, asset.name)
					end,
				}
			)
			return true
		end,
		OnUpdate = function(self)
			if property_scroll_container:IsValid() then
				local _, _, x2, y2 = property_scroll_container.transform:GetWorldRectFast()
				local btn_size = self.transform:GetSize()
				self.transform:SetPosition(
					self:GetParent().transform:GlobalToLocal(Vec2(x2 - btn_size.x - 16, y2 - btn_size.y - 8))
				)
			end
		end,
	}
	add_component_button:AddGlobalEvent("Update")
	editor_window:AddChild(add_component_button)
	editor_window:AddGlobalEvent("Update")

	local function is_ui_hovering()
		local hovered = MouseInput.GetHoveredObject()
		return hovered:IsValid() and hovered ~= Panel.World
	end

	local function has_text_focus()
		local focused = objects:GetFocusedObject()
		return focused:IsValid() and
			editor_window:ContainsParent(focused) and
			(
				focused.text ~= nil or
				focused.Name == "TextEdit"
			)
	end

	local view = View.New{Priority = 10}:Activate()
	local playing_selection

	-- the editor hides and the player gets the controls back, the camera stays the editor camera
	function editor_window:SetPlaying(playing)
		if self.playing == playing then return end

		self.playing = playing

		if playing then
			if picker_cancel_fn then
				picker_cancel_fn()
				picker_cancel_fn = nil
			end

			playing_selection = tree_view:GetSelectedEntity()
			Gizmo.EnableGizmo(nil)
		elseif playing_selection and playing_selection:IsValid() then
			Gizmo.EnableGizmo(playing_selection)
		end

		self.visual:SetVisible(not playing)
		event.Call("EditorControlsChanged", playing)
	end

	function editor_window:IsPlaying()
		return self.playing == true
	end

	event.AddListener("KeyInput", editor_window, function(key, press)
		if press and key == "e" and input.IsControlDown() then
			editor_window:SetPlaying(not editor_window.playing)
			return true
		end
	end)

	editor_window:CallOnRemove(function()
		event.RemoveListener("KeyInput", editor_window)
		event.Call("EditorControlsChanged", false)
	end)

	function editor_window:OnUpdate(dt)
		if edit_stack[1] then
			local count = #edit_stack

			while edit_stack[1] and not edit_stack[#edit_stack]:IsValid() do
				edit_stack[#edit_stack] = nil
			end

			if #edit_stack ~= count then apply_prefab_mode() end
		end

		do
			camera.SetBlockMovement(has_text_focus() or self.playing)
			local gizmo_status = Gizmo.GetStatus()
			camera.SetBlockDragging(
				self.playing or
					is_ui_hovering() or
					gizmo_status.active_drag or
					gizmo_status.hovered_handle or
					brush_editor.IsBusy()
			)
			camera.Update(dt)
			view:SetPosition(camera.GetPosition():Copy())
			view:SetRotation(camera.GetRotation():Copy())
		end

		do
			local position = camera.GetPosition()

			if not last_camera_position or (position - last_camera_position):GetLength() > 0.001 then
				last_camera_position = position:Copy()
				camera_moved_time = system.GetElapsedTime()
				nearby_dirty = true
			elseif
				show_nearby and
				nearby_dirty and
				system.GetElapsedTime() - camera_moved_time >= NEARBY_SETTLE_TIME
			then
				nearby_dirty = false
				tree_view:SetNearby(nearby.Collect(position, NEARBY_COUNT))
			end

			if pending_search and system.GetElapsedTime() >= search_deadline then
				local text = pending_search
				pending_search = nil
				tree_view:SetSearch(text)
			end
		end

		if pending_selection_sync then
			pending_selection_sync = false
			local selected_target = tree_view:GetSelectedEntity()

			if selected_target then
				editor_ui_mutation_blocked = editor_ui_mutation_blocked + 1
				tree_view:BlockMutations()
				property_editor:SetObject(selected_target)
				property_editor:ExpandAll()
				tree_view:UnblockMutations()
				editor_ui_mutation_blocked = math.max(0, editor_ui_mutation_blocked - 1)
			end
		end
	end

	event.AddListener("EditorSelect", editor_window, function(target)
		set_selected_target(target)
	end)

	-- not when a value was edited, rebuilding the panel then would drop the control that is being dragged
	event.AddListener("PrefabInputsChanged", editor_window, function()
		pending_selection_sync = true
	end)

	event.AddListener("EntityTreeReparent", editor_window, function(entity, old_parent, new_parent)
		editor_history.RecordReparent(entity, old_parent, new_parent)
	end)

	event.AddListener("WindowKeyInput", editor_window, function(_, key, press)
		if not press or not input.IsControlDown() or has_text_focus() then return end

		if Gizmo.GetStatus().active_drag then return end

		if key == "x" then
			local entity = tree_view:GetSelectedEntity()

			if entity and entity:GetRoot() == Entity.World and can_cut(entity) then
				cut_to_clipboard(entity)
				return true
			end
		end

		if key == "v" then
			local entity = tree_view:GetSelectedEntity()

			if entity and can_paste(entity) then
				paste_into(entity)
				return true
			end
		end

		if key == "z" and not input.IsShiftDown() then
			history:Undo()
			return true
		end

		if key == "y" or key == "z" and input.IsShiftDown() then
			history:Redo()
			return true
		end
	end)

	editor_window:CallOnRemove(
		function()
			event.RemoveListener("EditorSelect", editor_window)
			event.RemoveListener("EntityTreeReparent", editor_window)
			event.RemoveListener("WindowKeyInput", editor_window)
			event.RemoveListener("PrefabInputsChanged", editor_window)
			highlight.SetEntity()
			prefab_tools.Watch(nil)
			prefab.SetEditing(nil)
			Gizmo.Clear()
			view:Remove()
			render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
		end,
		"editor_gizmo_cleanup"
	)

	do
		local function add_component_listener(world)
			local remove_listener = world:AddLocalListener("OnEntityComponentChanged", function(_, entity, _, name)
				local selected_entity = tree_view:GetSelectedEntity()

				if selected_entity and entity == selected_entity then
					pending_selection_sync = true
					prefab_tools.Watch(selected_entity)
				end

				if name == "prefab" or name == "script" then tree_view:Refresh() end
			end)
			editor_window:CallOnRemove(remove_listener, remove_listener)
		end

		add_component_listener(Entity.World)
		add_component_listener(Panel.World)
	end

	function editor_window:GetSelectedEntityGUID()
		return tree_view:GetSelectedEntityGUID()
	end

	do
		camera.SetPosition(render3d.GetCamera():GetPosition():Copy())
		camera.SetRotation(render3d.GetCamera():GetRotation():Copy())
		Gizmo.SetMode(props.GizmoMode or Gizmo.GetMode())
		Gizmo.SetSpace(props.GizmoSpace or Gizmo.GetSpace())
		pending_selection_sync = true

		tree_view:CollapseOwnerGroup(Entity.World, Entity.World)
		local player = _G.PLAYER_RIG
		local outfit = player and player:IsValid() and player.player_avatar.outfit

		if not initial_selected_guid then
			if outfit and outfit:IsValid() then
				set_selected_target(outfit)
			else
				local closest = nearby.Collect(camera.GetPosition(), 1)[1]

				if closest then set_selected_target(closest.entity) end
			end
		end

		local selected = tree_view:GetSelectedEntity()

		if selected and selected:IsValid() and selected.transform then view_from_front(selected) end
	end

	return editor_window
end
