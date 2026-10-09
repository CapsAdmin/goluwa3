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
local shapes = RENDER_3D and import("goluwa/render3d/shapes.lua") or {}
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
local network = import("goluwa/network/network.lua")
local scene_sync = import("goluwa/network/scene_sync.lua")
local name_prompt = import("lua/name_prompt.lua")
local vfs = import("goluwa/vfs.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local View = import("goluwa/render3d/view.lua")
local camera = import("lua/camera.lua")
local picker = import("lua/picker.lua")
local MATERIAL_ROOT_KEY = "__editor_3d_materials__"
local SHARED_INSTANCE_COLOR = Color(0.35, 0.62, 1.0, 1.0)
local SHARED_INSTANCE_OUTLINE = Color(0.35, 0.62, 1.0, 0.95)
local NONVISUAL_HINT_TIME = 0.12

local function is_hidden(entity, editor_window)
	if entity == editor_window then return true end

	if entity.Type == "panel_context_menu" then return true end

	if entity:GetName() == "TooltipOverlay" then return true end

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

	local function set_selected_target(target)
		if not show_transient and target:GetTransient() then set_show_transient(true) end

		Gizmo.EnableGizmo(target)
		tree_view:SelectEntity(target)
		tree_view:ExpandToEntity(target)
		tree_view:EnsureEntityVisible(target)
		pending_selection_sync = true
	end

	local function flush_pending_editor_sync(force) end

	local function create_child_shape(parent_entity, kind)
		local spawn_world_position = camera.GetPosition() + camera.GetRotation():GetForward() * 2
		local config = {
			Name = kind == "sphere" and "sphere" or "box",
			Collision = false,
			RigidBody = false,
			PhysicsNoCollision = true,
			Position = spawn_world_position,
			Material = {
				Color = kind == "sphere" and Color(0.28, 0.65, 0.92, 1) or Color(0.9, 0.62, 0.24, 1),
			},
		}
		local entity = kind == "sphere" and shapes.Sphere(config) or shapes.Box(config)

		if entity:HasComponent("rigid_body") then
			entity:RemoveComponent("rigid_body")
		end

		entity:SetParent(parent_entity)

		if parent_entity.transform then
			entity.transform:SetPosition(parent_entity.transform:GetWorldMatrixInverse():TransformVector(spawn_world_position))
		end

		set_selected_target(entity)
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

	local function go_to_entity(entity)
		local center, radius = get_focus_bounds(entity)

		if not center then return end

		camera.SetPosition(center - camera.GetRotation():GetForward() * math.max(radius * 2.2, 2))
	end

	local function component_label(name)
		local s = name:gsub("_", " ")
		return s:sub(1, 1):upper() .. s:sub(2)
	end

	local function component_names(entity, present)
		local names = {}

		for name in pairs(entity:GetValidComponents()) do
			if entity:HasComponent(name) == present then names[#names + 1] = name end
		end

		table.sort(names)
		return names
	end

	local function build_component_items(entity, names, present)
		local items = {}

		for _, name in ipairs(names) do
			items[#items + 1] = MenuItem{
				Text = component_label(name),
				OnClick = function()
					if present then
						entity:RemoveComponent(name)
					else
						entity:AddComponent(name)
					end
				end,
			}
		end

		return items
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
								Text = "ui gallery",
								OnClick = function()
									local Gallery = import("addons/ui_gallery/lua/gallery_browser.lua")
									Panel.World:Ensure(Gallery({Key = "GalleryWindow"}))
								end,
							},
							MenuItem{
								Text = "asset browser",
								OnClick = function()
									local AssetBrowser = import("lua/asset_browser.lua")
									Panel.World:Ensure(AssetBrowser({Key = "AssetBrowserWindow"}))
								end,
							},
							MenuItem{
								Text = "save scene",
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
								Items = function()
									local items = {}

									for _, file_name in ipairs(vfs.Find(scene.GetDirectory()) or {}) do
										local name = file_name:match("^(.+)%.luadata$")

										if name then
											items[#items + 1] = MenuItem{
												Text = name,
												OnClick = function()
													last_scene_name = name
													scene.LoadAsync(name)
												end,
											}
										end
									end

									return items
								end,
							},
							MenuSpacer{},
							MenuItem{
								Text = "exit",
								OnClick = function()
									system.ShutDown(0)
								end,
							},
						}
					end,
				},
				{
					Text = "GIZMO",
					Items = function()
						local function add_gizmo_menu_item(label, setter, value, current)
							if value == current then label = label .. " (active)" end

							return MenuItem{
								Text = label,
								OnClick = function()
									setter(value)
								end,
							}
						end

						return {
							add_gizmo_menu_item("Move", Gizmo.SetMode, "move", Gizmo.GetMode()),
							add_gizmo_menu_item("Rotate", Gizmo.SetMode, "rotate", Gizmo.GetMode()),
							add_gizmo_menu_item("Scale", Gizmo.SetMode, "scale", Gizmo.GetMode()),
							add_gizmo_menu_item("Combined", Gizmo.SetMode, "combined", Gizmo.GetMode()),
							MenuSpacer{},
							add_gizmo_menu_item("Local Space", Gizmo.SetSpace, "local", Gizmo.GetSpace()),
							add_gizmo_menu_item("World Space", Gizmo.SetSpace, "world", Gizmo.GetSpace()),
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
								OnClick = function()
									set_show_transient(not show_transient)
								end,
							},
							MenuItem{
								Text = "Show nearby" .. (show_nearby and " (on)" or " (off)"),
								OnClick = function()
									show_nearby = not show_nearby
									nearby_dirty = true
									tree_view:SetNearbyRoot(show_nearby and Entity.World or nil)
								end,
							},
							MenuItem{
								Text = "Theme",
								Items = function()
									local items = {}

									for _, label in ipairs(theme.GetAvailable()) do
										if label == theme.active:GetName() then label = label .. " (active)" end

										items[#items + 1] = MenuItem{
											Text = label,
											OnClick = function()
												if label == theme.active:GetName() then return end

												theme.LoadTheme(label)
											end,
										}
									end

									return items
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
						SharedInstanceColor = SHARED_INSTANCE_COLOR,
						ShowVirtualChildren = true,
						FilterCallback = function(entity)
							return entity_tree_filter_callback(entity, editor_window) or
								(
									not show_transient and
									entity ~= Entity.World and
									entity ~= Panel.World and
									entity:GetTransient()
								)
						end,
						layout = {
							GrowWidth = 1,
							FitHeight = true,
						},
						OnSelect = function(node, key)
							local target = node and (node.Entity or node.Object) or objects.GetObjectByGUID(key)
							Gizmo.EnableGizmo(target)
							pending_selection_sync = true
							_G.SELECTED_OBJECT = target
						end,
						OnNodeHover = function(node, key, path, row_info, hovered)
							local entity = node and node.Entity or nil
							highlight.SetEntity(hovered and entity or nil)
						end,
						OnNodeContextMenu = function(node)
							local entity = node.Entity

							if not entity then return false end

							local can_create_shapes = entity:GetRoot() == Entity.World
							local can_remove = entity ~= Entity.World and
								entity ~= Panel.World and
								not entity:GetSingleton()

							if not can_create_shapes and not can_remove then return false end

							local add_names
							local remove_names

							if can_remove then
								add_names = component_names(entity, false)
								remove_names = component_names(entity, true)
							end

							local has_above_remove = can_create_shapes or (can_remove and (#add_names > 0 or #remove_names > 0))
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
										OnClick = function()
											go_to_entity(entity)
										end,
									} or
									nil,
									can_create_shapes and
									MenuSpacer{} or
									nil,
									can_create_shapes and
									MenuItem{
										Text = "Sphere",
										OnClick = function()
											create_child_shape(entity, "sphere")
										end,
									} or
									nil,
									can_create_shapes and
									MenuItem{
										Text = "Box",
										OnClick = function()
											create_child_shape(entity, "box")
										end,
									} or
									nil,
									can_remove and
									#add_names > 0 and
									MenuItem{
										Text = "Add Component",
										Items = function()
											return build_component_items(entity, add_names, false)
										end,
									} or
									nil,
									can_remove and
									#remove_names > 0 and
									MenuItem{
										Text = "Remove Component",
										Items = function()
											return build_component_items(entity, remove_names, true)
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									MenuItem{
										Text = "Clone",
										OnClick = function()
											set_selected_target(scene.Clone(entity))
										end,
									} or
									nil,
									can_create_shapes and
									can_remove and
									network.IsConnected() and
									MenuItem{
										Text = "Send to server",
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
										OnClick = function()
											scene_sync.RemoveOnServer(entity)
										end,
									} or
									nil,
									can_remove and
									has_above_remove and
									MenuSpacer{} or
									nil,
									can_remove and
									MenuItem{
										Text = "Remove",
										OnClick = function()
											local parent = entity:GetParent()

											if parent:IsValid() then set_selected_target(parent) end

											entity:Remove()
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
					visual = {
						OnDraw = function(self)
							if tree_view:IsValid() then
								local selected_node = tree_view:GetSelectedNode()

								if selected_node and not selected_node.SharedInstance then return end
							end

							local panel_size = self.Owner.transform:GetSize()
							render2d.SetTexture(nil)
							render2d.SetColor(SHARED_INSTANCE_OUTLINE:Unpack())
							render2d.DrawRect(0, 0, math.max(1, panel_size.x), 2)
							render2d.DrawRect(0, math.max(0, panel_size.y - 2), math.max(1, panel_size.x), 2)
							render2d.DrawRect(0, 0, 2, math.max(1, panel_size.y))
							render2d.DrawRect(math.max(0, panel_size.x - 2), 0, 2, math.max(1, panel_size.y))
						end,
					},
				}{
					PropertyEditor{
						Ref = function(self)
							property_editor = self
						end,
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
	local picker_button = Panel.New{
		Name = "PickerButton",
		transform = {
			Size = Vec2(28, 28),
			Position = Vec2(0, 0),
		},
		visual = {
			OnDraw = function(self)
				local btn_size = self.Owner.transform:GetSize()
				render2d.SetTexture(nil)

				if picker.IsActive() then
					render2d.SetColor(1.0, 0.35, 0.15, 0.9)
				else
					render2d.SetColor(0.5, 0.5, 0.55, 0.7)
				end

				render2d.DrawRect(0, 0, btn_size.x, btn_size.y)
				render2d.SetColor(1, 1, 1, 1)
				local cx, cy = btn_size.x / 2, btn_size.y / 2
				render2d.DrawRect(cx - 1, cy - 6, 2, 5)
				render2d.DrawRect(cx - 1, cy + 1, 2, 5)
				render2d.DrawRect(cx - 6, cy - 1, 5, 2)
				render2d.DrawRect(cx + 1, cy - 1, 5, 2)
			end,
		},
		mouse_input = {
			Cursor = "hand",
			OnMouseInput = function(self, button, press)
				if button ~= "button_1" or not press then return end

				if picker.IsActive() then
					if picker_cancel_fn then
						picker_cancel_fn()
						picker_cancel_fn = nil
					end
				else
					self:SetCursorOverride("crosshair")
					picker_cancel_fn = picker.StartEntityPicker{
						on_pick = function(target)
							set_selected_target(target)
						end,
						on_cancel = function()
							self:ClearCursorOverride()
							picker_cancel_fn = nil
						end,
					}
				end
			end,
		},
		layout = {
			Floating = true,
		},
		OnUpdate = function(self)
			if tree_scroll_container:IsValid() then
				local _, _, x, y = tree_scroll_container.transform:GetWorldRectFast()
				local btn_size = self.transform:GetSize()
				self.transform:SetPosition(Vec2(x - btn_size.x - 4, y - btn_size.y * 2 - 4))
			end
		end,
	}
	picker_button:AddGlobalEvent("Update")
	editor_window:AddChild(picker_button)
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

	function editor_window:OnUpdate(dt)
		do
			camera.SetBlockMovement(has_text_focus())
			local gizmo_status = Gizmo.GetStatus()
			camera.SetBlockDragging(
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

	editor_window:CallOnRemove(
		function()
			event.RemoveListener("EditorSelect", editor_window)
			highlight.SetEntity()
			Gizmo.Clear()
			view:Remove()
			render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
		end,
		"editor_gizmo_cleanup"
	)

	do
		local function add_component_listener(world)
			local remove_listener = world:AddLocalListener("OnEntityComponentChanged", function(_, entity)
				local selected_entity = tree_view:GetSelectedEntity()

				if selected_entity and entity == selected_entity then
					pending_selection_sync = true
				end
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

		if not initial_selected_guid then
			local closest = nearby.Collect(camera.GetPosition(), 1)[1]

			if closest then set_selected_target(closest.entity) end
		end
	end

	return editor_window
end
