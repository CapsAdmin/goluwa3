local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Panel = import("goluwa/ecs/panel.lua")
local prototype = import("goluwa/prototype.lua")
local Entity = import("goluwa/ecs/entity.lua")
local input = import("goluwa/input.lua")
local Quat = import("goluwa/structs/quat.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local Gizmo = import("lua/gizmo.lua")
local Highlight = import("lua/highlight.lua")
local shapes = import("lua/shapes.lua")
local ContextMenu = import("lua/ui/elements/context_menu.lua")
local MenuBar = import("lua/ui/elements/menu_bar.lua")
local MenuItem = import("lua/ui/elements/context_menu_item.lua")
local PropertyEditor = import("lua/ui/elements/property_editor.lua")
local ScrollablePanel = import("lua/ui/elements/scrollable_panel.lua")
local Splitter = import("lua/ui/elements/splitter.lua")
local Text = import("lua/ui/elements/text.lua")
local Tree = import("lua/ui/elements/tree.lua")
local Window = import("lua/ui/elements/window.lua")
local theme = import("lua/ui/theme.lua")
local Gallery = import("./gallery.lua")

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function point_in_rect(point, rect_pos, rect_size)
	return point.x >= rect_pos.x and
		point.y >= rect_pos.y and
		point.x < rect_pos.x + rect_size.x and
		point.y < rect_pos.y + rect_size.y
end

local function rects_overlap(pos_a, size_a, pos_b, size_b)
	return pos_a.x < pos_b.x + size_b.x and
		pos_a.x + size_a.x > pos_b.x and
		pos_a.y < pos_b.y + size_b.y and
		pos_a.y + size_a.y > pos_b.y
end

local function get_editor_viewport(world_size, window_pos, window_size)
	local viewport_pos = Vec2(0, 0)
	local viewport_size = world_size:Copy()
	local clamped_window_pos = Vec2(clamp(window_pos.x, 0, world_size.x), clamp(window_pos.y, 0, world_size.y))
	local clamped_window_size = Vec2(
		math.max(0, math.min(window_size.x, world_size.x - clamped_window_pos.x)),
		math.max(0, math.min(window_size.y, world_size.y - clamped_window_pos.y))
	)

	if clamped_window_pos.x <= 0 and clamped_window_size.x > 0 then
		viewport_pos.x = clamp(clamped_window_pos.x + clamped_window_size.x, 0, world_size.x)
		viewport_size.x = math.max(1, world_size.x - viewport_pos.x)
	end

	return viewport_pos, viewport_size
end

local function get_focus_owner()
	local focused = prototype.GetFocusedObject and prototype.GetFocusedObject() or NULL
	return focused
end

local function has_parent(panel, parent)
	local current = panel

	while current and current.IsValid and current:IsValid() do
		if current == parent then return true end

		current = current:GetParent()
	end

	return false
end

local function has_text_focus(window)
	local focused = get_focus_owner()

	if not (focused and focused.IsValid and focused:IsValid()) then return false end

	if window and not has_parent(focused, window) then return false end

	return focused.text ~= nil or focused.Name == "TextEdit"
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
	local new_pitch = clamp(camera_state.pitch + scaled_delta.y, camera_state.min_pitch, camera_state.max_pitch)
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

	if input.IsKeyDown("left_control") or input.IsKeyDown("right_control") then
		move_local.y = move_local.y - 1
	end

	local move = Vec3()

	if move_local:GetLength() > 0.0001 then
		move_local = move_local:GetNormalized()
		move = camera_state.rotation:GetForward() * move_local.z + camera_state.rotation:GetRight() * move_local.x + camera_state.rotation:GetUp() * move_local.y

		if move:GetLength() > 0.0001 then move = move:GetNormalized() end
	end

	local speed = camera_state.speed

	if input.IsKeyDown("left_shift") then
		speed = speed * camera_state.sprint_multiplier
	end

	camera_state.velocity = approach_vec(camera_state.velocity, move * speed, camera_state.acceleration * dt)
	camera_state.position = camera_state.position + camera_state.velocity * dt
end

local function get_component_name(entity, component)
	for name, value in pairs(entity.component_map or {}) do
		if value == component then return name end
	end

	return component.Type or "component"
end

local function get_entity_label(entity)
	local name = entity.GetName and entity:GetName() or ""
	local key = entity.GetKey and entity:GetKey() or ""
	local base = name ~= "" and name or key ~= "" and key or (entity.Type or "entity")

	if name ~= "" and key ~= "" and key ~= name then
		base = name .. " [" .. key .. "]"
	end

	return base
end

local function get_first_spawned_entity()
	for _, child in ipairs(Entity.World:GetChildren()) do
		if child and child:IsValid() then return child end
	end

	return nil
end

local function get_valid_children(entity)
	local out = {}

	for _, child in ipairs(entity:GetChildren()) do
		if child and child:IsValid() and child ~= entity and child:GetParent() == entity then
			out[#out + 1] = child
		end
	end

	return out
end

local function get_root_entities()
	return get_valid_children(Entity.World)
end

local function get_entity_by_guid(guid)
	if not guid or guid == "" then return nil end

	local entity = prototype.GetObjectByGUID(guid)

	if entity and entity:IsValid() then return entity end

	return nil
end

local function get_drop_parent(drop_info)
	if not drop_info then return nil end

	if drop_info.position == "inside" then
		return drop_info.target_node and drop_info.target_node.Entity or nil
	end

	return drop_info.parent_node and drop_info.parent_node.Entity or Entity.World
end

local function count_valid_children(entity)
	local count = 0

	for _, child in ipairs(get_valid_children(entity)) do
		if child and child:IsValid() then count = count + 1 end
	end

	return count
end

local function build_property_node(component, component_name, info, hooks)
	local value = prototype.GetProperty(component, info.var_name)
	local node = {
		Key = component.Owner:GetGUID() .. "/" .. component_name .. "/" .. info.var_name,
		Text = info.var_name,
		Value = value,
		GetValue = function()
			return prototype.GetProperty(component, info.var_name)
		end,
	}
	local property_type = info.enums and "enum" or info.type

	if property_type == "boolean" then
		node.Type = "boolean"
	elseif property_type == "number" or property_type == "integer" then
		node.Type = "number"
		node.Precision = property_type == "integer" and 0 or 3
	elseif property_type == "string" then
		node.Type = "string"
	elseif property_type == "vec3" or property_type == "Vec3" then
		node.Type = "vec3"
	elseif property_type == "quat" or property_type == "Quat" then
		node.Type = "quat"
	elseif property_type == "color" or property_type == "Color" then
		node.Type = "color"
	elseif property_type == "enum" then
		node.Type = "enum"
		node.Options = {}

		for _, option in ipairs(info.enums or {}) do
			node.Options[#node.Options + 1] = {
				Text = tostring(option),
				Value = option,
			}
		end
	else
		node.Type = "string"
		node.Value = tostring(value)
		node.Description = "String preview for unsupported value type " .. tostring(info.type)
		node.OnChange = function()
			return
		end
		return node
	end

	node.OnChange = function(_, next_value)
		if property_type == "integer" then
			next_value = math.floor((tonumber(next_value) or 0) + 0.5)
		end

		if hooks and hooks.OnPropertyChangeStart then
			hooks.OnPropertyChangeStart(component, info, next_value)
		end

		local ok, err = pcall(function()
			prototype.SetProperty(component, info.var_name, next_value)
		end)

		if hooks and hooks.OnPropertyChangeEnd then
			hooks.OnPropertyChangeEnd(component, info, next_value, ok, err)
		end

		if not ok then
			print(
				"editor failed to set property",
				component.Owner,
				component_name,
				info.var_name,
				err
			)
		end

		return ok
	end
	return node
end

local function build_property_items(entity, hooks)
	if not entity or not entity:IsValid() then return {} end

	local items = {}

	for _, component in ipairs(entity.component_list or {}) do
		local component_name = get_component_name(entity, component)
		local children = {}

		for _, info in ipairs(prototype.GetStorableVariables(component)) do
			children[#children + 1] = build_property_node(component, component_name, info, hooks)
		end

		items[#items + 1] = {
			Key = entity:GetGUID() .. "/" .. component_name,
			Text = component_name,
			Expanded = true,
			Children = children,
		}
	end

	return items
end

local function build_tree_snapshot(entity, expanded_entities, visited)
	if not entity or not entity:IsValid() then return nil end

	local guid = entity:GetGUID()

	if visited[entity] then return nil end

	visited[entity] = true
	local children = {}
	local valid_children = get_valid_children(entity)

	for _, child in ipairs(valid_children) do
		local child_node = build_tree_snapshot(child, expanded_entities, visited)

		if child_node then children[#children + 1] = child_node end
	end

	visited[entity] = nil
	return {
		Entity = entity,
		Key = guid,
		Text = get_entity_label(entity),
		HasChildren = valid_children[1] ~= nil,
		Children = children,
	}
end

local function build_tree_items(expanded_entities)
	local items = {}
	local visited = {}

	for _, entity in ipairs(get_root_entities()) do
		local node = build_tree_snapshot(entity, expanded_entities, visited)

		if node then items[#items + 1] = node end
	end

	return items
end

local function find_tree_item(items, key)
	for _, item in ipairs(items or {}) do
		if item.Key == key then return item end

		local found = find_tree_item(item.Children, key)

		if found then return found end
	end

	return nil
end

return function(props)
	props = props or {}
	local state = {
		selected_entity = nil,
		selected_entity_guid = props.SelectedEntityGUID,
		expanded_entities = {},
		tree_items = {},
	}
	local tree_view
	local property_editor
	local footer_text
	local window
	local selected_property_listener_removers = {}
	local property_change_sync_blocked = 0
	local refresh_property_editor
	local update_footer
	local refresh_property_key
	local sync_tree_items
	local editor_camera = {
		enabled = true,
		scale_viewport = false,
		position = nil,
		rotation = nil,
		pitch = 0,
		velocity = Vec3(),
		viewport_pos = Vec2(),
		viewport_size = Vec2(1, 1),
		mouse_sensitivity = 0.0075,
		min_pitch = -math.pi / 2 + 0.01,
		max_pitch = math.pi / 2 - 0.01,
		speed = 18,
		sprint_multiplier = 2.25,
		acceleration = 220,
		dragging = false,
		block_movement = false,
	}
	local active_camera_component = nil
	local active_camera_was_active = false

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
		editor_camera.pitch = math.asin(clamp(forward.y, -1, 1))
		editor_camera.velocity = Vec3()
	end

	local function update_editor_camera_viewport()
		local camera = render3d.GetCamera()
		local world_size = Panel.World.transform:GetSize()
		local viewport_pos = Vec2(0, 0)
		local viewport_size = world_size:Copy()

		if editor_camera.scale_viewport then
			local window_pos = window.transform:GetPosition()
			local window_size = window.transform:GetSize()
			viewport_pos, viewport_size = get_editor_viewport(world_size, window_pos, window_size)
		end

		editor_camera.viewport_pos = viewport_pos
		editor_camera.viewport_size = viewport_size
		camera:SetViewport(Rect(viewport_pos.x, viewport_pos.y, viewport_size.x, viewport_size.y))
	end

	local function restore_editor_camera_viewport()
		render3d.GetCamera():SetViewport(Rect(0, 0, Panel.World.transform:GetSize().x, Panel.World.transform:GetSize().y))
	end

	local function mouse_in_editor_window(mouse_pos)
		return point_in_rect(mouse_pos, window.transform:GetPosition(), window.transform:GetSize())
	end

	local function mouse_in_editor_viewport(mouse_pos)
		if not editor_camera.scale_viewport then
			return not mouse_in_editor_window(mouse_pos)
		end

		return point_in_rect(mouse_pos, editor_camera.viewport_pos, editor_camera.viewport_size)
	end

	local function context_menu_blocks_world(mouse_pos)
		local menu = Panel.World:GetKeyed("EditorMenuBarContextMenu") or
			Panel.World:GetKeyed("EditorTreeContextMenu")

		if not (menu and menu.IsValid and menu:IsValid()) then return false end

		return rects_overlap(
			mouse_pos,
			Vec2(1, 1),
			menu.transform:GetPosition(),
			menu.transform:GetSize()
		)
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
		local can_drag = mouse_in_editor_viewport(mouse_pos) and
			not focus_blocks_movement and
			not mouse_in_editor_window(mouse_pos)
			and
			not world_blocked
		editor_camera.dragging = can_drag and input.IsMouseDown("button_2")
		editor_camera.block_movement = focus_blocks_movement or world_blocked or not mouse_in_editor_viewport(mouse_pos)

		if editor_camera.dragging then
			update_editor_camera_rotation(editor_camera, system.GetWindow():GetMouseDelta() / 2)
		end

		update_editor_camera_position(editor_camera, dt)
		apply_editor_camera()
	end

	local function close_active_context_menu()
		local active = Panel.World:GetKeyed("EditorTreeContextMenu")

		if active and active:IsValid() then active:Remove() end
	end

	local function set_hovered_entity(entity)
		Highlight.EnableHighlight(entity)
	end

	local function get_selected_entity()
		if state.selected_entity and state.selected_entity:IsValid() then
			return state.selected_entity
		end

		state.selected_entity = get_entity_by_guid(state.selected_entity_guid)
		return state.selected_entity
	end

	local function clear_selected_property_listeners()
		for i = 1, #selected_property_listener_removers do
			selected_property_listener_removers[i]()
		end

		list.clear(selected_property_listener_removers)
	end

	local function refresh_selected_property_listeners()
		clear_selected_property_listeners()
		local entity = get_selected_entity()

		if not (entity and entity:IsValid()) then return end

		for _, component in ipairs(entity.component_list or {}) do
			if component and component.IsValid and component:IsValid() then
				local component_name = get_component_name(entity, component)
				selected_property_listener_removers[#selected_property_listener_removers + 1] = component:AddPropertyListener(function(_, key)
					if property_change_sync_blocked > 0 then return end

					refresh_property_key(component, component_name, key)
				end)
			end
		end
	end

	local property_node_hooks = {
		OnPropertyChangeStart = function()
			property_change_sync_blocked = property_change_sync_blocked + 1
		end,
		OnPropertyChangeEnd = function()
			property_change_sync_blocked = math.max(0, property_change_sync_blocked - 1)
		end,
	}
	update_footer = function(entity, tree_items)
		if not footer_text or not footer_text:IsValid() then return end

		local gizmo_status_info = Gizmo.GetStatus()
		local gizmo_status = string.format("gizmo: %s/%s", gizmo_status_info.mode, gizmo_status_info.space)

		if gizmo_status_info.active_drag then
			gizmo_status = string.format(
				"%s [%s %s]",
				gizmo_status,
				gizmo_status_info.active_drag.kind,
				gizmo_status_info.active_drag.axis_id:upper()
			)
		end

		if not entity then
			footer_text.text:SetText("No spawned 3D entities.  |  " .. gizmo_status)
			return
		end

		footer_text.text:SetText(
			string.format(
				"%d root entities  |  selected: %s  |  %s",
				#tree_items,
				get_entity_label(entity),
				gizmo_status
			)
		)
	end

	local function ensure_expanded_path(entity)
		local current = entity

		while current and current:IsValid() and current ~= Entity.World do
			state.expanded_entities[current:GetGUID()] = true
			current = current:GetParent()
		end
	end

	local function set_selected_entity(entity, ensure_visible)
		entity = entity and entity:IsValid() and entity or nil
		local previous_guid = state.selected_entity_guid
		state.selected_entity = entity
		state.selected_entity_guid = entity and entity:GetGUID() or nil
		Gizmo.EnableGizmo(entity)

		if ensure_visible and entity and state.selected_entity_guid ~= previous_guid then
			ensure_expanded_path(entity)
		end
	end

	local function resolve_selected_entity(tree_items)
		local selected_entity = get_selected_entity()
		local selected_item = find_tree_item(tree_items, state.selected_entity_guid)
		selected_entity = selected_entity and selected_entity:IsValid() and selected_entity or nil
		selected_entity = selected_item and selected_item.Entity or selected_entity

		if selected_entity then return selected_entity end

		return get_root_entities()[1] or get_first_spawned_entity()
	end

	refresh_property_editor = function()
		if not property_editor or not property_editor:IsValid() then return end

		property_editor:SetItems(build_property_items(get_selected_entity(), property_node_hooks))
		property_editor:ExpandAll()
	end
	refresh_property_key = function(component, component_name, property_name)
		if not property_editor or not property_editor:IsValid() then return end

		local entity = get_selected_entity()

		if not (entity and entity:IsValid() and component and component:IsValid()) then
			return
		end

		local row_key = entity:GetGUID() .. "/" .. component_name .. "/" .. property_name

		if property_name == "Name" or property_name == "Key" then
			property_editor:RefreshValueForKey(row_key)
			sync_tree_items()
			update_footer(state.selected_entity, state.tree_items)
			return
		end

		if property_editor:RefreshValueForKey(row_key) then return end

		refresh_property_editor()
	end
	sync_tree_items = function()
		if not tree_view or not tree_view:IsValid() then return end

		local tree_items = build_tree_items(state.expanded_entities)
		set_selected_entity(resolve_selected_entity(tree_items), false)
		state.tree_items = tree_items
		tree_view:SetItems(tree_items)
		tree_view:SetSelectedKey(state.selected_entity_guid)
		update_footer(state.selected_entity, tree_items)
	end

	local function sync_selection()
		set_selected_entity(resolve_selected_entity(state.tree_items), false)
		refresh_selected_property_listeners()

		if tree_view and tree_view:IsValid() then
			tree_view:SetSelectedKey(state.selected_entity_guid)
		end

		refresh_property_editor()
		update_footer(state.selected_entity, state.tree_items)
	end

	local function open_gallery()
		Panel.World:Ensure(Gallery({Key = "GalleryWindow"}))
	end

	local function create_child_shape(parent_entity, kind)
		if not parent_entity or not parent_entity:IsValid() then return end

		local child_count = count_valid_children(parent_entity)
		local config = {
			Name = kind == "sphere" and "sphere" or "box",
			Collision = false,
			RigidBody = false,
			PhysicsNoCollision = true,
			Position = Vec3(child_count * 1.5, 0, 0),
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

			if parent_entity ~= Entity.World then
				state.expanded_entities[parent_entity:GetGUID()] = true
			end

			set_selected_entity(entity, true)
			sync_tree_items()
			sync_selection()
		end
	end

	local function remove_entity(entity)
		if not entity or not entity:IsValid() or entity == Entity.World then return end

		local parent = entity:GetParent()

		if parent and parent:IsValid() and parent ~= Entity.World then
			set_selected_entity(parent, true)
		else
			set_selected_entity(nil, false)
		end

		entity:Remove()
		sync_tree_items()
		sync_selection()
	end

	local function open_tree_context_menu(entity)
		if not entity or not entity:IsValid() then return false end

		local can_remove = entity ~= Entity.World
		close_active_context_menu()
		Panel.World:Ensure(
			ContextMenu{
				Key = "EditorTreeContextMenu",
				Position = system.GetWindow():GetMousePosition():Copy(),
				OnClose = function(ent)
					ent:Remove()
				end,
			}{
				MenuItem{
					Text = "Sphere",
					OnClick = function()
						create_child_shape(entity, "sphere")
					end,
				},
				MenuItem{
					Text = "Box",
					OnClick = function()
						create_child_shape(entity, "box")
					end,
				},
				can_remove and
				MenuItem{
					Text = "-",
					Disabled = true,
				} or
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

		for _, name in ipairs(theme.GetPresetNames()) do
			local label = theme.GetPresetLabel(name)

			if name == theme.GetPresetName() then label = label .. " (active)" end

			items[#items + 1] = MenuItem{
				Text = label,
				OnClick = function()
					if name == theme.GetPresetName() then return end

					theme.SetPreset(name)

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
			MenuItem{Text = "-", Disabled = true},
			MenuItem{Text = "Theme", Items = build_theme_menu_items()},
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
					update_footer(state.selected_entity, state.tree_items)
				end,
			}
		end

		local function add_space_item(label, space)
			if Gizmo.GetSpace() == space then label = label .. " (active)" end

			items[#items + 1] = MenuItem{
				Text = label,
				OnClick = function()
					Gizmo.SetSpace(space)
					update_footer(state.selected_entity, state.tree_items)
				end,
			}
		end

		add_mode_item("Move", "move")
		add_mode_item("Rotate", "rotate")
		items[#items + 1] = MenuItem{Text = "-", Disabled = true}
		add_space_item("Local Space", "local")
		add_space_item("World Space", "world")
		return items
	end

	set_selected_entity(get_selected_entity(), true)
	Gizmo.SetMode(props.GizmoMode or Gizmo.GetMode())
	Gizmo.SetSpace(props.GizmoSpace or Gizmo.GetSpace())

	if not state.selected_entity then
		set_selected_entity(get_root_entities()[1] or get_first_spawned_entity(), true)
	end

	state.tree_items = build_tree_items(state.expanded_entities)
	local size = props.Size or Vec2(400, 540)
	local world_size = Panel.World.transform:GetSize()

	if not props.Size then size = Vec2(400, world_size.y) end

	local position = props.Position or Vec2(0, 0)
	window = Window{
		Key = props.Key or "GameEditorWindow",
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
							MenuItem{Text = "Open UI Gallery", OnClick = open_gallery},
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
					layout = {
						GrowWidth = 1,
						--GrowHeight = 1,
						FitHeight = true,
					},
					IsExpanded = function(node, path, key)
						return state.expanded_entities[key] == true
					end,
					OnSelect = function(node, key)
						set_selected_entity(node and node.Entity or get_entity_by_guid(key), true)
						sync_selection()
					end,
					OnToggle = function(node, expanded, key)
						state.expanded_entities[key] = expanded == true
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
					CanDropInside = function()
						return true
					end,
					OnDrop = function(drop_info)
						local source_entity = drop_info.source_node and drop_info.source_node.Entity or nil
						local next_parent = get_drop_parent(drop_info)

						if not source_entity or not source_entity:IsValid() then return false end

						if not next_parent or not next_parent:IsValid() then
							next_parent = Entity.World
						end

						if next_parent == source_entity then return false end

						if next_parent ~= Entity.World and next_parent:ContainsParent(source_entity) then
							return false
						end

						if source_entity:GetParent() == next_parent then return false end

						if next_parent ~= Entity.World then
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
				PropertyEditor{
					Ref = function(self)
						property_editor = self
					end,
					Items = build_property_items(state.selected_entity, property_node_hooks),
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
						FitWidth = false,
						MinSize = Vec2(size.x - 24, 0),
					},
				},
			},
		},
		Text{
			Ref = function(self)
				footer_text = self
				update_footer(state.selected_entity, state.tree_items)
			end,
			Text = "",
			Color = "text_disabled",
			FontSize = "XS",
			layout = {
				GrowWidth = 1,
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
	window:AddGlobalEvent("Update")

	function window:OnUpdate(dt)
		update_editor_camera(dt)
	end

	Gizmo.SetStateChangedCallback(window, function(status)
		update_footer(state.selected_entity, state.tree_items)
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
		local remove_hierarchy_listener = Entity.World:AddLocalListener("OnEntityHierarchyChanged", function()
			sync_tree_items()
			sync_selection()
		end)
		local remove_component_listener = Entity.World:AddLocalListener("OnEntityComponentChanged", function()
			sync_tree_items()
			sync_selection()
		end)
		window:CallOnRemove(remove_hierarchy_listener, remove_hierarchy_listener)
		window:CallOnRemove(remove_component_listener, remove_component_listener)
	end

	sync_tree_items()
	sync_selection()

	function window:GetSelectedEntityGUID()
		return state.selected_entity_guid
	end

	return window
end
