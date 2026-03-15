local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local window = import("goluwa/window.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local WALK_GROUND_SPEED = 1
local WALK_AIR_SPEED = 3.8
local WALK_SPRINT_MULTIPLIER = 1.75
local WALK_CROUCH_MULTIPLIER = 0.45
local WALK_SUPER_MULTIPLIER = 3
local WALK_GROUND_SNAP_DISTANCE = 0.08
local WALK_STEP_HEIGHT = 0.35
local WALK_ACCELERATION = 45
local WALK_AIR_ACCELERATION = 18
local WALK_JUMP_SPEED = 8
local WALK_GROUND_PROBE_DISTANCE = 0.2

local function get_speed_multiplier()
	if input.IsKeyDown("left_shift") and input.IsKeyDown("left_control") then
		return WALK_SUPER_MULTIPLIER
	elseif input.IsKeyDown("left_shift") then
		return WALK_SPRINT_MULTIPLIER
	elseif input.IsKeyDown("left_control") then
		return WALK_CROUCH_MULTIPLIER
	end

	return 1
end

do
	event.AddListener("KeyInput", "camera_movement", function(key, down)
		if key == "o" and down then
			render3d.GetCamera():SetOrthoMode(not render3d.GetCamera():GetOrthoMode())
		end
	end)
end

local PLAYER_EYE_HEIGHT = 1.75
local PLAYER_RADIUS = 0.35
local PLAYER_HEIGHT = 2
local PLAYER_BODY_TO_EYE_OFFSET = Vec3(0, PLAYER_EYE_HEIGHT - PLAYER_HEIGHT * 0.5, 0)
local PLAYER_SUPPORT_LOCAL = Vec3(0, -(PLAYER_HEIGHT * 0.5 - PLAYER_RADIUS), 0)
local player = Entity.New({Name = "player_controller"})
local player_transform = player:AddComponent("transform")
local player_body = player:AddComponent(
	"rigid_body",
	{
		MotionType = "kinematic",
		Shape = CapsuleShape.New(PLAYER_RADIUS, PLAYER_HEIGHT),
		LinearDamping = 14,
	}
)
local player_motion = player:AddComponent(
	"kinematic_controller",
	{
		GroundSnapDistance = WALK_GROUND_SNAP_DISTANCE,
		StepHeight = WALK_STEP_HEIGHT,
		Acceleration = WALK_ACCELERATION,
		AirAcceleration = WALK_AIR_ACCELERATION,
	}
)
local movement_mode = "fly"
local player_initialized = false
local pitch = 0 -- Track pitch angle for clamping
local function flatten_direction(dir, fallback)
	dir = Vec3(dir.x, 0, dir.z)

	if dir:GetLength() <= 0.0001 then return fallback:Copy() end

	return dir:GetNormalized()
end

local function try_initialize_player(reset_velocity)
	if player_initialized and not reset_velocity then return end

	local cam = render3d.GetCamera()
	local cam_pos = cam:GetPosition():Copy()
	player_transform:SetPosition(cam_pos - PLAYER_BODY_TO_EYE_OFFSET)
	player_body:SynchronizeFromTransform()
	player_body.PreviousPosition = player_body.Position:Copy()
	player_body.PreviousRotation = player_body.Rotation:Copy()

	if reset_velocity or not player_initialized then
		player_body:SetVelocity(Vec3(0, 0, 0))
		player_body:SetAngularVelocity(Vec3(0, 0, 0))
		player_motion:SetVelocity(Vec3(0, 0, 0))
		player_motion:SetDesiredVelocity(Vec3(0, 0, 0))
	end

	player_initialized = true
	cam:SetPosition(player_body:GetPosition() + PLAYER_BODY_TO_EYE_OFFSET)
end

local function set_movement_mode(mode)
	movement_mode = mode
	player_body:SetEnabled(mode == "walk")

	if mode == "walk" then
		player_body:SetMotionType("kinematic")
		player_motion:EnsureKinematicBody()
		try_initialize_player(true, false)
	else
		player_body:SetVelocity(Vec3(0, 0, 0))
		player_motion:SetVelocity(Vec3(0, 0, 0))
		player_motion:SetDesiredVelocity(Vec3(0, 0, 0))
	end
end

event.AddListener("KeyInput", "camera_movement_mode", function(key, down)
	if key ~= "v" or not down then return end

	if movement_mode == "fly" then
		set_movement_mode("walk")
	else
		set_movement_mode("fly")
	end
end)

set_movement_mode(movement_mode)

event.AddListener(
	"Update",
	"camera_movement_input",
	function(dt)
		if movement_mode == "walk" and not player_initialized then
			try_initialize_player(false, false)
		end

		if not window.GetMouseTrapped() then
			player_motion:SetDesiredVelocity(Vec3(0, 0, 0))
			return
		end

		local cam = render3d.GetCamera()
		local rotation = cam:GetRotation()
		local position = cam:GetPosition()
		local cam_fov = cam:GetFOV()
		local mouse_delta = window.GetMouseDelta() / 2 -- Mouse sensitivity
		if input.IsKeyDown("r") then
			rotation:Identity()
			pitch = 0
			cam_fov = math.rad(90)

			if movement_mode == "walk" then try_initialize_player(true, false) end
		end

		mouse_delta = mouse_delta * (cam_fov / 175)

		if input.IsKeyDown("left") then
			mouse_delta.x = mouse_delta.x - dt
		elseif input.IsKeyDown("right") then
			mouse_delta.x = mouse_delta.x + dt
		end

		if input.IsKeyDown("up") then
			mouse_delta.y = mouse_delta.y - dt
		elseif input.IsKeyDown("down") then
			mouse_delta.y = mouse_delta.y + dt
		end

		if input.IsMouseDown("button_2") then
			-- Roll with right mouse button
			rotation:RotateRoll(mouse_delta.x)
			cam_fov = math.clamp(
				cam_fov + mouse_delta.y * 10 * (cam_fov / math.pi),
				math.rad(0.1),
				math.rad(175)
			)
		elseif window.GetMouseTrapped() then
			-- Clamp pitch to prevent camera flip
			local new_pitch = pitch + mouse_delta.y
			new_pitch = math.clamp(new_pitch, -math.pi / 2 + 0.01, math.pi / 2 - 0.01)
			local pitch_delta = new_pitch - pitch
			pitch = new_pitch
			local yaw_quat = Quat()
			yaw_quat:Identity()
			yaw_quat:RotateYaw(-mouse_delta.x)
			rotation = yaw_quat * rotation
			rotation:RotatePitch(-pitch_delta)
		end

		if movement_mode == "fly" then
			local forward = Vec3(0, 0, 0)
			local right = Vec3(0, 0, 0)
			local up = Vec3(0, 0, 0)

			do
				local dir = rotation:GetUp()

				if input.IsKeyDown("z") then
					up = up - dir
				elseif input.IsKeyDown("x") then
					up = up + dir
				end
			end

			do
				local dir = rotation:GetForward()

				if input.IsKeyDown("w") then
					forward = forward + dir
				elseif input.IsKeyDown("s") then
					forward = forward - dir
				end
			end

			do
				local dir = rotation:GetRight()

				if input.IsKeyDown("a") then
					right = right - dir
				elseif input.IsKeyDown("d") then
					right = right + dir
				end
			end

			if cam_fov > math.rad(90) then
				right = right / ((cam_fov / math.rad(90)) ^ 4)
			else
				right = right / ((cam_fov / math.rad(90)) ^ 0.25)
			end

			position = position + ((forward + right + up) * dt * get_speed_multiplier() * 5)
			cam:SetPosition(position)
			player_motion:SetDesiredVelocity(Vec3(0, 0, 0))
		else
			local forward = flatten_direction(rotation:GetForward(), Vec3(0, 0, -1))
			local right = flatten_direction(rotation:GetRight(), Vec3(1, 0, 0))
			local move = Vec3(0, 0, 0)

			if input.IsKeyDown("w") then move = move + forward end

			if input.IsKeyDown("s") then move = move - forward end

			if input.IsKeyDown("a") then move = move - right end

			if input.IsKeyDown("d") then move = move + right end

			if move:GetLength() > 0.0001 then move = move:GetNormalized() end

			local grounded_for_input = player_body:GetGrounded()
			local move_speed = grounded_for_input and WALK_GROUND_SPEED or WALK_AIR_SPEED
			player_motion:SetDesiredVelocity(move * (move_speed * get_speed_multiplier()))

			if input.WasKeyPressed("space") and grounded_for_input then
				local velocity = player_body:GetVelocity():Copy()
				velocity.y = WALK_JUMP_SPEED
				player_body:SetVelocity(velocity)
				player_motion:SetVelocity(velocity)
				player_body:SetGrounded(false)
			end
		end

		cam:SetFOV(cam_fov)
		cam:SetRotation(rotation)
	end,
	{priority = 100}
)

event.AddListener(
	"Update",
	"camera_movement_camera",
	function()
		if movement_mode ~= "walk" or not player_initialized then return end

		local cam = render3d.GetCamera()
		cam:SetPosition(player_transform:GetPosition():Copy() + PLAYER_BODY_TO_EYE_OFFSET)
	end,
	{priority = -100}
)