local Vec2 = import("goluwa/structs/vec2.lua")
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
local assets = import("goluwa/assets.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local timer = import("goluwa/timer.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local picker = {}
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

local function is_blacklisted(entity)
	local blacklist = picker.entity_blacklist

	if not blacklist then return false end

	for _, banned in ipairs(blacklist) do
		if banned:IsValid() and (entity == banned or entity:ContainsParent(banned)) then
			return true
		end
	end

	return false
end

local function find_nonvisual_entity_hit(mouse_pos, ray_origin, ray_direction, max_distance)
	local cam = render3d.GetCamera()
	local screen_size = render2d.GetSize()
	local best_hit = nil
	local best_distance = max_distance or math.huge
	local marker_radius_sq = 144

	for _, entity in ipairs(picker.GetNonvisualCandidates()) do
		if
			not entity:IsValid() or
			is_blacklisted(entity) or
			(
				picker.filter and
				not picker.filter(entity)
			)
		then
			goto continue2
		end

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

function picker.GetPickPosition()
	local window = system.GetWindow()

	if window:GetMouseTrapped() then
		local width, height = render2d.GetSize()
		return Vec2(width / 2, height / 2)
	end

	return window:GetMousePosition()
end

local function is_pickable(entity)
	if not (entity:IsValid() and entity:GetRoot() == Entity.World) then return false end

	local owner = entity.VisualOwner and entity.VisualOwner.Owner or entity

	if is_blacklisted(owner) then return false end

	return not picker.filter or picker.filter(owner)
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
		is_pickable
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
			(not picker.filter or picker.filter(geometry_entity)) and
			(
				not visual_hit or
				geometry_distance <= visual_hit.distance + 0.01
			)
		then
			return geometry_entity
		end
	end

	if visual_hit and picker.filter then return visual_hit.primitive.entity.VisualOwner.Owner end

	if visual_hit then
		local entity = visual_hit.primitive.entity

		if not picker.include_transient then
			while entity:IsValid() and entity:IsRuntime() do
				entity = entity:GetParent()
			end
		end

		return entity
	end

	return NULL
end

local session
local finish

local function has_model(entity)
	return entity.visual ~= nil and entity.visual:GetModelPath() ~= ""
end

local function in_prefab(entity)
	local node = entity

	while node:IsValid() do
		if node.prefab and node.prefab.Path ~= "" then return true end

		node = node:GetParent()
	end

	return false
end

local function find_model_path(entity)
	local candidates = {entity}

	for _, node in ipairs(entity:GetParentList()) do
		candidates[#candidates + 1] = node
	end

	for _, node in ipairs(entity:GetChildrenList()) do
		candidates[#candidates + 1] = node
	end

	for _, node in ipairs(candidates) do
		local path = node.visual and node.visual:GetModelPath() or ""

		if path ~= "" then return path end
	end
end

local function find_prefab_path(entity)
	local node = entity

	while node:IsValid() do
		if node.prefab and node.prefab.Path ~= "" then return node.prefab.Path end

		node = node:GetParent()
	end
end

local MODES = {
	entity = {},
	model = {world_only = true, filter = has_model, resolve = find_model_path},
	prefab = {world_only = true, filter = in_prefab, resolve = find_prefab_path},
	material = {hit = true},
	texture = {hit = true},
}

local function open_texture_menu(material)
	local mine = session
	local items = {}

	for _, info in ipairs(material:GetTextures()) do
		local texture = info.texture
		local name = info.name:lower()
		local path = texture.config.path
		items[#items + 1] = MenuItem{
			Text = path and (name .. "  " .. path:match("[^/]*$")) or name,
			IconTexture = texture,
			OnClick = function()
				mine.opts.on_pick(texture, name)
				picker.Stop()
			end,
		}
	end

	if not items[1] then items[1] = MenuItem{Text = "no textures", Disabled = true} end

	mine.menu_open = true
	Panel.OpenContextMenu(
		{
			Position = picker.GetPickPosition(),
			mouse_input = {RequestMouse = true},
			OnClose = function(self)
				self:Remove()
				-- a click on an item closes the menu too, before or after it runs, so look again next frame
				timer.Delay(0, function()
					if session == mine then picker.Stop() end
				end)
			end,
		},
		items
	)
end

local function update_menu()
	if input.IsMouseDown("button_1") then return end

	event.RemoveListener("Update", "picker_menu")
	open_texture_menu(session.menu_material)
end

local function update_finish()
	if input.IsMouseDown("button_1") then return end

	event.RemoveListener("Update", "picker_finish")
	local done = finish
	finish = nil

	if done.desktop_shown then desktop.Show(true) end

	if done.on_done then done.on_done() end

end

function picker.Stop()
	if not session then return end

	local ended = session
	session = nil
	picker.hovered_entity = NULL
	picker.world_only = nil
	picker.filter = nil
	picker.entity_blacklist = nil
	highlight.SetEntity(nil)
	Gizmo.SetHidden(false)
	input.HijackKeyInput(nil)

	for _, remove in ipairs(ended.remove_events) do
		remove()
	end

	if ended.menu_material then
		event.RemoveListener("Update", "picker_menu")

		if ended.menu_open then Panel.CloseContextMenu() end
	end

	local opts = ended.opts

	if opts.on_stop then opts.on_stop() end

	if ended.desktop_shown or opts.on_done then
		finish = {desktop_shown = ended.desktop_shown, on_done = opts.on_done}
		event.AddListener("Update", "picker_finish", update_finish)
	end
end

local function get_hit_material(hit)
	local primitive = hit.primitive
	return primitive.entity.VisualOwner.MaterialOverride or
		primitive.material or
		render3d.GetDefaultMaterial()
end

local function on_hit_click(button, press)
	if button ~= "button_1" or not press then return end

	local hovered = not system.GetWindow():GetMouseTrapped() and MouseInput.GetHoveredObject()

	if hovered and hovered:IsValid() and not desktop.IsBackdrop(hovered) then return end

	local cam = render3d.GetCamera()
	local width, height = render2d.GetSize()
	local origin = cam:GetPosition()
	raycast.SetLODCamera(origin)
	local ok, hit = pcall(
		raycast.CastClosest,
		origin,
		cam:ScreenToWorldDirection(picker.GetPickPosition(), width, height),
		math.huge,
		is_pickable
	)
	raycast.SetLODCamera(nil)

	if not ok then error(hit, 0) end

	if hit then
		local material = get_hit_material(hit)

		if session.opts.mode == "texture" then
			session.remove_events[1]()
			session.menu_material = material
			event.AddListener("Update", "picker_menu", update_menu)
			return true
		end

		session.opts.on_pick(material, hit)
	end

	picker.Stop()
	return true
end

function picker.Start(opts)
	if session then return end

	local config = MODES[opts.mode]
	session = {opts = opts, config = config}
	picker.hovered_entity = NULL
	picker.world_only = config.world_only
	picker.filter = opts.filter or config.filter
	picker.entity_blacklist = opts.entity_blacklist
	Gizmo.SetHidden(true)

	if opts.hide_desktop then
		session.desktop_shown = desktop.IsShown()
		desktop.Hide()
	end

	input.HijackKeyInput(function(key)
		if key == "escape" then
			picker.Stop()
			return true
		end
	end)

	if config.hit then
		session.remove_events = {
			event.AddListener("MouseInput", "picker", on_hit_click, {priority = math.huge}),
		}
	else
		session.remove_events = {
			event.AddListener("Update", "picker", picker.Update),
			event.AddListener("MouseInput", "picker", picker.MouseInput, {priority = math.huge}),
		}
	end

	return picker.Stop
end

function picker.IsActive()
	return session ~= nil
end

local debug_draw = import("goluwa/debug_draw.lua")

function picker.Update(dt)
	do
		local NONVISUAL_HINT_TIME = 1.0

		for _, entity in ipairs(picker.GetNonvisualCandidates()) do
			if
				entity:IsValid() and
				not is_blacklisted(entity) and
				(
					not picker.filter or
					picker.filter(entity)
				)
			then
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

	local hovered = not system.GetWindow():GetMouseTrapped() and MouseInput.GetHoveredObject() or NULL

	if not hovered:IsValid() then
		picker.hovered_entity = picker.find_3d_pick_target(picker.GetPickPosition()) or NULL
	elseif picker.world_only then
		picker.hovered_entity = NULL
	else
		picker.hovered_entity = hovered
	end

	highlight.SetEntity(picker.hovered_entity)
end

function picker.MouseInput(button, press)
	if not picker.hovered_entity:IsValid() then return end

	if not press then return end

	if button == "button_1" then
		local entity = picker.hovered_entity
		local resolve = session.config.resolve
		local resolved = resolve and resolve(entity)

		if resolve and resolved == nil then return true end

		if session.opts.on_pick(entity, resolved) == false then return true end
	end

	picker.Stop()
end

function picker.PickAsset(category, current_value, callback)
	local config = category and assets.categories[category] or {}
	local selected = current_value

	if config.get_path and current_value and current_value ~= "" then
		selected = config.get_path(current_value)
	end

	import("lua/asset_browser.lua"){
		Key = "AssetPicker",
		PickerCategory = category,
		SelectedPath = selected,
		OnPick = function(entry)
			callback(config.get_value and config.get_value(entry) or entry.path)
		end,
	}
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
