local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Gizmo = import("lua/gizmo.lua")

local editor_camera = library()

function editor_camera.Initialize()
	editor_camera.state = {
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
end

function editor_camera.Update(dt, context)
	if not editor_camera.state.enabled then return end

	do
		local camera = render3d.GetCamera()
		local world_size = context.world_size
		local viewport_rect = Rect(0, 0, world_size.x, world_size.y)

		if editor_camera.state.scale_viewport then
			local window_rect = context.window_rect
			local clamped_x = math.clamp(window_rect.x, 0, world_size.x)
			local clamped_y = math.clamp(window_rect.y, 0, world_size.y)
			local clamped_w = math.max(0, math.min(window_rect.w, world_size.x - clamped_x))
			local clamped_h = math.max(0, math.min(window_rect.h, world_size.y - clamped_y))

			if clamped_x <= 0 and clamped_w > 0 then
				viewport_rect.x = math.clamp(clamped_x + clamped_w, 0, world_size.x)
				viewport_rect.w = math.max(1, world_size.x - viewport_rect.x)
			end
		end

		editor_camera.state.viewport_rect = viewport_rect
		camera:SetViewport(viewport_rect)
	end

	local mouse_pos = system.GetWindow():GetMousePosition()
	local gizmo_status = Gizmo.GetStatus()
	local can_drag = context.mouse_in_viewport(mouse_pos) and
		not context.block_movement
	local wants_drag = can_drag and input.IsMouseDown("button_1")

	if editor_camera.state.dragging then
		editor_camera.state.dragging = wants_drag and not gizmo_status.active_drag
	else
		editor_camera.state.dragging = wants_drag and
			not gizmo_status.active_drag and
			not gizmo_status.hovered_handle
	end

	if editor_camera.state.dragging then
		local mouse_delta = system.GetWindow():GetMouseDelta() / 2

		if mouse_delta.x ~= 0 or mouse_delta.y ~= 0 then
			local scaled_delta = mouse_delta * editor_camera.state.mouse_sensitivity
			local new_pitch = math.clamp(editor_camera.state.pitch + scaled_delta.y, editor_camera.state.min_pitch, editor_camera.state.max_pitch)
			local pitch_delta = new_pitch - editor_camera.state.pitch
			local yaw_quat = Quat():Identity()
			yaw_quat:RotateYaw(-scaled_delta.x)
			editor_camera.state.rotation = (yaw_quat * editor_camera.state.rotation:Copy()):GetNormalized()
			editor_camera.state.rotation:RotatePitch(-pitch_delta)
			editor_camera.state.pitch = new_pitch
		end
	end

	if context.block_movement then
		editor_camera.state.velocity = editor_camera.approach_vec(editor_camera.state.velocity, Vec3(), editor_camera.state.acceleration * dt)
	else
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
			move = editor_camera.state.rotation:GetForward() * move_local.z + editor_camera.state.rotation:GetRight() * move_local.x + editor_camera.state.rotation:GetUp() * move_local.y

			if move:GetLength() > 0.0001 then move = move:GetNormalized() end
		end

		local speed = editor_camera.state.speed

		if input.IsKeyDown("left_control") or input.IsKeyDown("right_control") then
			speed = speed * editor_camera.state.slow_multiplier
		end

		if input.IsKeyDown("left_shift") then
			speed = speed * editor_camera.state.sprint_multiplier
		end

		editor_camera.state.velocity = editor_camera.approach_vec(editor_camera.state.velocity, move * speed, editor_camera.state.acceleration * dt)
	end

	editor_camera.state.position = editor_camera.state.position + editor_camera.state.velocity * dt
	local camera = render3d.GetCamera()
	camera:SetPosition(editor_camera.state.position)
	camera:SetRotation(editor_camera.state.rotation)
end

function editor_camera.approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

function editor_camera.SetPitch(p)
	editor_camera.state.pitch = p
end

function editor_camera.SetRotation(r)
	editor_camera.state.rotation = r
end

function editor_camera.SetScaleViewport(v)
	editor_camera.state.scale_viewport = v
end

function editor_camera.IsInsideViewport(pos)
	return editor_camera.state.viewport_rect:IsPosInside(pos)
end

function editor_camera.SetVelocity(vel)
	editor_camera.state.velocity = vel
end

function editor_camera.GetScaleViewport()
	return editor_camera.state.scale_viewport
end

function editor_camera.GetPosition()
	return editor_camera.state.position
end

function editor_camera.SetPosition(pos)
	editor_camera.state.position = pos
end

function editor_camera.GetForward()
	return editor_camera.state.rotation:GetForward()
end

return editor_camera
