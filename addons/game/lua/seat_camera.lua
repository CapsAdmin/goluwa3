local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local event = import("goluwa/event.lua")
local camera_modes = import("lua/camera_modes.lua")
local outfit = import("lua/outfit.lua")
local seat_camera = {Priority = 100}
local MAX_PITCH = 1.4
local MAX_DT = 0.05
local ZOOM_STEP = 1.2
local MIN_DISTANCE = 1.5
local MAX_DISTANCE = 40
local HEADING_FOLLOW = 3
local DOWN_PITCH = -0.2
local NEAR_Z = 0.05
local BLOCK_RADIUS = 0.2
local BLOCK_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = true}
local state = {
	yaw = 0,
	pitch = 0,
	heading = nil,
	distance = nil,
	seat = nil,
	look = Quat(0, 0, 0, 1),
}
local seat_position = Vec3()
local seat_rotation = Quat()

local function get_seat()
	local rig = _G.PLAYER_RIG
	return rig and rig:IsValid() and rig.character_pose:GetSeatComponent()
end

local function is_static_geometry(entity)
	local body = entity.rigid_body
	return body ~= nil and body:IsStatic()
end

local function heading_of(rotation)
	local forward = rotation:GetForward()
	return math.atan2(-forward.x, -forward.z)
end

function seat_camera.IsEnabled()
	return get_seat() ~= nil
end

function seat_camera.IsFirstPerson()
	return state.distance == 0
end

function seat_camera.Disable()
	state.seat = nil
end

function seat_camera.AddMouse(delta)
	state.yaw = state.yaw - delta.x
	state.pitch = math.clamp(state.pitch - delta.y, -MAX_PITCH, MAX_PITCH)
end

event.AddListener("MouseInput", "seat_camera_zoom", function(key, press)
	if not press or not seat_camera.IsEnabled() then return end

	local distance = state.distance or 0

	if key == "mwheel_down" then
		distance = distance == 0 and MIN_DISTANCE or math.min(distance * ZOOM_STEP, MAX_DISTANCE)
	elseif key == "mwheel_up" then
		distance = distance <= MIN_DISTANCE and 0 or distance / ZOOM_STEP
	else
		return
	end

	state.distance = distance
end)

function seat_camera.Update(owner, eye, view_offset, aim, aim_fov, velocity, dt)
	dt = math.min(dt, MAX_DT)
	local seat = owner.character_pose:GetSeatComponent()
	seat:GetRenderFrame(seat_position, seat_rotation)

	if state.seat ~= seat then
		state.seat = seat
		state.yaw = 0
		state.pitch = 0
		state.heading = heading_of(seat_rotation)
		state.distance = state.distance or seat:GetCameraDistance()
	end

	local eye_position = seat_position + seat:GetEyeOffset(seat_rotation)

	if state.distance == 0 then
		local look = state.look:Identity():RotateYaw(state.yaw):RotatePitch(state.pitch)
		local avatar = owner.player_avatar
		local near_z = NEAR_Z

		if avatar and avatar:IsHeadCameraActive() then
			eye_position = eye_position + avatar:GetHeadOffset()
			near_z = outfit.GetHeadNear()
		end

		return eye_position, seat_rotation * look, aim_fov, near_z
	end

	local target = heading_of(seat_rotation)
	local difference = (target - state.heading + math.pi) % (math.pi * 2) - math.pi
	state.heading = state.heading + difference * math.min(dt * HEADING_FOLLOW, 1)
	local rotation = state.look:Identity():RotateYaw(state.heading + state.yaw):RotatePitch(math.clamp(state.pitch + DOWN_PITCH, -MAX_PITCH, MAX_PITCH))
	local pivot = seat_position + Vec3(0, seat:GetCameraHeight(), 0)
	local back = rotation:GetBackward()
	local distance = state.distance
	local hit = physics.Sweep(pivot, back * distance, BLOCK_RADIUS, owner, is_static_geometry, BLOCK_OPTIONS)

	if hit then distance = math.max(hit.distance, 0.3) end

	return pivot + back * distance, rotation:Copy(), aim_fov, NEAR_Z
end

function seat_camera.ApplyMovement(player_input, dt, attacking)
	local seat = get_seat()

	if not seat or state.seat ~= seat then return end

	seat:GetRenderFrame(seat_position, seat_rotation)
	local look = Quat():Identity():RotateYaw(state.yaw):RotatePitch(state.pitch)

	if state.distance ~= 0 then
		look = Quat():Identity():RotateYaw(state.heading + state.yaw - heading_of(seat_rotation)):RotatePitch(state.pitch)
	end

	local rotation = seat_rotation * look
	local forward = rotation:GetForward()
	local view = Quat():Identity():RotateYaw(math.atan2(-forward.x, -forward.z)):RotatePitch(math.asin(math.clamp(forward.y, -1, 1)))
	player_input:SetRotation(view)
	player_input:SetPitch(-math.asin(math.clamp(forward.y, -1, 1)))
end

function seat_camera.AdjustCommand(cmd) end

camera_modes.Register(seat_camera)
return seat_camera
