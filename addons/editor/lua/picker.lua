local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local raycast = import("goluwa/physics/raycast.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local input = import("goluwa/input.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local highlight = import("lua/highlight.lua")
local event = import("goluwa/event.lua")
local CameraComponent = import("lua/components/camera.lua")
local picker = library()

local function is_visual_pick_helper_entity(entity)
	return entity.visual_primitive ~= nil or entity.VisualOwner ~= nil
end

local function has_visual_pick_target(entity)
	local entries = entity.visual:GetRenderEntries()
	return entries and entries[1] ~= nil or false
end

local function is_nonvisual_pick_candidate(entity, editor_window, excluded_entity)
	if
		entity.visual and
		has_visual_pick_target(entity) or
		is_visual_pick_helper_entity(entity)
	then
		return false
	end

	return entity.transform ~= nil
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
	local best_hit = nil
	local best_distance = max_distance or math.huge
	local marker_radius_sq = 144

	for _, entity in ipairs(Entity.World:GetChildrenList()) do
		if not is_nonvisual_pick_candidate(entity, editor_window, excluded_entity) then
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

function picker.find_3d_pick_target(mouse_pos)
	local cam = render3d.GetCamera()
	local screen_width, screen_height = render2d.GetSize()
	local ray_origin = cam:GetPosition()
	local ray_direction = cam:ScreenToWorldDirection(mouse_pos, screen_width, screen_height)
	local visual_hit = raycast.CastClosest(
		ray_origin,
		ray_direction,
		math.huge,
		function(entity)
			return entity:IsValid() and entity:GetRoot() == Entity.World
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

	return NULL
end

local function cancel_picker()
	if not picker.IsActive() then return end

	picker.hovered_entity = NULL
	highlight.SetEntity(nil)
	input.HijackKeyInput(nil)

	for _, remove in ipairs(picker.remove_events) do
		remove()
	end

	picker.remove_events = nil

	if picker.on_cancel then picker.on_cancel() end

	picker.on_pick = nil
	picker.on_cancel = nil
end

function picker.Start(opts)
	if picker.IsActive() then return end

	opts = opts or {}
	local on_pick = opts.on_pick
	local on_cancel = opts.on_cancel
	picker.on_pick = on_pick
	picker.on_cancel = on_cancel
	local cancel_fn = cancel_picker

	input.HijackKeyInput(function(key)
		if key == "escape" then
			cancel_fn()
			return true
		end
	end)

	picker.remove_events = {
		event.AddListener("Update", "picker", picker.Update),
		event.AddListener("MouseInput", "picker", picker.MouseInput, {priority = math.huge}),
	}
	return cancel_picker
end

function picker.IsActive()
	return picker.remove_events and picker.remove_events[1]
end

local debug_draw = import("goluwa/render3d/debug_draw.lua")

function picker.Update(dt)
	do -- draw non-visual entity indicators
		local NONVISUAL_HINT_TIME = 1.0

		for _, entity in ipairs(Entity.World:GetChildrenList()) do
			if is_nonvisual_pick_candidate(entity) then
				local world_pos = entity.transform:GetWorldPosition()

				if render3d.GetCamera():WorldPositionToScreen(world_pos) then
					local is_selected = entity == picker.hovered_entity
					debug_draw.DrawSphere{
						id = "editor_nonvisual_hint_" .. entity:GetGUID(),
						position = world_pos,
						radius = is_selected and 0.1 or 0.06,
						color = is_selected and {0.45, 1.0, 0.45, 0.5} or {0.8, 0.9, 1.0, 0.35},
						ignore_z = true,
						time = NONVISUAL_HINT_TIME,
					}
				end
			end
		end
	end

	local hovered = MouseInput.GetHoveredObject() or NULL

	if not hovered:IsValid() then
		picker.hovered_entity = picker.find_3d_pick_target(system.GetWindow():GetMousePosition())
	else
		picker.hovered_entity = hovered
	end

	highlight.SetEntity(picker.hovered_entity)
end

function picker.MouseInput(button, press)
	if not picker.hovered_entity:IsValid() then return end

	if not press then return end

	if button == "button_1" then
		if picker.on_pick(picker.hovered_entity) == false then return true end
	end

	cancel_picker()
end

return picker
