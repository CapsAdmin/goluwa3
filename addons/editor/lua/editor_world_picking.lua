local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local raycast = import("goluwa/physics/raycast.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local transient_ui_keys = {
	ActiveContextMenu = true,
	ActiveMenuBarContextMenu = true,
	EditorMenuBarContextMenu = true,
	EditorTreeContextMenu = true,
	UITooltipOverlay = true,
}

local function is_hidden_editor_entity(entity, editor_window)
	if not (entity and entity.IsValid and entity:IsValid()) then return false end

	local current = entity

	while current and current.IsValid and current:IsValid() do
		if current == editor_window then return true end

		if current.IsContextMenuContainer then return true end

		local key = current.GetKey and current:GetKey() or ""

		if transient_ui_keys[key] then return true end

		current = current:GetParent()
	end

	return false
end

local editor_world_picking = library()

function editor_world_picking.has_visual_pick_target(entity)
	local entries = entity.visual:GetRenderEntries()
	return entries and entries[1] ~= nil or false
end

function editor_world_picking.is_visual_pick_helper_entity(entity)
	return entity.visual_primitive ~= nil or entity.VisualOwner ~= nil
end

function editor_world_picking.is_editor_control_rig_entity(entity)
	if
		entity:HasComponent("player_input") or
		entity:HasComponent("player_movement") or
		entity:HasComponent("player_physgun")
	then
		return true
	end

	return entity:GetKey() == "player_camera_rig" or entity:GetName() == "player_camera_rig"
end

function editor_world_picking.has_editor_control_rig_ancestor(entity)
	local current = entity

	while current and current:IsValid() do
		if editor_world_picking.is_editor_control_rig_entity(current) then
			return true
		end

		current = current:GetParent()
	end

	return false
end

function editor_world_picking.is_pick_excluded_entity(entity, excluded_entity)
	if editor_world_picking.has_editor_control_rig_ancestor(entity) then
		return true
	end

	local player_camera_rig = Entity.World:GetKeyed("player_camera_rig")

	if player_camera_rig and player_camera_rig:IsValid() then
		if entity == player_camera_rig or player_camera_rig:ContainsParent(entity) then
			return true
		end
	end

	if excluded_entity and excluded_entity:IsValid() then
		if entity == excluded_entity or excluded_entity:ContainsParent(entity) then
			return true
		end
	end

	return false
end

function editor_world_picking.is_nonvisual_pick_candidate(entity, editor_window, excluded_entity)
	if is_hidden_editor_entity(entity, editor_window) then return false end

	if editor_world_picking.is_pick_excluded_entity(entity, excluded_entity) then
		return false
	end

	if
		entity.visual and
		editor_world_picking.has_visual_pick_target(entity) or
		editor_world_picking.is_visual_pick_helper_entity(entity)
	then
		return false
	end

	return entity.transform ~= nil
end

function editor_world_picking.find_nonvisual_entity_hit(
	editor_window,
	mouse_pos,
	ray_origin,
	ray_direction,
	max_distance,
	excluded_entity
)
	local cam = render3d.GetCamera()
	local best_hit = nil
	local best_distance = max_distance or math.huge
	local marker_radius_sq = 144

	for _, entity in ipairs(Entity.World:GetChildrenList()) do
		if
			not editor_world_picking.is_nonvisual_pick_candidate(entity, editor_window, excluded_entity)
		then
			goto continue2
		end

		local world_pos = entity.transform:GetWorldPosition()
		local screen_pos = cam:WorldPositionToScreen(world_pos, render2d.GetSize())

		if not screen_pos then goto continue2 end

		local dx = screen_pos.x - mouse_pos.x
		local dy = screen_pos.y - mouse_pos.y
		local screen_distance_sq = dx * dx + dy * dy

		if screen_distance_sq > marker_radius_sq then goto continue2 end

		local ray_distance = (world_pos - ray_origin):Dot(ray_direction)

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

function editor_world_picking.find_world_pick_target(editor_window, excluded_entity)
	local input_window = system.GetWindow()
	local cam = render3d.GetCamera()
	local mouse_pos = input_window:GetMousePosition()
	local screen_width, screen_height = render2d.GetSize()
	local ray_origin = cam:GetPosition()
	local ray_direction = cam:ScreenToWorldDirection(mouse_pos, screen_width, screen_height)
	local visual_hit = raycast.CastClosest(
		ray_origin,
		ray_direction,
		math.huge,
		function(entity)
			return entity:IsValid() and
				entity:GetRoot() == Entity.World and
				not is_hidden_editor_entity(entity, editor_window)
				and
				not editor_world_picking.is_pick_excluded_entity(entity, excluded_entity)
		end
	)
	local fallback_hit = editor_world_picking.find_nonvisual_entity_hit(
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

return editor_world_picking
