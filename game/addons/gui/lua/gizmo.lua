local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Entity = import("goluwa/ecs/entity.lua")
local input = import("goluwa/input.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local debug_draw = import("goluwa/render3d/debug_draw.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local system = import("goluwa/system.lua")
local gizmo = library()
local listener_key = "gui_gizmo_service"
local axis_colors = {
	x = Color(0.95, 0.32, 0.28, 0.95),
	y = Color(0.30, 0.82, 0.34, 0.95),
	z = Color(0.28, 0.56, 0.96, 0.95),
}
local state = {
	gizmo_entity = nil,
	mode = "move",
	space = "local",
	hovered_handle = nil,
	active_drag = nil,
	callback_owner = nil,
	state_changed = nil,
}

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function brighten_color(color, scale)
	return Color(
		clamp(color.r * scale, 0, 1),
		clamp(color.g * scale, 0, 1),
		clamp(color.b * scale, 0, 1),
		color.a or 1
	)
end

local function is_valid_entity(entity)
	return entity and entity.IsValid and entity:IsValid() or false
end

local function is_gizmo_entity(entity)
	return is_valid_entity(entity) and entity ~= Entity.World and entity.transform ~= nil
end

local function notify_state_changed()
	if not state.state_changed then return end

	local owner = state.callback_owner

	if owner and owner.IsValid and not owner:IsValid() then
		state.callback_owner = nil
		state.state_changed = nil
		return
	end

	state.state_changed(gizmo.GetStatus())
end

local function get_entity_world_position(entity)
	if not is_gizmo_entity(entity) then return nil end

	local x, y, z = entity.transform:GetWorldMatrix():GetTranslation()
	return Vec3(x, y, z)
end

local function get_entity_pivot(entity)
	local fallback = get_entity_world_position(entity)

	if not fallback then return nil, 1 end

	if entity.model and entity.model.GetWorldAABB then
		local aabb = entity.model:GetWorldAABB()

		if aabb and aabb.min_x <= aabb.max_x then
			local extent_x = aabb.max_x - aabb.min_x
			local extent_y = aabb.max_y - aabb.min_y
			local extent_z = aabb.max_z - aabb.min_z
			return Vec3(
				(aabb.min_x + aabb.max_x) * 0.5,
				(aabb.min_y + aabb.max_y) * 0.5,
				(aabb.min_z + aabb.max_z) * 0.5
			),
			math.max(extent_x, extent_y, extent_z, 1)
		end
	end

	return fallback, 1
end

local function get_gizmo_scale(center, extent)
	local cam = render3d.GetCamera()

	if not cam then return math.max(extent * 0.75, 1.5) end

	local cam_distance = (center - cam:GetPosition()):GetLength()
	return math.max(extent * 0.75, cam_distance * 0.12, 1.5)
end

local function transform_direction(matrix, direction)
	local ox, oy, oz = matrix:TransformVectorUnpacked(0, 0, 0)
	local tx, ty, tz = matrix:TransformVectorUnpacked(direction.x, direction.y, direction.z)
	return Vec3(tx - ox, ty - oy, tz - oz):GetNormalized()
end

local function get_transform_local_rotation(transform)
	local _, interpolated_rotation = transform:GetRenderPositionRotation()
	return (transform.OverrideRotation or interpolated_rotation or transform.Rotation):GetNormalized()
end

local function get_transform_world_rotation(transform)
	local rotation = get_transform_local_rotation(transform)
	local owner = transform and transform.Owner
	local parent = owner and owner:GetParent()

	if parent and parent.IsValid and parent:IsValid() and parent.transform then
		return (get_transform_world_rotation(parent.transform) * rotation):GetNormalized()
	end

	return rotation
end

local function get_gizmo_axes(entity)
	local transform = entity.transform

	if state.space == "local" and transform then
		local world_rotation = get_transform_world_rotation(transform)
		return {
			{
				id = "x",
				direction = world_rotation:Right(),
				color = axis_colors.x,
			},
			{
				id = "y",
				direction = world_rotation:Up(),
				color = axis_colors.y,
			},
			{
				id = "z",
				direction = world_rotation:Forward(),
				color = axis_colors.z,
			},
		}
	end

	return {
		{id = "x", direction = orientation.RIGHT_VECTOR:Copy(), color = axis_colors.x},
		{id = "y", direction = orientation.UP_VECTOR:Copy(), color = axis_colors.y},
		{id = "z", direction = orientation.FORWARD_VECTOR:Copy(), color = axis_colors.z},
	}
end

local function get_viewport_size()
	local window = system.GetWindow()

	if window and window.GetSize then
		local size = window:GetSize()

		if size then return size.x, size.y end
	end

	local size = Panel.World and
		Panel.World.transform and
		Panel.World.transform:GetSize() or
		Vec2(1, 1)
	return size.x, size.y
end

local function project_world_position(position)
	local cam = render3d.GetCamera()

	if not cam then return nil end

	local width, height = get_viewport_size()
	local screen_pos, visibility = cam:WorldPositionToScreen(position, width, height)

	if visibility ~= -1 then return nil end

	return screen_pos
end

local function get_screen_segment_distance(mouse_pos, start_pos, stop_pos)
	local dx = stop_pos.x - start_pos.x
	local dy = stop_pos.y - start_pos.y
	local len_sq = dx * dx + dy * dy

	if len_sq <= 1e-6 then
		local sx = mouse_pos.x - start_pos.x
		local sy = mouse_pos.y - start_pos.y
		return math.sqrt(sx * sx + sy * sy)
	end

	local t = clamp(((mouse_pos.x - start_pos.x) * dx + (mouse_pos.y - start_pos.y) * dy) / len_sq, 0, 1)
	local px = start_pos.x + dx * t
	local py = start_pos.y + dy * t
	local ox = mouse_pos.x - px
	local oy = mouse_pos.y - py
	return math.sqrt(ox * ox + oy * oy)
end

local function get_circle_basis(normal)
	local tangent = math.abs(normal:GetDot(orientation.UP_VECTOR)) > 0.9 and
		orientation.RIGHT_VECTOR or
		orientation.UP_VECTOR
	local u = normal:GetCross(tangent)

	if u:GetLength() < 1e-5 then u = normal:GetCross(orientation.FORWARD_VECTOR) end

	u = u:GetNormalized()
	return u, normal:GetCross(u):GetNormalized()
end

local function build_axis_rotation(axis, angle)
	return QuatFromAxis(angle, axis)
end

local function get_mouse_rotation_ring_vector(center, axis_direction, radius, mouse_pos, center_screen)
	center_screen = center_screen or project_world_position(center)

	if not center_screen then return nil end

	local u, v = get_circle_basis(axis_direction)
	local u_screen = project_world_position(center + u * radius)
	local v_screen = project_world_position(center + v * radius)

	if not (u_screen and v_screen) then return nil end

	local ux = u_screen.x - center_screen.x
	local uy = u_screen.y - center_screen.y
	local vx = v_screen.x - center_screen.x
	local vy = v_screen.y - center_screen.y
	local det = ux * vy - uy * vx

	if math.abs(det) < 1e-5 then return nil end

	local dx = mouse_pos.x - center_screen.x
	local dy = mouse_pos.y - center_screen.y
	local ru = (dx * vy - dy * vx) / det
	local rv = (ux * dy - uy * dx) / det
	local ring_vector = Vec2(ru, rv)

	if ring_vector:GetLength() < 1e-5 then return nil end

	return ring_vector:GetNormalized()
end

local function set_entity_world_position(entity, world_position)
	local parent = entity and entity:GetParent()

	if parent and parent:IsValid() and parent.transform then
		entity.transform:SetPosition(parent.transform:GetWorldMatrixInverse():TransformVector(world_position))
		return
	end

	entity.transform:SetPosition(world_position)
end

local function set_entity_world_rotation(entity, world_rotation)
	local parent = entity and entity:GetParent()

	if parent and parent:IsValid() and parent.transform then
		entity.transform:SetRotation(get_transform_world_rotation(parent.transform):GetConjugated() * world_rotation)
		return
	end

	entity.transform:SetRotation(world_rotation)
end

local function get_gizmo_definition(entity)
	if not is_gizmo_entity(entity) then return nil end

	local center, extent = get_entity_pivot(entity)

	if not center then return nil end

	local scale = get_gizmo_scale(center, extent)
	return {
		center = center,
		axis_length = scale,
		handle_radius = scale * 0.12,
		ring_radius = scale * 0.8,
		axes = get_gizmo_axes(entity),
	}
end

local function find_hovered_gizmo_handle(entity)
	local gizmo_def = get_gizmo_definition(entity)

	if not gizmo_def then return nil end

	local window = system.GetWindow()

	if not window then return nil end

	local mouse_pos = window:GetMousePosition()
	local best_handle
	local best_distance = math.huge

	if state.mode == "move" then
		for _, axis in ipairs(gizmo_def.axes) do
			local start_screen = project_world_position(gizmo_def.center)
			local stop_screen = project_world_position(gizmo_def.center + axis.direction * gizmo_def.axis_length)

			if start_screen and stop_screen then
				local distance = get_screen_segment_distance(mouse_pos, start_screen, stop_screen)

				if distance < best_distance and distance <= 14 then
					best_distance = distance
					best_handle = {
						kind = "move",
						axis_id = axis.id,
						direction = axis.direction,
						center = gizmo_def.center,
						axis_length = gizmo_def.axis_length,
						start_screen = start_screen,
						stop_screen = stop_screen,
						color = axis.color,
					}
				end
			end
		end

		return best_handle
	end

	for _, axis in ipairs(gizmo_def.axes) do
		local u, v = get_circle_basis(axis.direction)
		local previous_screen = project_world_position(gizmo_def.center + u * gizmo_def.ring_radius)

		for i = 1, 48 do
			local angle = (i / 48) * math.pi * 2
			local point_world = gizmo_def.center + (
					u * math.cos(angle) + v * math.sin(angle)
				) * gizmo_def.ring_radius
			local point_screen = project_world_position(point_world)

			if previous_screen and point_screen then
				local distance = get_screen_segment_distance(mouse_pos, previous_screen, point_screen)

				if distance < best_distance and distance <= 12 then
					best_distance = distance
					best_handle = {
						kind = "rotate",
						axis_id = axis.id,
						direction = axis.direction,
						center = gizmo_def.center,
						radius = gizmo_def.ring_radius,
						center_screen = project_world_position(gizmo_def.center),
						color = axis.color,
					}
				end
			end

			previous_screen = point_screen
		end
	end

	return best_handle
end

local function begin_gizmo_drag(handle)
	local entity = state.gizmo_entity

	if not (handle and is_gizmo_entity(entity)) then return nil end

	local window = system.GetWindow()

	if not window then return nil end

	local mouse_pos = window:GetMousePosition():Copy()

	if handle.kind == "move" then
		local start_screen = handle.start_screen or project_world_position(handle.center)
		local stop_screen = handle.stop_screen or
			project_world_position(handle.center + handle.direction * handle.axis_length)

		if not (start_screen and stop_screen) then return nil end

		local axis_screen = stop_screen - start_screen
		local axis_screen_length = axis_screen:GetLength()

		if axis_screen_length < 1e-5 then return nil end

		return {
			kind = "move",
			axis_id = handle.axis_id,
			entity = entity,
			axis_direction = handle.direction,
			start_mouse_position = mouse_pos,
			axis_screen_direction = axis_screen / axis_screen_length,
			axis_screen_length = axis_screen_length,
			axis_world_length = handle.axis_length,
			start_world_position = get_entity_world_position(entity),
		}
	end

	local center_screen = handle.center_screen or project_world_position(handle.center)

	if not center_screen then return nil end

	local start_mouse_vector = mouse_pos - center_screen
	local start_ring_vector = get_mouse_rotation_ring_vector(handle.center, handle.direction, handle.radius, mouse_pos, center_screen)

	if start_mouse_vector:GetLength() < 1e-5 and not start_ring_vector then
		return nil
	end

	return {
		kind = "rotate",
		axis_id = handle.axis_id,
		entity = entity,
		axis_direction = handle.direction,
		center_screen = center_screen,
		center = handle.center,
		radius = handle.radius,
		start_mouse_vector = start_mouse_vector:GetLength() >= 1e-5 and
			start_mouse_vector:GetNormalized() or
			nil,
		start_ring_vector = start_ring_vector,
		start_world_rotation = get_transform_world_rotation(entity.transform):Copy(),
	}
end

local function finish_gizmo_drag()
	if not state.active_drag then return end

	state.active_drag = nil
	notify_state_changed()
end

local function update_gizmo_drag()
	local drag = state.active_drag

	if not drag then return end

	if not is_gizmo_entity(drag.entity) then
		finish_gizmo_drag()
		return
	end

	if not input.IsMouseDown("button_1") then
		finish_gizmo_drag()
		return
	end

	local window = system.GetWindow()

	if not window then return end

	local mouse_pos = window:GetMousePosition()

	if drag.kind == "move" then
		local mouse_delta = mouse_pos - drag.start_mouse_position
		local offset = mouse_delta:GetDot(drag.axis_screen_direction) / drag.axis_screen_length * drag.axis_world_length

		if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
			offset = math.floor(offset / 0.25 + 0.5) * 0.25
		end

		set_entity_world_position(drag.entity, drag.start_world_position + drag.axis_direction * offset)
		return
	end

	local current_ring_vector = get_mouse_rotation_ring_vector(drag.center, drag.axis_direction, drag.radius, mouse_pos, drag.center_screen)
	local angle

	if drag.start_ring_vector and current_ring_vector then
		angle = math.atan2(
			drag.start_ring_vector.x * current_ring_vector.y - drag.start_ring_vector.y * current_ring_vector.x,
			drag.start_ring_vector:GetDot(current_ring_vector)
		)
	else
		local current_mouse_vector = mouse_pos - drag.center_screen

		if not drag.start_mouse_vector or current_mouse_vector:GetLength() < 1e-5 then
			return
		end

		current_mouse_vector = current_mouse_vector:GetNormalized()
		angle = math.atan2(
			drag.start_mouse_vector.x * current_mouse_vector.y - drag.start_mouse_vector.y * current_mouse_vector.x,
			drag.start_mouse_vector:GetDot(current_mouse_vector)
		)
	end

	if input.IsKeyDown("left_shift") or input.IsKeyDown("right_shift") then
		angle = math.rad(math.floor(math.deg(angle) / 15 + 0.5) * 15)
	end

	local next_world_rotation = (
		build_axis_rotation(drag.axis_direction, angle) * drag.start_world_rotation
	):GetNormalized()
	set_entity_world_rotation(drag.entity, next_world_rotation)
end

local function draw_move_gizmo(gizmo_def)
	for _, axis in ipairs(gizmo_def.axes) do
		local end_position = gizmo_def.center + axis.direction * gizmo_def.axis_length
		local is_hovered = state.hovered_handle and
			state.hovered_handle.kind == "move" and
			state.hovered_handle.axis_id == axis.id
		local is_active = state.active_drag and
			state.active_drag.kind == "move" and
			state.active_drag.axis_id == axis.id
		local color = axis.color

		if is_active then
			color = brighten_color(color, 1.35)
		elseif is_hovered then
			color = brighten_color(color, 1.18)
		end

		debug_draw.DrawLine{
			id = listener_key .. "_move_line_" .. axis.id,
			from = gizmo_def.center,
			to = end_position,
			color = color,
			width = is_active and 3 or 2,
			time = 0.05,
		}
		debug_draw.DrawSphere{
			id = listener_key .. "_move_handle_" .. axis.id,
			position = end_position,
			radius = gizmo_def.handle_radius,
			color = color,
			ignore_z = true,
			time = 0.05,
		}
	end
end

local function draw_rotation_gizmo(gizmo_def)
	for _, axis in ipairs(gizmo_def.axes) do
		local u, v = get_circle_basis(axis.direction)
		local previous = gizmo_def.center + u * gizmo_def.ring_radius
		local is_hovered = state.hovered_handle and
			state.hovered_handle.kind == "rotate" and
			state.hovered_handle.axis_id == axis.id
		local is_active = state.active_drag and
			state.active_drag.kind == "rotate" and
			state.active_drag.axis_id == axis.id
		local color = axis.color

		if is_active then
			color = brighten_color(color, 1.35)
		elseif is_hovered then
			color = brighten_color(color, 1.18)
		end

		for i = 1, 48 do
			local angle = (i / 48) * math.pi * 2
			local current = gizmo_def.center + (
					u * math.cos(angle) + v * math.sin(angle)
				) * gizmo_def.ring_radius
			debug_draw.DrawLine{
				id = string.format("%s_rotate_%s_%d", listener_key, axis.id, i),
				from = previous,
				to = current,
				color = color,
				width = is_active and 3 or 2,
				time = 0.05,
			}
			previous = current
		end
	end
end

local function draw_gizmo()
	local entity = state.gizmo_entity
	local gizmo_def = get_gizmo_definition(entity)

	if not gizmo_def then
		if
			state.gizmo_entity ~= nil or
			state.hovered_handle ~= nil or
			state.active_drag ~= nil
		then
			state.gizmo_entity = nil
			state.hovered_handle = nil
			state.active_drag = nil
			notify_state_changed()
		end

		return
	end

	if entity.model and entity.model.GetWorldAABB then
		debug_draw.DrawWireAABB{
			id = listener_key .. "_aabb",
			aabb = entity.model:GetWorldAABB(),
			color = Color(1, 1, 1, 0.45),
			width = 1,
			time = 0.05,
		}
	end

	debug_draw.DrawSphere{
		id = listener_key .. "_center",
		position = gizmo_def.center,
		radius = gizmo_def.handle_radius * 0.55,
		color = Color(1, 1, 1, 0.9),
		ignore_z = true,
		time = 0.05,
	}

	if state.mode == "move" then
		draw_move_gizmo(gizmo_def)
	else
		draw_rotation_gizmo(gizmo_def)
	end
end

local function draw_overlay()
	if state.gizmo_entity ~= nil then draw_gizmo() end
end

local function update_hovered_handle()
	if state.active_drag then
		update_gizmo_drag()
		return
	end

	state.hovered_handle = find_hovered_gizmo_handle(state.gizmo_entity)
end

function gizmo.EnableGizmo(entity)
	local next_entity = is_gizmo_entity(entity) and entity or nil

	if state.gizmo_entity == next_entity then return next_entity end

	state.gizmo_entity = next_entity
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return next_entity
end

function gizmo.DisableGizmo()
	return gizmo.EnableGizmo(nil)
end

function gizmo.SetMode(mode)
	if mode ~= "move" and mode ~= "rotate" then return state.mode end

	if state.mode == mode then return state.mode end

	state.mode = mode
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return state.mode
end

function gizmo.GetMode()
	return state.mode
end

function gizmo.SetSpace(space)
	if space ~= "local" and space ~= "world" then return state.space end

	if state.space == space then return state.space end

	state.space = space
	state.hovered_handle = nil
	state.active_drag = nil
	notify_state_changed()
	return state.space
end

function gizmo.GetSpace()
	return state.space
end

function gizmo.GetStatus()
	return {
		mode = state.mode,
		space = state.space,
		hovered_handle = state.hovered_handle,
		active_drag = state.active_drag,
		gizmo_entity = state.gizmo_entity,
	}
end

function gizmo.SetStateChangedCallback(owner, callback)
	state.callback_owner = owner
	state.state_changed = callback
end

function gizmo.Clear(owner)
	if owner and state.callback_owner ~= owner then return end

	state.gizmo_entity = nil
	state.hovered_handle = nil
	state.active_drag = nil

	if not owner or state.callback_owner == owner then
		state.callback_owner = nil
		state.state_changed = nil
	end

	notify_state_changed()
end

event.AddListener("Draw3DGeometryOverlay", listener_key, draw_overlay)
event.AddListener("Update", listener_key .. "_update", update_hovered_handle)

event.AddListener("MouseInput", listener_key .. "_mouse", function(button, press)
	if button ~= "button_1" then return end

	if press then
		local drag = begin_gizmo_drag(state.hovered_handle)

		if not drag then return end

		state.active_drag = drag
		state.hovered_handle = nil
		notify_state_changed()
		return true
	end

	if state.active_drag then
		finish_gizmo_drag()
		return true
	end
end)

return gizmo
