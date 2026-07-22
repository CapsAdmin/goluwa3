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
local highlight = import("lua/highlight.lua")
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
local CameraComponent = import("lua/components/camera.lua")
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

	local parent = entity:GetRoot(1) or NULL -- one off from Panel.World
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

	local function set_selected_target(target)
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
						return {
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
						highlight.SetEntity(hovered and entity or nil)
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
						Entity = tree_view:GetSelectedEntity(),
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
	-- Create picker button, positioned at bottom-right of tree view
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

				if picker.IsActive() then
					-- Cancel picker
					if picker_cancel_fn then
						picker_cancel_fn()
						picker_cancel_fn = nil
					end
				else
					-- Start picker
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

	function editor_window:OnUpdate(dt)
		do
			camera.SetBlockMovement(has_text_focus())
			local gizmo_status = Gizmo.GetStatus()
			camera.SetBlockDragging(is_ui_hovering() or gizmo_status.active_drag or gizmo_status.hovered_handle)
			camera.Update(dt)
			render3d.GetCamera():SetPosition(camera.GetPosition():Copy())
			render3d.GetCamera():SetRotation(camera.GetRotation():Copy())
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

	editor_window:CallOnRemove(
		function()
			highlight.SetEntity()
			Gizmo.Clear(editor_window)
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
		tree_view:Refresh(true)
		pending_selection_sync = true
	end

	return editor_window
end
