local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local input = import("goluwa/input.lua")
local raycast = GRAPHICS_3D and import("goluwa/physics/raycast.lua")
local Quat = import("goluwa/structs/quat.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Gizmo = import("lua/gizmo.lua")
local Highlight = import("lua/highlight.lua")
local shapes = _G.GRAPHICS_3D and import("lua/shapes.lua") or {}
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local EntityTree = import("goluwa/render2d/ui/widgets/entity_tree.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local AssetBrowser = import("lua/asset_browser.lua")
local property_builder = import("addons/editor/lua/property_builder.lua")
local CameraComponent = import("lua/components/camera.lua")
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

	local parent = entity:GetRoot(1) or NULL -- one off from Panel.World
	if parent:IsValid() and is_hidden(parent, editor_window) then return true end

	return false
end

local function has_text_focus(editor_window)
	local focused = objects:GetFocusedObject()
	return focused:IsValid() and
		editor_window:ContainsParent(focused) and
		(
			focused.text ~= nil or
			focused.Name == "TextEdit"
		)
end

return function(props)
	props = props or {}
	local initial_selected_guid = props.SelectedEntityGUID
	local tree_view = NULL
	local tree_scroll_container = NULL
	local property_editor = NULL
	local editor_window = NULL
	local selected_property_listener_removers = {}
	local property_change_sync_blocked = 0
	local pending_selection_sync = false
	local sync_debounce_time = props.SyncDebounceTime or 0.1
	local editor_ui_mutation_blocked = 0
	local editor_camera = import("lua/editor_camera.lua")
	editor_camera.Initialize()
	local editor_world_picking = import("lua/editor_world_picking.lua")
	local click_drag_threshold_sq = 16
	local picker_2d_active = false
	local picker_2d_cursor_override = nil
	local picker_2d_last_button_down = false
	local picker_2d_scroll_to_guid = nil
	local property_node_hooks = {
		OnPropertyChangeStart = function()
			property_change_sync_blocked = property_change_sync_blocked + 1
		end,
		OnPropertyChangeEnd = function()
			property_change_sync_blocked = math.max(0, property_change_sync_blocked - 1)
		end,
	}

	local function set_selected_target(target)
		Gizmo.EnableGizmo(target)
		tree_view:SelectEntity(target)
		pending_selection_sync = true
	end

	local function flush_pending_editor_sync(force) end

	local function create_child_shape(parent_entity, kind)
		local camera_forward = editor_camera.GetForward()
		local spawn_world_position = editor_camera.GetPosition() + camera_forward * 2
		local config = {
			Name = kind == "sphere" and "sphere" or "box",
			Collision = false,
			RigidBody = false,
			PhysicsNoCollision = true,
			Position = spawn_world_position,
			Material = {
				Color = kind == "sphere" and
					{r = 0.28, g = 0.65, b = 0.92, a = 1} or
					{r = 0.9, g = 0.62, b = 0.24, a = 1},
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
		tree_view:ExpandToEntity(entity)
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
									Panel.World:Ensure(AssetBrowser({Key = "AssetBrowserWindow"}))
								end,
							},
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
							MenuSpacer(),
							add_gizmo_menu_item("Local Space", Gizmo.SetSpace, "local", Gizmo.GetSpace()),
							add_gizmo_menu_item("World Space", Gizmo.SetSpace, "world", Gizmo.GetSpace()),
						}
					end,
				},
				{
					Text = "OPTIONS",
					Items = function()
						local viewport_label = "Scale 3D Viewport"

						if editor_camera.GetScaleViewport() then
							viewport_label = viewport_label .. " (active)"
						end

						return {
							MenuItem{
								Text = viewport_label,
								OnClick = function()
									editor_camera.SetScaleViewport(not editor_camera.GetScaleViewport())
								end,
							},
							MenuSpacer(),
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

												if props.OnThemeChange then
													props.OnThemeChange(
														tree_view:GetSelectedEntityGUID(),
														editor_window.transform:GetPosition():Copy(),
														editor_window.transform:GetSize():Copy()
													)
												end
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
			ScrollablePanel{
				Ref = function(self)
					tree_scroll_container = self
				end,
				ScrollX = false,
				ScrollY = true,
				Padding = Rect(),
				ScrollBarContentShiftMode = "auto_shift",
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
						return entity_tree_filter_callback(entity, editor_window)
					end,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
					},
					OnSelect = function(node, key)
						local target = node and (node.Entity or node.Object) or objects.GetObjectByGUID(key)
						set_selected_target(target)
					end,
					OnNodeHover = function(node, key, path, row_info, hovered)
						local entity = node and node.Entity or nil

						if hovered then
							Highlight.EnableHighlight(entity)
						else
							Highlight.EnableHighlight(nil)
						end
					end,
					OnNodeContextMenu = function(node)
						local entity = node and node.Entity or nil
						local can_create_shapes = entity:GetRoot() == Entity.World
						local can_remove = entity ~= Entity.World and entity ~= Panel.World

						if not can_create_shapes and not can_remove then return false end

						Panel.OpenContextMenu(
							{
								OnClose = function(self)
									self:Remove()
								end,
							},
							{
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
								can_create_shapes and
								can_remove and
								MenuSpacer() or
								nil,
								can_remove and
								MenuItem{
									Text = "Remove",
									OnClick = function()
										local parent = entity:GetParent()

										if parent:IsValid() then
											set_selected_target(parent)
											tree_view:ExpandToEntity(entity)
										end

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
			ScrollablePanel{
				ScrollX = false,
				ScrollY = true,
				Padding = "none",
				ScrollBarContentShiftMode = "auto_shift",
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
					gui_element = {
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
						OnPropertyChangeStart = property_node_hooks.OnPropertyChangeStart,
						OnPropertyChangeEnd = property_node_hooks.OnPropertyChangeEnd,
						Items = property_builder.build_property_items(tree_view:GetSelectedEntity(), property_node_hooks),
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
	-- Create 2D picker button, positioned at bottom-right of tree view
	local picker_button = Panel.New{
		Name = "Picker2DButton",
		transform = {
			Size = Vec2(28, 28),
			Position = Vec2(0, 0),
		},
		gui_element = {
			OnDraw = function(self)
				local btn_size = self.Owner.transform:GetSize()
				render2d.SetTexture(nil)

				if picker_2d_active then
					render2d.SetColor(1.0, 0.35, 0.15, 0.9)
				else
					render2d.SetColor(0.5, 0.5, 0.55, 0.7)
				end

				render2d.DrawRect(0, 0, btn_size.x, btn_size.y)
				render2d.SetColor(1, 1, 1, 1)
				-- crosshair icon
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

				picker_2d_active = not picker_2d_active

				if picker_2d_active then
					self:SetCursorOverride("crosshair")
					picker_2d_cursor_override = self

					input.HijackKeyInput(function(key)
						if key == "escape" then
							picker_2d_active = false
							return true
						end
					end)
				else
					self:ClearCursorOverride()
					picker_2d_cursor_override = nil
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

	do
		local function is_ui_hovering()
			local hovered = MouseInput.GetHoveredObject()
			return hovered:IsValid() and hovered ~= Panel.World
		end

		local function mouse_in_editor_viewport(mouse_pos)
			if not editor_camera.GetScaleViewport() then
				return not editor_window.transform:GetRect():IsPosInside(mouse_pos)
			end

			return editor_camera.IsInsideViewport(mouse_pos)
		end

		local world_click = {
			button_down = false,
			allow_pick = false,
			dragged = false,
			start_mouse_pos = nil,
		}

		local function update_world_click_selection()
			local mouse_pos = system.GetWindow():GetMousePosition()
			local gizmo_status = Gizmo.GetStatus()
			local inside_world = mouse_in_editor_viewport(mouse_pos) and
				not editor_window.transform:GetRect():IsPosInside(mouse_pos)
			local selection_allowed = inside_world and
				not has_text_focus(editor_window)
				and
				not is_ui_hovering()
				and
				not gizmo_status.active_drag and
				not gizmo_status.hovered_handle
			local button_down = input.IsMouseDown("button_1")

			if button_down and not world_click.button_down then
				world_click.button_down = true
				world_click.allow_pick = selection_allowed
				world_click.dragged = false
				world_click.start_mouse_pos = mouse_pos:Copy()
				return
			end

			if button_down and world_click.button_down then
				if world_click.allow_pick and world_click.start_mouse_pos then
					local dx = mouse_pos.x - world_click.start_mouse_pos.x
					local dy = mouse_pos.y - world_click.start_mouse_pos.y

					if dx * dx + dy * dy > click_drag_threshold_sq then
						world_click.dragged = true
					end
				end

				return
			end

			if not button_down and world_click.button_down then
				local should_pick = world_click.allow_pick and not world_click.dragged and selection_allowed
				world_click.button_down = false
				world_click.allow_pick = false
				world_click.dragged = false
				world_click.start_mouse_pos = nil

				if not should_pick then return end

				local camera = CameraComponent.GetActiveCameraComponent()
				local target = editor_world_picking.find_world_pick_target(editor_window, camera and camera.Owner)

				if target and target:IsValid() then set_selected_target(target) end
			end
		end

		local function update_picker_2d()
			if not picker_2d_active then
				if picker_2d_cursor_override then
					picker_2d_cursor_override:ClearCursorOverride()
					picker_2d_cursor_override = nil
				end

				return
			end

			local hovered = MouseInput.GetHoveredObject()

			if
				not hovered:IsValid() or
				editor_window:ContainsParent(hovered) or
				hovered == picker_button
			then
				Highlight.EnableHighlight(nil)
				return
			end

			Highlight.EnableHighlight(hovered)

			if input.IsMouseDown("button_1") and not picker_2d_last_button_down then
				-- Expand parent path before refresh so the entity appears in the tree
				local expanded_keys = tree_view:GetExpandedKeys()
				local parent = hovered:GetParent()

				while parent and parent:IsValid() and parent ~= Panel.World and parent ~= Entity.World do
					expanded_keys[parent:GetGUID()] = true
					parent = parent:GetParent()
				end

				tree_view:Refresh(true)
				set_selected_target(hovered)
				picker_2d_scroll_to_guid = hovered:GetGUID()
				picker_2d_active = false
			end

			picker_2d_last_button_down = input.IsMouseDown("button_1")
		end

		local function clear_selected_property_listeners()
			for i = 1, #selected_property_listener_removers do
				selected_property_listener_removers[i]()
			end

			list.clear(selected_property_listener_removers)
		end

		function editor_window:OnUpdate(dt)
			-- Deferred scroll to picked entity
			if picker_2d_scroll_to_guid then
				tree_view:EnsureVisible(picker_2d_scroll_to_guid, Rect(0, 12, 0, 12))
				picker_2d_scroll_to_guid = nil
			end

			if not has_text_focus(editor_window) then
				local mouse_pos = system.GetWindow():GetMousePosition()
				editor_camera.Update(
					dt,
					{
						world_size = Panel.World.transform:GetSize(),
						window_rect = editor_window.transform:GetRect(),
						block_movement = has_text_focus(editor_window) or
							is_ui_hovering() or
							not mouse_in_editor_viewport(mouse_pos),
						mouse_in_viewport = mouse_in_editor_viewport,
					}
				)
			end

			do
				local excluded_entity = CameraComponent.GetActiveCameraComponent() and
					CameraComponent.GetActiveCameraComponent().Owner or
					nil
				local selected_entity = tree_view:GetSelectedEntity()

				for _, entity in ipairs(Entity.World:GetChildrenList()) do
					if
						editor_world_picking.is_nonvisual_pick_candidate(entity, editor_window, excluded_entity)
					then
						local world_pos = entity.transform:GetWorldPosition()

						if render3d.GetCamera():WorldPositionToScreen(world_pos) then
							local is_selected = entity == selected_entity
							debug_draw.DrawSphere{
								id = "editor_nonvisual_hint_" .. entity:GetGUID(),
								position = world_pos,
								radius = is_selected and 0.1 or 0.06,
								color = is_selected and {0.45, 1.0, 0.45, 0.35} or {0.8, 0.9, 1.0, 0.16},
								ignore_z = true,
								time = NONVISUAL_HINT_TIME,
							}
						end
					end
				end
			end

			update_world_click_selection()
			update_picker_2d()

			if pending_selection_sync then
				pending_selection_sync = false
				local selected_target = tree_view:GetSelectedEntity()

				if selected_target then
					clear_selected_property_listeners()

					if property_builder.is_valid_object(selected_target) then
						for _, category in ipairs(property_builder.enumerate_property_categories(selected_target)) do
							selected_property_listener_removers[#selected_property_listener_removers + 1] = category.object:AddPropertyListener(function(_, key)
								if property_change_sync_blocked > 0 then return end

								property_editor:RefreshValueForKey(category.key .. "/" .. key)

								if property_name == "Name" or property_name == "Key" or property_name == "Material" then
									pending_selection_sync = true
								end
							end)
						end
					end

					tree_view:ExpandToEntity(selected_target)
					editor_ui_mutation_blocked = editor_ui_mutation_blocked + 1
					tree_view:BlockMutations()
					property_editor:SetItems(property_builder.build_property_items(selected_target, property_node_hooks))
					property_editor:ExpandAll()
					tree_view:UnblockMutations()
					editor_ui_mutation_blocked = math.max(0, editor_ui_mutation_blocked - 1)
				end
			end
		end

		editor_window:CallOnRemove(
			function()
				clear_selected_property_listeners()
				Highlight.Clear()
				Gizmo.Clear(editor_window)
				render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
			end,
			"editor_gizmo_cleanup"
		)
	end

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
		do
			local camera = render3d.GetCamera()
			editor_camera.SetPosition(camera:GetPosition():Copy())
			editor_camera.SetRotation(camera:GetRotation():Copy())
			local forward = editor_camera.GetForward()
			editor_camera.SetPitch(math.asin(math.clamp(forward.y, -1, 1)))
			editor_camera.SetVelocity(Vec3())
		end

		Gizmo.SetMode(props.GizmoMode or Gizmo.GetMode())
		Gizmo.SetSpace(props.GizmoSpace or Gizmo.GetSpace())
		tree_view:Refresh(true)
		pending_selection_sync = true
	end

	return editor_window
end
