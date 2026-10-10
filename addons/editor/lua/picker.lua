local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local input = import("goluwa/input.lua")
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local static_world = import("goluwa/entities/components/static_world.lua")
local highlight = import("lua/highlight.lua")
local Gizmo = import("lua/gizmo.lua")
local event = import("goluwa/event.lua")
local CameraComponent = import("lua/components/camera.lua")
local AssetBrowser = import("lua/asset_browser.lua")
local assets = import("goluwa/assets.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local picker = library()
picker.include_transient = false
local nonvisual_candidates = {}
local nonvisual_candidates_dirty = true
local nonvisual_candidates_time = -math.huge
local NONVISUAL_REBUILD_INTERVAL = 1

local function is_visual_pick_helper_entity(entity)
	return entity.visual_primitive ~= nil or entity.VisualOwner ~= nil
end

do
	local function collect(entity, out)
		for _, child in ipairs(entity:GetChildren()) do
			if not is_visual_pick_helper_entity(child) then
				if child.transform and not child.visual then out[#out + 1] = child end

				collect(child, out)
			end
		end
	end

	function picker.GetNonvisualCandidates()
		local now = system.GetElapsedTime()

		if
			nonvisual_candidates_dirty and
			now - nonvisual_candidates_time >= NONVISUAL_REBUILD_INTERVAL
		then
			nonvisual_candidates = {}
			collect(Entity.World, nonvisual_candidates)
			nonvisual_candidates_dirty = false
			nonvisual_candidates_time = now
		end

		return nonvisual_candidates
	end

	local function mark_dirty()
		nonvisual_candidates_dirty = true
	end

	Entity.World:AddLocalListener("OnEntityHierarchyChanged", mark_dirty)
	Entity.World:AddLocalListener("OnEntityComponentChanged", mark_dirty)
end

local function find_nonvisual_entity_hit(mouse_pos, ray_origin, ray_direction, max_distance)
	local cam = render3d.GetCamera()
	local screen_size = render2d.GetSize()
	local best_hit = nil
	local best_distance = max_distance or math.huge
	local marker_radius_sq = 144

	for _, entity in ipairs(picker.GetNonvisualCandidates()) do
		if not entity:IsValid() then goto continue2 end

		local world_pos = entity.transform:GetWorldPosition()
		local screen_pos = cam:WorldPositionToScreen(world_pos, screen_size)

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
	raycast.SetLODCamera(ray_origin)
	local ok, visual_hit = pcall(
		raycast.CastClosest,
		ray_origin,
		ray_direction,
		math.huge,
		function(entity)
			return entity:IsValid() and entity:GetRoot() == Entity.World
		end
	)
	raycast.SetLODCamera(nil)

	if not ok then error(visual_hit, 0) end

	local fallback_hit = find_nonvisual_entity_hit(mouse_pos, ray_origin, ray_direction, math.huge)

	if fallback_hit then return fallback_hit.entity end

	local world = static_world.GetActive()

	if world then
		local geometry_entity, geometry_distance = world:PickGeometry(ray_origin, ray_direction)

		if
			geometry_entity and
			(
				not visual_hit or
				geometry_distance <= visual_hit.distance + 0.01
			)
		then
			return geometry_entity
		end
	end

	if visual_hit then
		local entity = visual_hit.primitive.entity

		if not picker.include_transient then
			while entity:IsValid() and entity:GetTransient() do
				entity = entity:GetParent()
			end
		end

		return entity
	end

	return NULL
end

local function cancel_picker()
	if not picker.IsActive() then return end

	picker.hovered_entity = NULL
	highlight.SetEntity(nil)
	Gizmo.SetHidden(false)
	input.HijackKeyInput(nil)

	for _, remove in ipairs(picker.remove_events) do
		remove()
	end

	picker.remove_events = nil

	if picker.on_cancel then picker.on_cancel() end

	picker.on_pick = nil
	picker.on_cancel = nil
end

function picker.StartEntityPicker(opts)
	if picker.IsActive() then return end

	opts = opts or {}
	local on_pick = opts.on_pick
	local on_cancel = opts.on_cancel
	picker.on_pick = on_pick
	picker.on_cancel = on_cancel
	local cancel_fn = cancel_picker
	Gizmo.SetHidden(true)

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

local debug_draw = import("goluwa/debug_draw.lua")

function picker.Update(dt)
	do
		local NONVISUAL_HINT_TIME = 1.0

		for _, entity in ipairs(picker.GetNonvisualCandidates()) do
			if entity:IsValid() then
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
		picker.hovered_entity = picker.find_3d_pick_target(system.GetWindow():GetMousePosition()) or NULL
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

-- most categories are identified by their path, a category can say its value is something else (a prefab is its name)
function picker.PickAsset(category, current_value, callback)
	local config = category and assets.categories[category] or {}
	local selected = current_value

	if config.get_path and current_value and current_value ~= "" then
		selected = config.get_path(current_value)
	end

	Panel.World:Ensure(
		AssetBrowser{
			Key = "AssetPicker",
			PickerCategory = category,
			SelectedPath = selected,
			OnPick = function(entry)
				callback(config.get_value and config.get_value(entry) or entry.path)
			end,
		}
	)
end

event.AddListener("PickObject", "picker", function(what, callback, options)
	if what == "material" then
		picker.PickAsset("materials", nil, function(path)
			callback(assets.GetMaterial(path))
		end)
	elseif what == "texture" then
		picker.PickAsset("textures", nil, function(path)
			callback(assets.GetTexture(path))
		end)
	elseif what == "asset" then
		picker.PickAsset(options.category, options.path, callback)
	end
end)

return picker
