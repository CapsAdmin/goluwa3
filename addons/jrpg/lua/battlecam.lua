local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local pvars = import("goluwa/cli/pvars.lua")
local targeting = import("lua/targeting.lua")
local camera_modes = import("lua/camera_modes.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local event = import("goluwa/event.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local U = import("goluwa/source_engine/units.lua").meters
local UP = orientation.UP_VECTOR
local FORWARD = orientation.FORWARD_VECTOR
local RIGHT = orientation.RIGHT_VECTOR
local MAX_DT = 0.1
local CAM_SPEED = 6
local ROOM_SIZE = 200 * U
local MIN_DISTANCE = 60 * U
local START_DISTANCE = 175 * U
local TARGET_SIZE = 150 * U
local FOLLOW_NEAR = 100 * U
local FOLLOW_FAR = 300 * U
local TARGET_BASE_PITCH = 0.3
local TARGET_PITCH_LIMIT = 1
local TRACE_MARGIN = 10 * U
local CHEST = 40 * U
local MAX_ORBIT_PITCH = 1.2
local FREE_FOV = math.rad(60)
local TARGET_FOV = math.rad(50)
local TURN_SPEED = 12
local AIM_LIFT = 0.15
local battlecam = {}
local enabled = false
pvars.Setup2{
	key = "cl_battlecam",
	default = false,
	category = "Game",
	group = "Battle camera",
	friendly = "battle camera",
	help = "jrpg style camera that trails the player and locks on to bodies, client side only",
	callback = function(value)
		battlecam.SetEnabled(value)
	end,
}
local state = {
	origin = Vec3(),
	rotation = Quat():Identity(),
	fov = FREE_FOV,
	roll = 0,
	initialized = false,
	prev_enabled = false,
	cam_away = nil,
	target_pitch = 0,
	mouse_x = 0,
	mouse_y = 0,
	walking = false,
}
local pivot = Vec3()
local target_point = Vec3()

local function blocks_camera(entity, owner, target)
	if entity == owner or entity:ContainsParent(owner) then return false end

	if target and (entity == target or entity:ContainsParent(target)) then
		return false
	end

	if entity.weapon then return false end

	local movement = entity.character_movement

	if movement and movement.latch and movement.latch.Grabber == owner then
		return false
	end

	for _, parent in ipairs(entity:GetParentList()) do
		if parent.weapon then return false end

		movement = parent.character_movement

		if movement and movement.latch and movement.latch.Grabber == owner then
			return false
		end
	end

	return true
end

local pending_target

event.AddListener("KeyInput", "battlecam_target", function(key, press)
	if not enabled or not press then return end

	if key == "insert" or key == "tab" then
		pending_target = "toggle"
	elseif key == "home" or key == "right" then
		pending_target = 1
	elseif key == "pageup" or key == "left" then
		pending_target = -1
	end
end)

event.AddListener("MouseInput", "battlecam_target", function(key, press)
	if enabled and press and key == "button_3" then pending_target = "toggle" end
end)

function battlecam.IsEnabled()
	return enabled
end

function battlecam.SetEnabled(value)
	if enabled and not value then battlecam.Disable() end

	enabled = value
end

function battlecam.IsFirstPerson()
	return false
end

function battlecam.IsHudHidden()
	return false
end

function battlecam.Disable()
	state.prev_enabled = false
	targeting.Clear()
end

function battlecam.AddMouse(delta)
	state.mouse_x = state.mouse_x + delta.x
	state.mouse_y = state.mouse_y + delta.y
end

function battlecam.Update(owner, eye, view_offset, aim, aim_fov, velocity, dt)
	dt = math.min(dt, MAX_DT)
	local feet_y = eye.y - view_offset.y
	pivot:Set(eye.x, feet_y + CHEST, eye.z)

	if not state.initialized or not state.prev_enabled then
		local back = aim:VecMul(FORWARD)
		back.y = 0
		back = back:GetNormalized()
		state.origin = pivot - back * START_DISTANCE + UP * (START_DISTANCE * 0.3)
		state.rotation = Quat():SetLookDirection((pivot - state.origin):GetNormalized())
		state.fov = FREE_FOV
		state.roll = 0
		state.initialized = true
		state.prev_enabled = true
		state.mouse_x, state.mouse_y = 0, 0
	end

	local mouse_x, mouse_y = state.mouse_x, state.mouse_y
	state.mouse_x, state.mouse_y = 0, 0
	targeting.Validate(owner, pivot)

	if pending_target then
		if pending_target == "toggle" then
			targeting.Toggle(owner, pivot, state.rotation)
		else
			targeting.Scroll(owner, pivot, state.rotation, pending_target)
		end

		pending_target = nil
		state.cam_away = nil
		state.target_pitch = 0
	end

	local target = targeting.Get()
	local desired = Vec3()
	local look_at = Vec3()
	local target_fov = FREE_FOV
	local origin = state.origin
	local orbiting = false

	if target then
		target_point:CopyFrom(target:GetPosition())
		local to_target = target_point - pivot
		local distance = to_target:GetLength()
		local flat = math.sqrt(to_target.x * to_target.x + to_target.z * to_target.z)
		local ideal = flat > 1e-4 and
			Vec3(-to_target.x / flat, 0, -to_target.z / flat) or
			aim:VecMul(FORWARD) * -1
		local away = state.cam_away

		if not away then
			away = ideal:Copy()
			state.cam_away = away
		end

		if mouse_x ~= 0 then
			local yaw = Quat():Identity()
			yaw:RotateYaw(-mouse_x)
			away = yaw:VecMul(away)
		end

		local t = math.clamp((flat - FOLLOW_NEAR) / (FOLLOW_FAR - FOLLOW_NEAR), 0, 1)
		local follow = t * t * (3 - 2 * t) * math.min(dt * CAM_SPEED, 1)
		away = away + (ideal - away) * follow
		away.y = 0
		away = away:GetLength() > 1e-4 and away:GetNormalized() or state.cam_away
		state.cam_away = away
		state.target_pitch = math.clamp(state.target_pitch + mouse_y, -TARGET_PITCH_LIMIT, TARGET_PITCH_LIMIT)
		local pitch = TARGET_BASE_PITCH + state.target_pitch
		look_at = pivot + to_target * 0.5
		desired = look_at + away * (
				math.cos(pitch) * (
					TARGET_SIZE + distance * 0.6
				)
			) + UP * (
				math.sin(pitch) * (
					TARGET_SIZE + distance * 0.6
				)
			)
		orbiting = mouse_x ~= 0 or mouse_y ~= 0
		target_fov = TARGET_FOV
	else
		state.cam_away = nil
		local offset = origin - pivot

		if mouse_x ~= 0 or mouse_y ~= 0 then
			local current_pitch = math.asin(math.clamp(offset.y / math.max(offset:GetLength(), 1e-4), -1, 1))
			local pitch = math.clamp(current_pitch + mouse_y, -MAX_ORBIT_PITCH, MAX_ORBIT_PITCH) - current_pitch
			local yaw = Quat():Identity()
			yaw:RotateYaw(-mouse_x)
			local right = yaw:VecMul(state.rotation:VecMul(RIGHT))
			local orbit = Quat():Identity()
			orbit:Rotate(-pitch, right.x, right.y, right.z)
			orbit = orbit * yaw
			offset = orbit:VecMul(offset)
			state.rotation = (orbit * state.rotation):GetNormalized()

			if offset:GetLength() < MIN_DISTANCE then
				offset = offset:GetNormalized() * MIN_DISTANCE
			end

			origin:CopyFrom(pivot + offset)
		end

		local outside = math.max(math.clamp(offset:GetLength() / ROOM_SIZE, 0, 1) ^ 10 - 0.05, 0)
		desired = origin + (pivot - origin) * outside
		look_at:CopyFrom(pivot)
	end

	local k = math.min(dt * CAM_SPEED, 1)

	if orbiting then
		origin:CopyFrom(desired)
		state.rotation = Quat():SetLookDirection((look_at - origin):GetNormalized())
	end

	origin:Set(
		origin.x + (desired.x - origin.x) * k,
		origin.y + (desired.y - origin.y) * k,
		origin.z + (desired.z - origin.z) * k
	)
	local to_origin = origin - pivot
	local length = to_origin:GetLength()

	if length > 1e-4 then
		local hit = raycast.CastClosestSolid(pivot, to_origin / length, length, blocks_camera, owner, target and target.Owner)

		if hit then
			origin:CopyFrom(pivot + to_origin / length * math.max(hit.distance - TRACE_MARGIN, 0))
		end
	end

	local look = look_at - origin
	look = look:GetLength() > 1e-4 and look:GetNormalized() or aim:VecMul(FORWARD)
	state.rotation = state.rotation:Interpolate(Quat():SetLookDirection(look), k)
	state.fov = state.fov + (target_fov - state.fov) * k
	local sideways = velocity:Dot(state.rotation:VecMul(RIGHT)) / U
	local roll = target and math.rad(-5) or math.rad(math.clamp(-sideways * 0.01, -10, 10))
	state.roll = state.roll + (roll - state.roll) * k
	local rotation = state.rotation:Copy()
	rotation:RotateRoll(state.roll)
	return origin, rotation, state.fov, 0.1
end

function battlecam.ApplyMovement(player_input, dt, attacking)
	state.walking = false

	if not enabled then return end

	local current = player_input:GetRotation()
	local forward = current:VecMul(FORWARD)
	local yaw = math.atan2(-forward.x, -forward.z)
	local pitch = math.asin(math.clamp(forward.y, -1, 1))
	local target_yaw
	local target_pitch = 0
	local target = targeting.Get()
	local move = player_input.move_local

	if target then
		local to_target = target:GetPosition() - pivot
		local flat = math.sqrt(to_target.x * to_target.x + to_target.z * to_target.z)
		target_yaw = math.atan2(-to_target.x, -to_target.z)
		target_pitch = math.atan2(to_target.y, math.max(flat, 1e-3))
	elseif move.z ~= 0 or move.x ~= 0 then
		state.walking = true
		local camera_forward = state.rotation:VecMul(FORWARD)
		local flat = math.sqrt(camera_forward.x * camera_forward.x + camera_forward.z * camera_forward.z)

		if flat < 1e-3 then return end

		local fx, fz = camera_forward.x / flat, camera_forward.z / flat
		target_yaw = math.atan2(-(fx * move.z + -fz * move.x), -(fz * move.z + fx * move.x))
	elseif attacking then
		local camera_forward = state.rotation:VecMul(FORWARD)
		target_yaw = math.atan2(-camera_forward.x, -camera_forward.z)
		target_pitch = math.asin(math.clamp(camera_forward.y, -1, 1)) + AIM_LIFT
	else
		target_yaw = yaw
	end

	local k = math.min(dt * TURN_SPEED, 1)
	local difference = (target_yaw - yaw + math.pi) % (math.pi * 2) - math.pi
	pitch = pitch + (target_pitch - pitch) * k
	local result = Quat():Identity()
	result:RotateYaw(yaw + difference * k)
	result:RotatePitch(pitch)
	player_input:SetRotation(result)
	player_input:SetPitch(pitch)
end

function battlecam.AdjustCommand(cmd)
	if not (enabled and state.walking) then return end

	cmd.forward = math.min(math.sqrt(cmd.forward * cmd.forward + cmd.side * cmd.side), 1)
	cmd.side = 0
end

camera_modes.Register(battlecam)
return battlecam
