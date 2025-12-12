local event = require("event")
local input = require("input")
local Vec3 = require("structs.vec3")
local window = require("window")
local render3d = require("graphics.render3d")
local held_ang
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

function events.Update.camera_movement(dt)
	local cam_pos = render3d.GetCameraPosition()
	local cam_ang = render3d.GetCameraAngles()
	local cam_fov = render3d.GetCameraFOV()
	cam_ang:Normalize()
	local speed = dt * get_speed_multiplier()
	local delta = window.GetMouseDelta() / 2
	local r = cam_ang.z
	local cs = math.cos(r)
	local sn = math.sin(r)
	local x = delta.x * cs - delta.y * sn
	local y = delta.x * sn + delta.y * cs
	local original_delta = delta:Copy()
	delta.x = x
	delta.y = y

	if input.IsKeyDown("r") then
		cam_ang.z = 0
		cam_fov = math.rad(75)
	end

	delta = delta * (cam_fov / 175)

	if input.IsKeyDown("left") then
		delta.x = delta.x - speed / 3
	elseif input.IsKeyDown("right") then
		delta.x = delta.x + speed / 3
	end

	if input.IsKeyDown("up") then
		delta.y = delta.y - speed / 3
	elseif input.IsKeyDown("down") then
		delta.y = delta.y + speed / 3
	end

	if input.IsMouseDown("button_2") then
		-- roll
		cam_ang.z = cam_ang.z + original_delta.x / 100
		cam_fov = math.clamp(
			cam_fov + original_delta.y / 100 * (cam_fov / math.pi),
			math.rad(0.1),
			math.rad(175)
		)
	else
		if window.GetMouseTrapped() then
			cam_ang.x = math.clamp(cam_ang.x + delta.y, -math.pi / 2, math.pi / 2)
			cam_ang.y = cam_ang.y - delta.x
		else
			if drag_view then
				held_mpos = held_mpos or window.GetMousePosition()
				local delta = (held_mpos - window.GetMousePosition())
				delta = delta / 300
				held_ang = held_ang or cam_ang:Copy()
				cam_ang.x = math.clamp(held_ang.x - delta.y, -math.pi / 2, math.pi / 2)
				cam_ang.y = held_ang.y + delta.x
			else
				held_mpos = nil
				held_ang = cam_ang:Copy()
			end
		end
	end

	-- ORIENTATION / TRANSFORMATION
	local forward = Vec3(0, 0, 0)
	local right = Vec3(0, 0, 0)
	local up = Vec3(0, 0, 0)
	local offset

	do
		local dir = cam_ang:GetUp()

		if input.IsKeyDown("z") then
			up = up + dir
		elseif input.IsKeyDown("x") then
			up = up - dir
		end
	end

	do
		local dir = cam_ang:GetForward()

		if input.IsKeyDown("w") then
			forward = forward + dir
		elseif input.IsKeyDown("s") then
			forward = forward - dir
		end
	end

	do
		local dir = cam_ang:GetRight()

		if input.IsKeyDown("a") then
			right = right - dir
		elseif input.IsKeyDown("d") then
			right = right + dir
		end
	end

	if input.IsKeyDown("left_alt") then
		cam_ang.z = math.rad(math.round(math.deg(cam_ang.z) / 45) * 45)
	end

	if cam_fov > math.rad(90) then
		right = right / ((cam_fov / math.rad(90)) ^ 4)
	else
		right = right / ((cam_fov / math.rad(90)) ^ 0.25)
	end

	render3d.SetCameraPosition(cam_pos + (forward + right + up) * speed)
	render3d.SetCameraAngles(cam_ang)
	render3d.SetCameraFOV(cam_fov)
end
