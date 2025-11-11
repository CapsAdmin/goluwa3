local event = require("event")
local camera = require("graphics.camera")
local input = require("input")
local Vec3 = require("structs.Vec3")
local window = require("window")
local held_ang
local held_mpos
local drag_view = false

local function calc_movement(dt, cam_ang, cam_fov)
	cam_ang:Normalize()
	local speed = dt * 10
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

	if input.IsKeyDown("left_shift") and input.IsKeyDown("left_control") then
		speed = speed * 32
	elseif input.IsKeyDown("left_shift") then
		speed = speed * 8
	elseif input.IsKeyDown("left_control") then
		speed = speed / 4
	end

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

	local forward = Vec3(0, 0, 0)
	local side = Vec3(0, 0, 0)
	local up = Vec3(0, 0, 0)

	if input.IsKeyDown("space") then up = up + cam_ang:GetUp() * speed end

	local offset = cam_ang:GetForward() * speed

	if input.IsKeyDown("w") then
		side = side + offset
	elseif input.IsKeyDown("s") then
		side = side - offset
	end

	offset = cam_ang:GetRight() * speed

	if input.IsKeyDown("a") then
		forward = forward - offset
	elseif input.IsKeyDown("d") then
		forward = forward + offset
	end

	if input.IsKeyDown("left_alt") then
		cam_ang.z = math.rad(math.round(math.deg(cam_ang.z) / 45) * 45)
	end

	if cam_fov > math.rad(90) then
		side = side / ((cam_fov / math.rad(90)) ^ 4)
	else
		side = side / ((cam_fov / math.rad(90)) ^ 0.25)
	end

	return forward + side + up, cam_ang, cam_fov
end

event.AddListener("Update", "camera_movement", function(dt)
	local cam_pos = camera:GetPosition()
	local cam_ang = camera:GetAngles()
	local cam_fov = camera:GetFOV()
	local dir, ang, fov = calc_movement(dt, cam_ang, cam_fov)
	cam_pos = cam_pos + dir
	camera:SetPosition(cam_pos)
	camera:SetAngles(ang)
	camera:SetFOV(fov)
end)
