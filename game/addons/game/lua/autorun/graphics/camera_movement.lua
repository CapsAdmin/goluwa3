local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local window = import("goluwa/window.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local WALK_GROUND_SPEED = 10
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
local PLAYER_CROUCH_SCALE = 0.5

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function get_speed_multiplier()
	local crouching = input.IsKeyDown("left_control") or input.IsKeyDown("right_control")

	if input.IsKeyDown("left_shift") and crouching then
		return WALK_SUPER_MULTIPLIER
	elseif input.IsKeyDown("left_shift") then
		return WALK_SPRINT_MULTIPLIER
	elseif crouching then
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
local PLAYER_CROUCH_RADIUS = PLAYER_RADIUS * PLAYER_CROUCH_SCALE
local PLAYER_CROUCH_HEIGHT = PLAYER_HEIGHT * PLAYER_CROUCH_SCALE
local PLAYER_CROUCH_EYE_HEIGHT = PLAYER_EYE_HEIGHT * PLAYER_CROUCH_SCALE
local player = Entity.New({Name = "player_controller"})
local player_transform = player:AddComponent("transform")
local player_body = player:AddComponent(
	"rigid_body",
	{
		MotionType = "dynamic",
		Shape = CapsuleShape.New(PLAYER_RADIUS, PLAYER_HEIGHT),
		LinearDamping = 10,
		AirLinearDamping = 0,
		AngularDamping = 40,
		AirAngularDamping = 40,
		Friction = 0,
	}
)
local movement_mode = "fly"
local player_initialized = false
local player_crouched = false
local pitch = 0 -- Track pitch angle for clamping
local function flatten_direction(dir, fallback)
	dir = Vec3(dir.x, 0, dir.z)

	if dir:GetLength() <= 0.0001 then return fallback:Copy() end

	return dir:GetNormalized()
end

local function is_crouch_down()
	return input.IsKeyDown("left_control") or input.IsKeyDown("right_control")
end

local function get_player_dimensions(crouched)
	if crouched then
		return PLAYER_CROUCH_RADIUS, PLAYER_CROUCH_HEIGHT, PLAYER_CROUCH_EYE_HEIGHT
	end

	return PLAYER_RADIUS, PLAYER_HEIGHT, PLAYER_EYE_HEIGHT
end

local function get_player_eye_offset(crouched)
	local _, height, eye_height = get_player_dimensions(crouched)
	return Vec3(0, eye_height - height * 0.5, 0)
end

local function apply_player_crouch(crouched)
	if player_crouched == crouched then return end

	local _, old_height = get_player_dimensions(player_crouched)
	local new_radius, new_height = get_player_dimensions(crouched)
	local velocity = player_body:GetVelocity():Copy()
	local angular_velocity = player_body:GetAngularVelocity():Copy()
	local feet_position = player_body:GetPosition():Copy() - Vec3(0, old_height * 0.5, 0)
	local new_position = feet_position + Vec3(0, new_height * 0.5, 0)

	player_crouched = crouched
	player_body:SetShape(CapsuleShape.New(new_radius, new_height))
	player_transform:SetPosition(new_position)
	player_body:SynchronizeFromTransform()
	player_body.PreviousPosition = player_body.Position:Copy()
	player_body:SetVelocity(velocity)
	player_body:SetAngularVelocity(angular_velocity)
end

local function reset_player_rotation()
	local rotation = Quat()
	rotation:Identity()
	player_transform:SetRotation(rotation)
	player_body:SetRotation(rotation)
	player_body.PreviousRotation = rotation:Copy()
	player_body:SetAngularVelocity(Vec3(0, 0, 0))
end

local function stop_player_horizontal_motion()
	local velocity = player_body:GetVelocity():Copy()
	velocity.x = 0
	velocity.z = 0
	player_body:SetVelocity(velocity)
	player_body:SetAngularVelocity(Vec3(0, 0, 0))
end

local function try_initialize_player(reset_velocity)
	if player_initialized and not reset_velocity then return end

	local cam = render3d.GetCamera()
	local cam_pos = cam:GetPosition():Copy()
	player_transform:SetPosition(cam_pos - get_player_eye_offset(player_crouched))
	reset_player_rotation()
	player_body:SynchronizeFromTransform()
	player_body.PreviousPosition = player_body.Position:Copy()
	player_body:SetGrounded(false)

	if reset_velocity or not player_initialized then
		player_body:SetVelocity(Vec3(0, 0, 0))
		player_body:SetAngularVelocity(Vec3(0, 0, 0))
	end

	player_initialized = true
	cam:SetPosition(player_body:GetPosition() + get_player_eye_offset(player_crouched))
end

local function set_movement_mode(mode)
	movement_mode = mode
	player_body:SetEnabled(mode == "walk")

	if mode == "walk" then
		player_body:SetMotionType("dynamic")
		try_initialize_player(true)
	else
		player_body:SetVelocity(Vec3(0, 0, 0))
		player_body:SetAngularVelocity(Vec3(0, 0, 0))
		player_body:SetGrounded(false)
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
		local cam = render3d.GetCamera()

		if movement_mode == "walk" and not player_initialized then
			try_initialize_player(false)
		end

		if movement_mode == "walk" then
			apply_player_crouch(is_crouch_down())
			cam:SetPosition(player_transform:GetPosition():Copy() + get_player_eye_offset(player_crouched))
		end

		if not window.GetMouseTrapped() then
			if movement_mode == "walk" then
				stop_player_horizontal_motion()
				reset_player_rotation()
			end

			return
		end

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

			position = position + ((forward + right + up) * dt * get_speed_multiplier() * 30)
			cam:SetPosition(position)
		else
			local forward = flatten_direction(rotation:GetForward(), Vec3(0, 0, -1))
			local right = flatten_direction(rotation:GetRight(), Vec3(1, 0, 0))
			local move = Vec3(0, 0, 0)

			if input.IsKeyDown("w") then move = move + forward end

			if input.IsKeyDown("s") then move = move - forward end

			if input.IsKeyDown("a") then move = move - right end

			if input.IsKeyDown("d") then move = move + right end

			if move:GetLength() > 0.0001 then move = move:GetNormalized() end

			local on_ground = player_body:GetGrounded()
			if on_ground then
				local move_speed = on_ground and WALK_GROUND_SPEED or WALK_AIR_SPEED
				local acceleration = on_ground and WALK_ACCELERATION or WALK_AIR_ACCELERATION
				local velocity = player_body:GetVelocity():Copy()
				local horizontal_velocity = approach_vec(
					Vec3(velocity.x, 0, velocity.z),
					move * (move_speed * get_speed_multiplier()),
					acceleration * dt * 10
				)
				velocity.x = horizontal_velocity.x
				velocity.z = horizontal_velocity.z

				if input.WasKeyPressed("space") and on_ground then
					velocity.y = WALK_JUMP_SPEED
					player_body:SetGrounded(false)
				end
				
				player_body:SetVelocity(velocity)
			end
			reset_player_rotation()
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
		cam:SetPosition(player_transform:GetPosition() + get_player_eye_offset(player_crouched))
	end,
	{priority = -100}
)