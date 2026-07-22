local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local Quat = import("goluwa/structs/quat.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Gizmo = import("lua/gizmo.lua")
local camera = library()
camera.position = Vec3()
camera.rotation = Quat():Identity()
camera.pitch = 0
camera.velocity = Vec3()
camera.mouse_sensitivity = 0.0075
camera.min_pitch = -math.pi / 2 + 0.01
camera.max_pitch = math.pi / 2 - 0.01
camera.speed = 18
camera.sprint_multiplier = 2.25
camera.acceleration = 220
camera.slow_multiplier = 0.2
camera.block_movement = false
camera.block_dragging = false

function camera.SetBlockMovement(b)
	camera.block_movement = b
end

function camera.SetBlockDragging(b)
	camera.block_dragging = b
end

function camera.SetPosition(pos)
	camera.position = pos
end

function camera.GetPosition()
	return camera.position
end

function camera.SetRotation(r)
	camera.rotation = r
end

function camera.GetRotation()
	return camera.rotation
end

function camera.Update(dt)
	if not camera.block_dragging and input.IsMouseDown("button_1") then
		local mouse_delta = system.GetWindow():GetMouseDelta() / 2

		if mouse_delta.x ~= 0 or mouse_delta.y ~= 0 then
			local scaled_delta = mouse_delta * camera.mouse_sensitivity
			local new_pitch = math.clamp(camera.pitch + scaled_delta.y, camera.min_pitch, camera.max_pitch)
			local pitch_delta = new_pitch - camera.pitch
			local yaw_quat = Quat():Identity()
			yaw_quat:RotateYaw(-scaled_delta.x)
			camera.rotation = (yaw_quat * camera.rotation):GetNormalized()
			camera.rotation:RotatePitch(-pitch_delta)
			camera.pitch = new_pitch
		end
	end

	if not camera.block_movement then
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
			move = camera.rotation:GetForward() * move_local.z + camera.rotation:GetRight() * move_local.x + camera.rotation:GetUp() * move_local.y

			if move:GetLength() > 0.0001 then move = move:GetNormalized() end
		end

		local speed = camera.speed

		if input.IsControlDown() then speed = speed * camera.slow_multiplier end

		if input.IsShiftDown() then speed = speed * camera.sprint_multiplier end

		camera.velocity = camera.velocity:Approach(move * speed, camera.acceleration * dt)
	else
		camera.velocity = camera.velocity:Approach(Vec3(), camera.acceleration * dt)
	end

	camera.position = camera.position + camera.velocity * dt
end

return camera
