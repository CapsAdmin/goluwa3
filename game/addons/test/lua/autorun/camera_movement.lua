local event = require("event")
local input = require("input")
local Vec3 = require("structs.vec3")
local Matrix44 = require("structs.matrix").Matrix44
local Quat = require("structs.quat")
local window = require("window")
local render3d = require("graphics.render3d")
local orientation = require("orientation")
local held_rot
local held_mpos
local drag_view = false

local function get_speed_multiplier()
	if input.IsKeyDown("left_shift") and input.IsKeyDown("left_control") then
		return 32
	elseif input.IsKeyDown("left_shift") then
		return 8
	elseif input.IsKeyDown("left_control") then
		return 0.25
	end

	return 10
end

do
	local Vec3 = require("structs.vec3")
	local ecs = require("ecs")
	local Ang3 = require("structs.ang3")
	local Polygon3D = require("graphics.polygon_3d")
	local Material = require("graphics.material")

	function events.KeyInput.camera_movement(key, down)
		if key == "o" and down then
			local poly = Polygon3D.New()
			poly:CreateCube(1.0, 1.0)
			poly:AddSubMesh(#poly.Vertices)
			poly:BuildNormals()
			poly:BuildBoundingBox()
			poly:Upload()
			local entity = ecs.CreateEntity("cube", ecs.GetWorld())
			entity:AddComponent(
				"transform",
				{
					position = DEBUG_CAMERA_POS,
					scale = Vec3(1, 1, 1) * 0.1,
				}
			)
			entity:AddComponent(
				"model",
				{
					mesh = poly,
					material = Material.New({base_color_factor = {1, 0.2, 0.2, 1}}),
				}
			)
		end
	end
end

-- Use quaternion for rotation to avoid gimbal lock
local rotation = Quat()
rotation:Identity()
local position = Vec3(0, 0, 0)
local pitch = 0 -- Track pitch angle for clamping
function events.Update.camera_movement(dt)
	local cam_fov = render3d.GetCameraFOV()
	local speed = dt * get_speed_multiplier()
	local mouse_delta = window.GetMouseDelta() / 2 -- Mouse sensitivity
	if input.IsKeyDown("r") then
		rotation:Identity()
		position:Set(0, 0, 0)
		pitch = 0
		cam_fov = math.rad(75)
	end

	mouse_delta = mouse_delta * (cam_fov / 175)

	if input.IsKeyDown("left") then
		mouse_delta.x = mouse_delta.x - speed / 30
	elseif input.IsKeyDown("right") then
		mouse_delta.x = mouse_delta.x + speed / 30
	end

	if input.IsKeyDown("up") then
		mouse_delta.y = mouse_delta.y - speed / 30
	elseif input.IsKeyDown("down") then
		mouse_delta.y = mouse_delta.y + speed / 30
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
		local new_pitch = pitch - mouse_delta.y
		new_pitch = math.clamp(new_pitch, -math.pi / 2 + 0.01, math.pi / 2 - 0.01)
		local pitch_delta = new_pitch - pitch
		pitch = new_pitch
		local yaw_quat = Quat()
		yaw_quat:Identity()
		yaw_quat:RotateYaw(-mouse_delta.x)
		rotation = yaw_quat * rotation
		rotation:RotatePitch(pitch_delta)
	end

	-- ORIENTATION / TRANSFORMATION: Use quaternion directions for movement
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
			right = right + dir
		elseif input.IsKeyDown("d") then
			right = right - dir
		end
	end

	if cam_fov > math.rad(90) then
		right = right / ((cam_fov / math.rad(90)) ^ 4)
	else
		right = right / ((cam_fov / math.rad(90)) ^ 0.25)
	end

	position = position + ((forward + right + up) * speed)
	-- Convert quaternion to matrix and apply translation
	local view = rotation:GetMatrix()
	view:Translate(position:Unpack())
	render3d.SetViewMatrix(view)
	render3d.SetCameraFOV(cam_fov)
	DEBUG_CAMERA_POS = -position
	DEBUG_CAMERA_ROT = rotation
end
