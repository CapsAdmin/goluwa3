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
local ContextMenu = import("goluwa/render2d/ui/elements/context_menu.lua")
local MenuBar = import("goluwa/render2d/ui/widgets/menu_bar.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local MenuSpacer = import("goluwa/render2d/ui/elements/menu_spacer.lua")
local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
local ScrollablePanel = import("goluwa/render2d/ui/elements/scrollable_panel.lua")
local Splitter = import("goluwa/render2d/ui/elements/splitter.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local Tree = import("goluwa/render2d/ui/widgets/tree.lua")
local Window = import("goluwa/render2d/ui/widgets/window.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local AssetBrowser = import("lua/asset_browser.lua")
local Material = import("goluwa/render3d/material.lua")
local tree_builder = import("addons/editor/lua/tree_builder.lua")
local property_builder = import("addons/editor/lua/property_builder.lua")
local MATERIAL_ROOT_KEY = tree_builder.MATERIAL_ROOT_KEY
local SHARED_INSTANCE_COLOR = tree_builder.SHARED_INSTANCE_COLOR
local SHARED_INSTANCE_OUTLINE = Color(0.35, 0.62, 1.0, 0.95)
local NONVISUAL_HINT_TIME = 0.12

local function has_text_focus(window)
	local focused = objects:GetFocusedObject()

	if not focused:IsValid() then return false end

	if not window:ContainsParent(focused) then return false end

	return focused.text ~= nil or focused.Name == "TextEdit"
end

local function is_ui_hovering()
	local hovered = MouseInput.GetHoveredObject()
	return hovered:IsValid() and hovered ~= Panel.World
end

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function update_editor_camera_rotation(camera_state, mouse_delta)
	if mouse_delta.x == 0 and mouse_delta.y == 0 then return end

	local rotation = camera_state.rotation:Copy()
	local scaled_delta = mouse_delta * camera_state.mouse_sensitivity
	local new_pitch = math.clamp(camera_state.pitch + scaled_delta.y, camera_state.min_pitch, camera_state.max_pitch)
	local pitch_delta = new_pitch - camera_state.pitch
	local yaw_quat = Quat():Identity()
	yaw_quat:RotateYaw(-scaled_delta.x)
	rotation = (yaw_quat * rotation):GetNormalized()
	rotation:RotatePitch(-pitch_delta)
	camera_state.rotation = rotation
	camera_state.pitch = new_pitch
end

local function update_editor_camera_position(camera_state, dt)
	if camera_state.block_movement then
		camera_state.velocity = approach_vec(camera_state.velocity, Vec3(), camera_state.acceleration * dt)
		camera_state.position = camera_state.position + camera_state.velocity * dt
		return
	end

	local move_local = Vec3()

	if input.IsKeyDown("w") then move_local.z = move_local.z + 1 end

	if input.IsKeyDown("s") then move_local.z = move_local.z - 1 end

	if input.IsKeyDown("a") then move_local.x = move_local.x - 1 end

	if input.IsKeyDown("d") then move_local.x = move_local.x + 1 end

	if input.IsKeyDown("space") then move_local.y = move_local.y + 1 end

	if input.IsKeyDown("q") then move_local.y = move_local.y - 1 end

	local move = Vec3()

	if move_local:GetLength() > 0.0001 then
		move_local = move_local:GetNormalized()
		move = camera_state.rotation:GetForward() * move_local.z + camera_state.rotation:GetRight() * move_local.x + camera_state.rotation:GetUp() * move_local.y

		if move:GetLength() > 0.0001 then move = move:GetNormalized() end
	end

	local speed = camera_state.speed

	if input.IsKeyDown("left_control") or input.IsKeyDown("right_control") then
		speed = speed * camera_state.slow_multiplier
	end

	if input.IsKeyDown("left_shift") then
		speed = speed * camera_state.sprint_multiplier
	end

	camera_state.velocity = approach_vec(camera_state.velocity, move * speed, camera_state.acceleration * dt)
	camera_state.position = camera_state.position + camera_state.velocity * dt
end

local function is_editor_control_rig_entity(entity)
	if not (entity and entity.IsValid and entity:IsValid()) then return false end

	if entity.HasComponent then
		if
			entity:HasComponent("player_input") or
			entity:HasComponent("player_movement") or
			entity:HasComponent("player_physgun")
		then
			return true
		end
	end

	local key = entity:GetKey()
	local name = entity:GetName()
	return key == "player_camera_rig" or name == "player_camera_rig"
end

local function has_editor_control_rig_ancestor(entity)
	local current = entity

	while current and current.IsValid and current:IsValid() do
		if is_editor_control_rig_entity(current) then return true end

		current = current:GetParent()
	end

	return false
end

local function is_editor_pick_excluded_entity(entity, excluded_entity)
	if not (entity and entity.IsValid and entity:IsValid()) then return true end

	if has_editor_control_rig_ancestor(entity) then return true end

	local world = Entity.World
	local player_camera_rig = world and world.GetKeyed and world:GetKeyed("player_camera_rig") or nil

	if player_camera_rig and player_camera_rig.IsValid and player_camera_rig:IsValid() then
		if entity == player_camera_rig or player_camera_rig:ContainsParent(entity) then
			return true
		end
	end

	if excluded_entity and excluded_entity.IsValid and excluded_entity:IsValid() then
		if entity == excluded_entity or excluded_entity:ContainsParent(entity) then
			return true
		end
	end

	return false
end

local function get_first_spawned_entity(editor_window)
	for _, world in ipairs{Entity.World, Panel.World} do
		for _, child in ipairs(world:GetChildren()) do
			if
				child and
				child:IsValid() and
				not tree_builder.is_hidden_editor_entity(child, editor_window)
			then
				return child
			end
		end
	end

	return nil
end

local function has_visual_pick_target(entity)
	local visual = entity and entity.visual or nil

	if not visual then return false end

	local entries = visual:GetRenderEntries()
	return entries and entries[1] ~= nil or false
end

local function is_visual_pick_helper_entity(entity)
	return entity and (entity.visual_primitive ~= nil or entity.VisualOwner ~= nil) or false
end

local function is_nonvisual_pick_candidate(entity, editor_window, excluded_entity)
	if tree_builder.is_hidden_editor_entity(entity, editor_window) then
		return false
	end

	if is_editor_pick_excluded_entity(entity, excluded_entity) then return false end

	if has_visual_pick_target(entity) or is_visual_pick_helper_entity(entity) then
		return false
	end

	return entity.transform ~= nil
end

local function draw_nonvisual_entity_hints(editor_window, excluded_entity, selected_entity)
	local cam = render3d.GetCamera()

	if not cam then return end

	local viewport = cam:GetViewport()
	local screen_width = viewport and viewport.w or nil
	local screen_height = viewport and viewport.h or nil

	for _, entity in ipairs(Entity.World:GetChildrenList()) do
		if not is_nonvisual_pick_candidate(entity, editor_window, excluded_entity) then
			goto continue
		end

		local _, visibility = cam:WorldPositionToScreen(entity.transform:GetWorldPosition(), screen_width, screen_height)

		if visibility ~= -1 then goto continue end

		local is_selected = entity == selected_entity
		debug_draw.DrawSphere{
			id = "editor_nonvisual_hint_" .. entity:GetGUID(),
			position = world_pos,
			radius = is_selected and 0.1 or 0.06,
			color = is_selected and {0.45, 1.0, 0.45, 0.35} or {0.8, 0.9, 1.0, 0.16},
			ignore_z = true,
			time = NONVISUAL_HINT_TIME,
		}

		::continue::
	end
end

local function find_nonvisual_entity_hit(
	editor_window,
	mouse_pos,
	ray_origin,
	ray_direction,
	max_distance,
	excluded_entity
)
	local cam = render3d.GetCamera()

	if not (cam and mouse_pos and ray_origin and ray_direction) then return nil end

	local best_hit = nil
	local best_distance = max_distance or math.huge
	local marker_radius = 12
	local marker_radius_sq = marker_radius * marker_radius

	for _, entity in ipairs(Entity.World:GetChildrenList()) do
		if not is_nonvisual_pick_candidate(entity, editor_window, excluded_entity) then
			goto continue2
		end

		local world_pos = entity.transform:GetWorldPosition()
		local screen_pos, visibility = cam:WorldPositionToScreen(world_pos, render2d.GetSize())

		if visibility ~= -1 or not screen_pos then goto continue2 end

		local dx = screen_pos.x - mouse_pos.x
		local dy = screen_pos.y - mouse_pos.y
		local screen_distance_sq = dx * dx + dy * dy

		if screen_distance_sq > marker_radius_sq then goto continue2 end

		local to_entity = world_pos - ray_origin
		local ray_distance = to_entity:Dot(ray_direction)

		if ray_distance <= 0 or ray_distance > best_distance then goto continue2 end

		if
			not best_hit or
			ray_distance < best_hit.distance or
			(
				ray_distance == best_hit.distance and
				screen_distance_sq < best_hit.screen_distance_sq
			)
		then
			best_hit = {
				entity = entity,
				distance = ray_distance,
				position = world_pos:Copy(),
				screen_distance_sq = screen_distance_sq,
			}
			best_distance = ray_distance
		end

		::continue2::
	end

	return best_hit
end

local function find_world_pick_target(editor_window, excluded_entity)
	if not raycast then return nil end

	local input_window = system.GetWindow()

	if not input_window then return nil end

	local cam = render3d.GetCamera()

	if not cam then return nil end

	local mouse_pos = input_window:GetMousePosition()

	if not mouse_pos then return nil end

	local screen_width, screen_height = render2d.GetSize()
	local ray_origin = cam:GetPosition()
	local ray_direction = cam:ScreenToWorldDirection(mouse_pos, screen_width, screen_height)

	if not (ray_origin and ray_direction and mouse_pos) then return nil end

	local visual_hit = raycast.CastClosest(
		ray_origin,
		ray_direction,
		math.huge,
		function(entity)
			return entity:IsValid() and
				tree_builder.get_entity_world_root(entity) == Entity.World and
				not tree_builder.is_hidden_editor_entity(entity, editor_window)
				and
				not is_editor_pick_excluded_entity(entity, excluded_entity)
		end
	)
	local fallback_hit = find_nonvisual_entity_hit(
		editor_window,
		mouse_pos,
		ray_origin,
		ray_direction,
		math.huge,
		excluded_entity
	)

	if fallback_hit then return fallback_hit.entity end

	if visual_hit then return visual_hit.entity end

	return nil
end

local function get_entity_by_guid(guid)
	if not guid or guid == "" then return nil end

	local entity = objects.GetObjectByGUID(guid)

	if entity and entity:IsValid() then return entity end

	return nil
end

local function get_drop_parent(drop_info, source_entity)
	if not drop_info then return nil end

	if drop_info.position == "inside" then
		return drop_info.target_node and drop_info.target_node.Entity or nil
	end

	if drop_info.parent_node and drop_info.parent_node.Entity then
		return drop_info.parent_node.Entity
	end

	return tree_builder.get_entity_world_root(source_entity) or Entity.World
end

local function count_valid_children(entity, editor_window)
	local count = 0

	for _, child in ipairs(tree_builder.get_valid_children(entity, editor_window)) do
		if child and child:IsValid() then count = count + 1 end
	end

	return count
end

local open_material_picker
local open_texture_picker
return function(props)
	props = props or {}
	local state = {
		selected_entity = nil,
		selected_object = nil,
		selected_entity_guid = props.SelectedEntityGUID,
		expanded_entities = {
			[Entity.World:GetGUID()] = true,
			[MATERIAL_ROOT_KEY] = true,
			[Panel.World:GetGUID()] = true,
		},
		tree_items = {},
	}
	local tree_view
	local tree_panel
	local property_editor
	local property_editor_frame
	local footer_text
	local window
	local selected_property_listener_removers = {}
	local property_change_sync_blocked = 0
	local refresh_property_editor
	local update_footer
	local refresh_property_key
	local set_selected_target
	local reveal_selected_tree_item
	local sync_tree_items
	local sync_selection
	local request_editor_sync
	local flush_pending_editor_sync
	local flush_pending_tree_branch_refreshes
	local pending_tree_sync = false
	local pending_tree_branch_keys = {}
	local pending_selection_sync = false
	local pending_sync_deadline = 0
	local sync_debounce_time = props.SyncDebounceTime or 0.1
	local editor_ui_mutation_blocked = 0
	local tracked_material_count = tree_builder.count_material_objects()
	local world_click = {
		button_down = false,
		allow_pick = false,
		dragged = false,
		start_mouse_pos = nil,
	}
	local editor_camera = {
		enabled = true,
		scale_viewport = false,
		position = nil,
		rotation = nil,
		pitch = 0,
		velocity = Vec3(),
		viewport_rect = Rect(0, 0, 1, 1),
		mouse_sensitivity = 0.0075,
		min_pitch = -math.pi / 2 + 0.01,
		max_pitch = math.pi / 2 - 0.01,
		speed = 18,
		sprint_multiplier = 2.25,
		acceleration = 220,
		slow_multiplier = 0.2,
		dragging = false,
		block_movement = false,
	}
	local active_camera_component = nil
	local active_camera_was_active = false
	local click_drag_threshold_sq = 16

	local function run_editor_ui_mutation(callback, reason)
		editor_ui_mutation_blocked = editor_ui_mutation_blocked + 1
		local ok, result_a, result_b, result_c = pcall(callback)
		editor_ui_mutation_blocked = math.max(0, editor_ui_mutation_blocked - 1)

		if not ok then error(result_a, 0) end

		return result_a, result_b, result_c
	end

	local function get_active_camera_component()
		local function walk(entity)
			if
				entity and
				entity:IsValid() and
				entity.camera and
				entity.camera.GetActive and
				entity.camera:GetActive()
			then
				return entity.camera
			end

			for _, child in ipairs(entity:GetChildren()) do
				local found = walk(child)

				if found then return found end
			end
		end

		return walk(Entity.World)
	end

	local function sync_editor_camera_from_render_camera()
		local camera = render3d.GetCamera()
		editor_camera.position = camera:GetPosition():Copy()
		editor_camera.rotation = camera:GetRotation():Copy()
		local forward = editor_camera.rotation:GetForward()
		editor_camera.pitch = math.asin(math.clamp(forward.y, -1, 1))
		editor_camera.velocity = Vec3()
	end

	local function update_editor_camera_viewport()
		local camera = render3d.GetCamera()
		local world_size = Panel.World.transform:GetSize()
		local viewport_rect = Rect(0, 0, world_size.x, world_size.y)

		if editor_camera.scale_viewport then
			local window_rect = window.transform:GetRect()
			local clamped_x = math.clamp(window_rect.x, 0, world_size.x)
			local clamped_y = math.clamp(window_rect.y, 0, world_size.y)
			local clamped_w = math.max(0, math.min(window_rect.w, world_size.x - clamped_x))
			local clamped_h = math.max(0, math.min(window_rect.h, world_size.y - clamped_y))

			if clamped_x <= 0 and clamped_w > 0 then
				viewport_rect.x = math.clamp(clamped_x + clamped_w, 0, world_size.x)
				viewport_rect.w = math.max(1, world_size.x - viewport_rect.x)
			end
		end

		editor_camera.viewport_rect = viewport_rect
		camera:SetViewport(viewport_rect)
	end

	local function restore_editor_camera_viewport()
		render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
	end

	local function mouse_in_editor_viewport(mouse_pos)
		if not editor_camera.scale_viewport then
			return not window.transform:GetRect():IsPosInside(mouse_pos)
		end

		return editor_camera.viewport_rect:IsPosInside(mouse_pos)
	end

	local function context_menu_blocks_world(mouse_pos)
		local menu = Panel.World:GetKeyed("EditorMenuBarContextMenu") or
			Panel.World:GetKeyed("EditorTreeContextMenu")

		if not (menu and menu.IsValid and menu:IsValid()) then return false end

		return Rect(mouse_pos.x, mouse_pos.y, 1, 1):Intersects(menu.transform:GetRect())
	end

	local function apply_editor_camera()
		local camera = render3d.GetCamera()
		camera:SetPosition(editor_camera.position)
		camera:SetRotation(editor_camera.rotation)
	end

	local function update_editor_camera(dt)
		if not editor_camera.enabled then return end

		update_editor_camera_viewport()
		local mouse_pos = system.GetWindow():GetMousePosition()
		local focus_blocks_movement = has_text_focus(window)
		local world_blocked = context_menu_blocks_world(mouse_pos)
		local ui_blocks_movement = is_ui_hovering()
		local gizmo_status = Gizmo.GetStatus()
		local can_drag = mouse_in_editor_viewport(mouse_pos) and
			not focus_blocks_movement and
			not window.transform:GetRect():IsPosInside(mouse_pos)
			and
			not world_blocked and
			not ui_blocks_movement
		local wants_drag = can_drag and input.IsMouseDown("button_1")

		if editor_camera.dragging then
			editor_camera.dragging = wants_drag and not gizmo_status.active_drag
		else
			editor_camera.dragging = wants_drag and
				not gizmo_status.active_drag and
				not gizmo_status.hovered_handle
		end

		editor_camera.block_movement = focus_blocks_movement or
			world_blocked or
			ui_blocks_movement or
			not mouse_in_editor_viewport(mouse_pos)

		if editor_camera.dragging then
			update_editor_camera_rotation(editor_camera, system.GetWindow():GetMouseDelta() / 2)
		end

		update_editor_camera_position(editor_camera, dt)
		apply_editor_camera()
	end

	local function update_world_click_selection()
		local input_window = system.GetWindow()

		if not input_window then return end

		local mouse_pos = input_window:GetMousePosition()
		local gizmo_status = Gizmo.GetStatus()
		local focus_blocks_selection = has_text_focus(window)
		local world_blocked = context_menu_blocks_world(mouse_pos)
		local ui_blocks_selection = is_ui_hovering()
		local inside_world = mouse_in_editor_viewport(mouse_pos) and
			not window.transform:GetRect():IsPosInside(mouse_pos)
		local selection_allowed = inside_world and
			not focus_blocks_selection and
			not world_blocked and
			not ui_blocks_selection and
			not gizmo_status.active_drag and
			not gizmo_status.hovered_handle
		local button_down = input.IsMouseDown("button_1")

		if button_down and not world_click.button_down then
			world_click.button_down = true
			world_click.allow_pick = selection_allowed
			world_click.dragged = false
			world_click.start_mouse_pos = mouse_pos and mouse_pos:Copy() or nil
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

			local excluded_entity = active_camera_component and active_camera_component.Owner or nil
			local target = find_world_pick_target(window, excluded_entity)

			if not (target and target.IsValid and target:IsValid()) then return end

			set_selected_target(target, true, target:GetGUID())
			sync_selection()
		end
	end

	local function close_active_context_menu()
		local active = Panel.World:GetKeyed("EditorTreeContextMenu")

		if active and active:IsValid() then active:Remove() end
	end

	local function set_hovered_entity(entity)
		Highlight.EnableHighlight(entity)
	end

	local picker_2d_active = false
	local picker_2d_cursor_override = nil
	local picker_2d_last_button_down = false
	local picker_2d_scroll_to_guid = nil

	local function update_picker_2d()
		if not picker_2d_active then
			if picker_2d_cursor_override then
				picker_2d_cursor_override:ClearCursorOverride()
				picker_2d_cursor_override = nil
			end

			return
		end

		if input.IsKeyDown("escape") then
			picker_2d_active = false
			set_hovered_entity(nil)
			return
		end

		local hovered = MouseInput.GetHoveredObject()

		if not (hovered and hovered.IsValid and hovered:IsValid()) then
			set_hovered_entity(nil)
			return
		end

		if window:ContainsParent(hovered) then
			set_hovered_entity(nil)
			return
		end

		set_hovered_entity(hovered)
		local button_down = input.IsMouseDown("button_1")

		if button_down and not picker_2d_last_button_down then
			set_selected_target(hovered, true, hovered:GetGUID())
			sync_tree_items()
			sync_selection()
			picker_2d_scroll_to_guid = hovered:GetGUID()
			picker_2d_active = false
		end

		picker_2d_last_button_down = button_down
	end

	local function get_selected_entity()
		if state.selected_entity and state.selected_entity:IsValid() then
			return state.selected_entity
		end

		state.selected_entity = get_entity_by_guid(state.selected_entity_guid)
		return state.selected_entity
	end

	local function get_selected_object()
		local selected_item = tree_builder.find_tree_item(state.tree_items, state.selected_entity_guid)

		if selected_item then
			return selected_item.Entity or selected_item.Object or nil
		end

		local entity = get_selected_entity()

		if entity then return entity end

		if property_builder.is_valid_object(state.selected_object) then
			return state.selected_object
		end

		state.selected_object = objects.GetObjectByGUID(state.selected_entity_guid)
		return property_builder.is_valid_object(state.selected_object) and
			state.selected_object or
			nil
	end

	local function is_selected_shared_instance()
		local selected_item = tree_builder.find_tree_item(state.tree_items, state.selected_entity_guid)
		return selected_item and selected_item.SharedInstance == true or false
	end

	local function clear_selected_property_listeners()
		for i = 1, #selected_property_listener_removers do
			selected_property_listener_removers[i]()
		end

		list.clear(selected_property_listener_removers)
	end

	local function refresh_selected_property_listeners()
		clear_selected_property_listeners()
		local target = get_selected_object()

		if not property_builder.is_valid_object(target) then return end

		if target.component_list then
			for _, component in ipairs(target.component_list or {}) do
				if component and component.IsValid and component:IsValid() then
					local component_name = property_builder.get_component_name(target, component)
					selected_property_listener_removers[#selected_property_listener_removers + 1] = component:AddPropertyListener(function(_, key)
						if property_change_sync_blocked > 0 then return end

						refresh_property_key(target:GetGUID() .. "/" .. component_name, key, target)
					end)
				end
			end

			return
		end

		selected_property_listener_removers[#selected_property_listener_removers + 1] = target:AddPropertyListener(function(_, key)
			if property_change_sync_blocked > 0 then return end

			refresh_property_key(target:GetGUID() .. "/properties", key, target)
		end)
	end

	local property_node_hooks = {
		OnPropertyChangeStart = function()
			property_change_sync_blocked = property_change_sync_blocked + 1
		end,
		OnPropertyChangeEnd = function()
			property_change_sync_blocked = math.max(0, property_change_sync_blocked - 1)
		end,
	}
	update_footer = function(selected, tree_items)
		if not footer_text or not footer_text:IsValid() then return end

		local gizmo_status_info = Gizmo.GetStatus()
		local gizmo_status = string.format("gizmo: %s/%s", gizmo_status_info.mode, gizmo_status_info.space)
		local root_3d_count = count_valid_children(Entity.World, window)
		local root_2d_count = count_valid_children(Panel.World, window)

		if gizmo_status_info.active_drag then
			gizmo_status = string.format(
				"%s [%s %s]",
				gizmo_status,
				gizmo_status_info.active_drag.kind,
				gizmo_status_info.active_drag.axis_id:upper()
			)
		end

		if not selected then
			footer_text.text:SetText(
				string.format(
					"3D roots: %d  |  2D roots: %d  |  %s",
					root_3d_count,
					root_2d_count,
					gizmo_status
				)
			)
			return
		end

		footer_text.text:SetText(
			string.format(
				"3D roots: %d  |  2D roots: %d  |  selected: %s  |  %s",
				root_3d_count,
				root_2d_count,
				selected.component_list and
					tree_builder.get_entity_label(selected) or
					tree_builder.get_object_label(selected),
				gizmo_status
			)
		)
	end

	local function ensure_expanded_path(entity)
		local current = entity and entity:GetParent() or nil

		while current and current:IsValid() and not tree_builder.is_world_root(current) do
			state.expanded_entities[current:GetGUID()] = true
			current = current:GetParent()
		end
	end

	set_selected_target = function(target, ensure_visible, selected_key)
		local entity = target and target.component_list and target or nil
		local object = property_builder.is_valid_object(target) and target or nil
		local previous_guid = state.selected_entity_guid
		state.selected_entity = entity
		state.selected_object = object and not entity and object or nil
		state.selected_entity_guid = selected_key or object and object:GetGUID() or nil
		Gizmo.EnableGizmo(entity)

		if ensure_visible and entity and state.selected_entity_guid ~= previous_guid then
			ensure_expanded_path(entity)
		end
	end

	local function should_defer_tree_refresh(branch_entity)
		local current = branch_entity

		while current and current.IsValid and current:IsValid() do
			if state.expanded_entities[current:GetGUID()] ~= true then return true end

			if tree_builder.is_world_root(current) then break end

			current = current:GetParent()
		end

		return false
	end

	local function resolve_selected_target(tree_items)
		local selected_item = tree_builder.find_tree_item(tree_items, state.selected_entity_guid)

		if selected_item then
			return selected_item.Entity or selected_item.Object, selected_item.Key
		end

		local current_selected = get_selected_object()

		if tree_builder.can_preserve_hidden_selection(current_selected, window) then
			return current_selected, state.selected_entity_guid
		end

		local fallback = get_first_spawned_entity(window)

		if fallback then return fallback, fallback:GetGUID() end

		local first = tree_items[1]
		return first and (first.Entity or first.Object) or nil,
		first and first.Key or nil
	end

	local function build_tree_branch_item(entity)
		if not (entity and entity.IsValid and entity:IsValid()) then return nil end

		if entity == Entity.World then
			return tree_builder.build_world_tree_item(Entity.World, "3D World", state.expanded_entities, {}, window)
		end

		if entity == Panel.World then
			return tree_builder.build_world_tree_item(Panel.World, "2D World", state.expanded_entities, {}, window)
		end

		return tree_builder.build_tree_snapshot(entity, state.expanded_entities, {}, window)
	end

	local function get_tree_branch_entity_by_guid(guid)
		if guid == Entity.World:GetGUID() then return Entity.World end

		if guid == Panel.World:GetGUID() then return Panel.World end

		if guid == MATERIAL_ROOT_KEY then return nil end

		return get_entity_by_guid(guid)
	end

	local function try_incremental_tree_insert(entity, parent)
		if not (tree_view and tree_view:IsValid() and entity and entity:IsValid()) then
			return false
		end

		if not (parent and parent:IsValid()) then return false end

		-- Parent must be in the tree and expanded
		local parent_item = tree_builder.find_tree_item(state.tree_items, parent:GetGUID())

		if not parent_item then return false end

		if not state.expanded_entities[parent:GetGUID()] then return false end

		-- Build the new tree item
		local new_item = tree_builder.build_tree_snapshot(entity, state.expanded_entities, {}, window)

		if not new_item then return false end

		-- Insert into tree data structure
		tree_builder.insert_tree_item(state.tree_items, parent:GetGUID(), new_item)
		-- Add to UI
		tree_view:AddNode(new_item, parent:GetGUID())
		return true
	end

	local function try_incremental_tree_remove(entity)
		if not (tree_view and tree_view:IsValid() and entity and entity:IsValid()) then
			return false
		end

		local guid = entity:GetGUID()
		-- Entity must be in the tree
		local item = tree_builder.find_tree_item(state.tree_items, guid)

		if not item then return false end

		-- Remove from tree data structure
		tree_builder.remove_tree_item(state.tree_items, guid)
		-- Remove from UI: find and remove all rows for this entity and its children
		local keys_to_remove = {}

		local function collect_keys(items)
			for _, i in ipairs(items or {}) do
				keys_to_remove[i.Key] = true
				collect_keys(i.Children)
			end
		end

		collect_keys(item.Children)
		keys_to_remove[guid] = true

		-- Remove rows in reverse order to maintain indices
		for i = #tree_view._row_order, 1, -1 do
			local row_key = tree_view._row_order[i]

			if keys_to_remove[row_key] then
				local info = tree_view._row_infos[row_key]

				if info and info.clip and info.clip:IsValid() then info.clip:Remove() end

				tree_view._row_infos[row_key] = nil
				table.remove(tree_view._row_order, i)
			end
		end

		tree_view:refresh_visibility()
		return true
	end

	local function try_incremental_tree_expand(entity)
		if not (tree_view and tree_view:IsValid() and entity and entity:IsValid()) then
			return false
		end

		local guid = entity:GetGUID()
		-- Entity must be in the tree
		local parent_item = tree_builder.find_tree_item(state.tree_items, guid)

		if not parent_item then return false end

		-- Get valid children
		local valid_children = tree_builder.get_valid_children(entity, window)

		if not valid_children[1] then return false end

		local visited = {}
		visited[entity] = true

		for _, child in ipairs(valid_children) do
			local new_item = tree_builder.build_tree_snapshot(child, state.expanded_entities, visited, window)

			if new_item then
				tree_builder.insert_tree_item(state.tree_items, guid, new_item)
				tree_view:AddNode(new_item, guid)
			end
		end

		-- Also handle virtual property children
		local virtual_children = tree_builder.build_virtual_property_children(entity)

		for _, child_node in ipairs(virtual_children) do
			tree_builder.insert_tree_item(state.tree_items, guid, child_node)
			tree_view:AddNode(child_node, guid)
		end

		visited[entity] = nil
		return true
	end

	local function refresh_tree_branch(entity)
		if not (tree_view and tree_view:IsValid() and entity and entity:IsValid()) then
			return sync_tree_items()
		end

		local replacement = build_tree_branch_item(entity)

		if not replacement then return sync_tree_items() end

		if
			not tree_builder.replace_tree_item(state.tree_items, entity:GetGUID(), replacement)
		then
			return sync_tree_items()
		end

		run_editor_ui_mutation(
			function()
				tree_view:RefreshBranchForKey(entity:GetGUID())
			end,
			"tree_refresh_branch"
		)

		return false
	end

	refresh_property_editor = function()
		if not property_editor or not property_editor:IsValid() then return end

		run_editor_ui_mutation(
			function()
				property_editor:SetItems(property_builder.build_property_items(get_selected_object(), property_node_hooks))
				property_editor:ExpandAll()
			end,
			"property_editor_set_items"
		)
	end
	refresh_property_key = function(row_prefix, property_name, target)
		if not property_editor or not property_editor:IsValid() then return end

		if not property_builder.is_valid_object(target) then return end

		local row_key = row_prefix .. "/" .. property_name

		if property_name == "Name" or property_name == "Key" or property_name == "Material" then
			property_editor:RefreshValueForKey(row_key)
			request_editor_sync(true, false, nil)
			update_footer(get_selected_object(), state.tree_items)
			return
		end

		local refreshed = property_editor:RefreshValueForKey(row_key)

		if refreshed then return end

		-- property not in the editor, ignore silently
		return
	end
	reveal_selected_tree_item = function()
		if not (tree_view and tree_view:IsValid()) then return end

		tree_view:ExpandToKey(state.selected_entity_guid)
		tree_view:SetSelectedKey(state.selected_entity_guid)
		tree_view:EnsureVisible(state.selected_entity_guid, Rect(0, 12, 0, 12))
	end
	sync_tree_items = function()
		if not tree_view or not tree_view:IsValid() then return end

		pending_tree_sync = false
		local previous_guid = state.selected_entity_guid
		local tree_items = tree_builder.build_tree_items(state.expanded_entities, window)
		local selected_target, selected_key = resolve_selected_target(tree_items)
		set_selected_target(selected_target, false, selected_key)
		state.tree_items = tree_items

		run_editor_ui_mutation(function()
			tree_view:SetItems(tree_items)
		end, "tree_set_items")

		reveal_selected_tree_item()
		update_footer(get_selected_object(), tree_items)
		return state.selected_entity_guid ~= previous_guid
	end
	flush_pending_tree_branch_refreshes = function()
		local branch_keys = {}

		for key in pairs(pending_tree_branch_keys) do
			branch_keys[#branch_keys + 1] = key
		end

		pending_tree_branch_keys = {}

		if branch_keys[1] == nil then return false end

		local selected_guid = state.selected_entity_guid

		for _, key in ipairs(branch_keys) do
			local entity = get_tree_branch_entity_by_guid(key)

			if not (entity and entity:IsValid()) then return sync_tree_items() end

			local selection_changed = refresh_tree_branch(entity)

			if selection_changed then return true end
		end

		if
			selected_guid ~= nil and
			not tree_builder.find_tree_item(state.tree_items, selected_guid)
			and
			not tree_builder.can_preserve_hidden_selection(get_selected_object(), window)
		then
			local selected_target, selected_key = resolve_selected_target(state.tree_items)
			set_selected_target(selected_target, false, selected_key)
			reveal_selected_tree_item()
			update_footer(get_selected_object(), state.tree_items)
			return state.selected_entity_guid ~= selected_guid
		end

		reveal_selected_tree_item()
		update_footer(get_selected_object(), state.tree_items)
		return false
	end
	request_editor_sync = function(tree_dirty, selection_dirty, branch_entity)
		if tree_dirty then
			if branch_entity and branch_entity.IsValid and branch_entity:IsValid() then
				pending_tree_branch_keys[branch_entity:GetGUID()] = true
			else
				pending_tree_sync = true
			end
		end

		if selection_dirty then pending_selection_sync = true end

		pending_sync_deadline = system.GetElapsedTime() + sync_debounce_time
	end
	flush_pending_editor_sync = function(force)
		if
			not pending_tree_sync and
			not next(pending_tree_branch_keys)
			and
			not pending_selection_sync
		then
			return
		end

		if not force and system.GetElapsedTime() < pending_sync_deadline then return end

		if pending_tree_sync then
			pending_tree_sync = false

			if sync_tree_items() then pending_selection_sync = true end
		elseif next(pending_tree_branch_keys) then
			if flush_pending_tree_branch_refreshes() then pending_selection_sync = true end
		end

		if pending_selection_sync then
			pending_selection_sync = false
			sync_selection()
		end
	end
	sync_selection = function()
		pending_selection_sync = false
		local selected_target, selected_key = resolve_selected_target(state.tree_items)
		set_selected_target(selected_target, false, selected_key)
		refresh_selected_property_listeners()
		reveal_selected_tree_item()
		refresh_property_editor()
		update_footer(get_selected_object(), state.tree_items)
	end

	local function open_gallery()
		local Gallery = import("addons/ui_gallery/lua/gallery_browser.lua")
		Panel.World:Ensure(Gallery({Key = "GalleryWindow"}))
	end

	local function open_asset_browser()
		Panel.World:Ensure(AssetBrowser({Key = "AssetBrowserWindow"}))
	end

	open_material_picker = function(node, target, info, key, path, panel, commit_value)
		Panel.World:Ensure(
			AssetBrowser{
				Key = "MaterialAssetPickerWindow",
				Title = "PICK MATERIAL",
				PickerCategory = "materials",
				Categories = {"materials"},
				SelectedKey = "materials",
				ShowGridByDefault = true,
				OnPickAsset = function(entry, material, browser_window)
					if not material then return false end

					commit_value(node, material, key, path, panel)

					if browser_window and browser_window.IsValid and browser_window:IsValid() then
						browser_window:Remove()
					end

					return true
				end,
			}
		)
	end
	open_texture_picker = function(node, target, info, key, path, panel, commit_value)
		Panel.World:Ensure(
			AssetBrowser{
				Key = "TextureAssetPickerWindow",
				Title = "PICK TEXTURE",
				PickerCategory = "textures",
				Categories = {"textures"},
				SelectedKey = "textures",
				ShowGridByDefault = true,
				OnPickAsset = function(entry, texture, browser_window)
					if not texture then return false end

					commit_value(node, texture, key, path, panel)

					if browser_window and browser_window.IsValid and browser_window:IsValid() then
						browser_window:Remove()
					end

					return true
				end,
			}
		)
	end

	local function create_child_shape(parent_entity, kind)
		if not parent_entity or not parent_entity:IsValid() then return end

		if tree_builder.get_entity_world_root(parent_entity) ~= Entity.World then
			return
		end

		local camera_forward = editor_camera.rotation and editor_camera.rotation:GetForward() or Vec3(0, 0, 1)
		local spawn_world_position = editor_camera.position and
			(
				editor_camera.position + camera_forward * 2
			)
			or
			Vec3(0, 0, 2)
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
		local entity

		if kind == "sphere" then
			entity = shapes.Sphere(config)
		else
			entity = shapes.Box(config)
		end

		if type(entity) == "table" and entity.IsValid and entity:IsValid() then
			if entity:HasComponent("rigid_body") then
				entity:RemoveComponent("rigid_body")
			end

			entity:SetParent(parent_entity)

			if parent_entity.transform then
				entity.transform:SetPosition(parent_entity.transform:GetWorldMatrixInverse():TransformVector(spawn_world_position))
			else
				entity.transform:SetPosition(spawn_world_position)
			end

			if parent_entity ~= Entity.World then
				state.expanded_entities[parent_entity:GetGUID()] = true
			end

			set_selected_target(entity, true, entity:GetGUID())
			sync_selection()
		end
	end

	local function remove_entity(entity)
		if not entity or not entity:IsValid() or tree_builder.is_world_root(entity) then
			return
		end

		local parent = entity:GetParent()

		if parent and parent:IsValid() then
			set_selected_target(parent, true, parent:GetGUID())
		else
			set_selected_target(nil, false, nil)
		end

		entity:Remove()
		sync_selection()
	end

	local function open_tree_context_menu(entity)
		if not entity or not entity:IsValid() then return false end

		local can_create_shapes = tree_builder.get_entity_world_root(entity) == Entity.World
		local can_remove = not tree_builder.is_world_root(entity)

		if not can_create_shapes and not can_remove then return false end

		close_active_context_menu()
		Panel.World:Ensure(
			ContextMenu{
				Key = "EditorTreeContextMenu",
				Position = system.GetWindow():GetMousePosition():Copy(),
				OnClose = function(self)
					self:Remove()
				end,
			}{
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
						remove_entity(entity)
					end,
				} or
				nil,
			}
		)
		return true
	end

	local function build_theme_menu_items()
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
							state.selected_entity_guid,
							window.transform:GetPosition():Copy(),
							window.transform:GetSize():Copy()
						)
					end
				end,
			}
		end

		return items
	end

	local function build_options_menu_items()
		local viewport_label = "Scale 3D Viewport"

		if editor_camera.scale_viewport then
			viewport_label = viewport_label .. " (active)"
		end

		return {
			MenuItem{
				Text = viewport_label,
				OnClick = function()
					editor_camera.scale_viewport = not editor_camera.scale_viewport
					update_editor_camera_viewport()
				end,
			},
			MenuSpacer(),
			MenuItem{
				Text = "Theme",
				Items = function()
					return build_theme_menu_items()
				end,
			},
		}
	end

	local function build_gizmo_menu_items()
		local items = {}

		local function add_mode_item(label, mode)
			if Gizmo.GetMode() == mode then label = label .. " (active)" end

			items[#items + 1] = MenuItem{
				Text = label,
				OnClick = function()
					Gizmo.SetMode(mode)
					update_footer(get_selected_object(), state.tree_items)
				end,
			}
		end

		local function add_space_item(label, space)
			if Gizmo.GetSpace() == space then label = label .. " (active)" end

			items[#items + 1] = MenuItem{
				Text = label,
				OnClick = function()
					Gizmo.SetSpace(space)
					update_footer(get_selected_object(), state.tree_items)
				end,
			}
		end

		add_mode_item("Move", "move")
		add_mode_item("Rotate", "rotate")
		add_mode_item("Scale", "scale")
		add_mode_item("Combined", "combined")
		items[#items + 1] = MenuSpacer()
		add_space_item("Local Space", "local")
		add_space_item("World Space", "world")
		return items
	end

	set_selected_target(get_selected_object(), true, state.selected_entity_guid)
	Gizmo.SetMode(props.GizmoMode or Gizmo.GetMode())
	Gizmo.SetSpace(props.GizmoSpace or Gizmo.GetSpace())

	if not get_selected_object() then
		local fallback = get_first_spawned_entity() or Entity.World
		set_selected_target(fallback, true, fallback:GetGUID())
	end

	state.tree_items = tree_builder.build_tree_items(state.expanded_entities)
	local size = props.Size or Vec2(400, 540)
	local world_size = Panel.World.transform:GetSize()

	if not props.Size then size = Vec2(400, world_size.y) end

	local position = props.Position or Vec2(0, 0)
	window = Window{
		Key = props.Key or "GameEditorWindow",
		RequestMouse = props.RequestMouse,
		Title = "ENTITY EDITOR",
		Size = size,
		Position = position,
		Padding = Rect(),
		MinSize = Vec2(320, 320),
		OnClose = function(self)
			close_active_context_menu()

			if props.OnClose then
				props.OnClose(self, state.selected_entity_guid)
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
							MenuItem{Text = "ui gallery", OnClick = open_gallery},
							MenuItem{Text = "asset browser", OnClick = open_asset_browser},
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
						return build_gizmo_menu_items()
					end,
				},
				{
					Text = "OPTIONS",
					Items = function()
						return build_options_menu_items()
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
					tree_panel = self
				end,
				Padding = "XXS",
				ScrollX = false,
				ScrollY = true,
				Padding = Rect(),
				ScrollBarContentShiftMode = "auto_shift",
				mouse_input = {
					OnMouseInput = function(self, button, press)
						if button ~= "button_2" or not press then return end

						return open_tree_context_menu(Entity.World)
					end,
				},
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
				},
			}{
				Tree{
					Ref = function(self)
						_G.EDITOR_VIEW = self
						tree_view = self
					end,
					Items = state.tree_items,
					SelectedKey = state.selected_entity_guid,
					SharedInstanceColor = SHARED_INSTANCE_COLOR,
					OnGetTextColor = function(node)
						return node and node.SharedInstance and SHARED_INSTANCE_COLOR or nil
					end,
					layout = {
						GrowWidth = 1,
						--GrowHeight = 1,
						FitHeight = true,
					},
					OnIsExpanded = function(node, path, key)
						return state.expanded_entities[key] == true
					end,
					OnSelect = function(node, key)
						local target = node and
							(
								node.Entity or
								node.Object
							)
							or
							get_entity_by_guid(key) or
							objects.GetObjectByGUID(key)
						set_selected_target(target, true, key)
						sync_selection()
					end,
					OnToggle = function(node, expanded, key)
						local was_expanded = state.expanded_entities[key] == true
						state.expanded_entities[key] = expanded == true

						if expanded ~= true or was_expanded then return end

						if not (node and node.HasChildren) then return end

						if key == MATERIAL_ROOT_KEY then
							request_editor_sync(true, false, nil)
							flush_pending_editor_sync(true)
							return
						end

						local branch_entity = node.Entity or get_tree_branch_entity_by_guid(key)

						if branch_entity and branch_entity:IsValid() then
							if not try_incremental_tree_expand(branch_entity) then
								request_editor_sync(true, false, branch_entity)
								flush_pending_editor_sync(true)
							end
						end
					end,
					OnNodeHover = function(node, key, path, row_info, hovered)
						local entity = node and node.Entity or nil

						if hovered then
							set_hovered_entity(entity)
						else
							set_hovered_entity(nil)
						end
					end,
					OnNodeContextMenu = function(node)
						return open_tree_context_menu(node and node.Entity or nil)
					end,
					OnCanDragNode = function(node)
						return node and node.Entity and not tree_builder.is_world_root(node.Entity)
					end,
					OnCanDropInside = function()
						return true
					end,
					OnDrop = function(drop_info)
						local source_entity = drop_info.source_node and drop_info.source_node.Entity or nil
						local next_parent = get_drop_parent(drop_info, source_entity)

						if
							not source_entity or
							not source_entity:IsValid()
							or
							tree_builder.is_world_root(source_entity)
						then
							return false
						end

						if not next_parent or not next_parent:IsValid() then
							next_parent = tree_builder.get_entity_world_root(source_entity) or Entity.World
						end

						if next_parent == source_entity then return false end

						if
							tree_builder.get_entity_world_root(source_entity) ~= tree_builder.get_entity_world_root(next_parent)
						then
							return false
						end

						if
							not tree_builder.is_world_root(next_parent) and
							next_parent:ContainsParent(source_entity)
						then
							return false
						end

						if source_entity:GetParent() == next_parent then return false end

						if not tree_builder.is_world_root(next_parent) then
							state.expanded_entities[next_parent:GetGUID()] = true
						end

						source_entity:SetParent(next_parent)
						return true
					end,
				},
			},
			ScrollablePanel{
				Padding = "XXS",
				ScrollX = false,
				ScrollY = true,
				Padding = Rect(),
				ScrollBarContentShiftMode = "auto_shift",
				layout = {
					GrowWidth = 1,
					GrowHeight = 1,
				},
			}{
				Panel.New{
					Ref = function(self)
						property_editor_frame = self
					end,
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
							if not is_selected_shared_instance() then return end

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
						Items = property_builder.build_property_items(get_selected_object(), property_node_hooks),
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
		Text{
			Ref = function(self)
				footer_text = self
				update_footer(get_selected_object(), state.tree_items)
			end,
			Text = "",
			Color = "text_disabled",
			FontSize = "XS",
			layout = {
				GrowWidth = 1,
				Padding = "XS",
				FitHeight = true,
			},
		},
	}
	active_camera_component = get_active_camera_component()
	active_camera_was_active = active_camera_component and active_camera_component:GetActive() or false

	if active_camera_component and active_camera_was_active then
		active_camera_component:SetActive(false)
	end

	sync_editor_camera_from_render_camera()
	update_editor_camera_viewport()
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
				else
					self:ClearCursorOverride()
					picker_2d_cursor_override = nil
					set_hovered_entity(nil)
				end
			end,
		},
		layout = {
			Floating = true,
		},
	}
	window:AddChild(picker_button)
	window:AddGlobalEvent("Update")

	function window:OnUpdate(dt)
		-- Position picker button at bottom-right of tree view
		if picker_button and picker_button:IsValid() and tree_panel and tree_panel:IsValid() then
			local _, _, x, y = tree_panel.transform:GetWorldRectFast()
			local btn_size = picker_button.transform:GetSize()
			picker_button.transform:SetPosition(Vec2(x - btn_size.x - 4, y - btn_size.y * 2 - 4))
		end

		-- Deferred scroll to picked entity
		if picker_2d_scroll_to_guid then
			tree_view:EnsureVisible(picker_2d_scroll_to_guid, Rect(0, 12, 0, 12))
			picker_2d_scroll_to_guid = nil
		end

		update_editor_camera(dt)
		draw_nonvisual_entity_hints(
			window,
			active_camera_component and active_camera_component.Owner or nil,
			get_selected_entity()
		)
		update_world_click_selection()
		update_picker_2d()
		local material_count = tree_builder.count_material_objects()

		if material_count ~= tracked_material_count then
			tracked_material_count = material_count
			request_editor_sync(true, false, nil)
		end

		flush_pending_editor_sync(false)
	end

	Gizmo.SetStateChangedCallback(window, function(status)
		update_footer(get_selected_object(), state.tree_items)
	end)

	window:CallOnRemove(
		function()
			clear_selected_property_listeners()
			Highlight.Clear()
			Gizmo.Clear(window)
			restore_editor_camera_viewport()

			if
				active_camera_component and
				active_camera_component.IsValid and
				active_camera_component:IsValid()
			then
				active_camera_component:SetActive(active_camera_was_active)
			end
		end,
		"editor_gizmo_cleanup"
	)

	do
		local function add_world_listeners(world)
			local remove_hierarchy_listener = world:AddLocalListener("OnEntityHierarchyChanged", function(_, entity, action, parent)
				if editor_ui_mutation_blocked > 0 then return end

				if tree_builder.should_ignore_editor_tree_change(entity, parent, window) then
					return
				end

				-- If neither the entity nor its parent are in the tree, skip
				if parent and parent:IsValid() then
					local parent_in_tree = tree_builder.find_tree_item(state.tree_items, parent:GetGUID())

					if not parent_in_tree then
						local entity_in_tree = tree_builder.find_tree_item(state.tree_items, entity:GetGUID())

						if not entity_in_tree then return end
					end
				end

				-- For removals, if entity is not in tree, skip
				if action == "unparented" then
					local entity_in_tree = tree_builder.find_tree_item(state.tree_items, entity:GetGUID())

					if not entity_in_tree then return end
				end

				if action == "parented" and parent and parent:IsValid() then
					-- Try incremental insert for added entities
					if try_incremental_tree_insert(entity, parent) then return end
				elseif action == "unparented" then
					-- Try incremental remove for removed entities
					if try_incremental_tree_remove(entity) then return end
				end

				local branch_entity = parent and
					parent:IsValid() and
					parent or
					tree_builder.get_entity_world_root(entity)

				if branch_entity and should_defer_tree_refresh(branch_entity) then return end

				request_editor_sync(true, false, branch_entity)
			end)
			local remove_component_listener = world:AddLocalListener("OnEntityComponentChanged", function(_, entity)
				local selected_entity = get_selected_entity()

				if selected_entity and entity == selected_entity then
					request_editor_sync(false, true)
				end
			end)
			window:CallOnRemove(remove_hierarchy_listener, remove_hierarchy_listener)
			window:CallOnRemove(remove_component_listener, remove_component_listener)
		end

		add_world_listeners(Entity.World)
		add_world_listeners(Panel.World)
	end

	sync_tree_items()
	sync_selection()

	function window:GetSelectedEntityGUID()
		return state.selected_entity_guid
	end

	return window
end
