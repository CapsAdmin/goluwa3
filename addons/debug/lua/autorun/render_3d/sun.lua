local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weather = import("goluwa/render3d/weather.lua")
local DEGREES_PER_SECOND = 30
local UP = Vec3(0, 1, 0)
local RESYNC_DOT = math.cos(math.rad(1))
local rotation

event.AddListener("Update", "debug_sun", function(dt)
	local pitch = (input.IsKeyDown("k") and 1 or 0) - (input.IsKeyDown("l") and 1 or 0)
	local yaw = (input.IsKeyDown("period") and 1 or 0) - (input.IsKeyDown("comma") and 1 or 0)

	if pitch == 0 and yaw == 0 then return end

	if
		not rotation or
		rotation:GetBackward():GetDot(weather.GetSunDirection()) < RESYNC_DOT
	then
		rotation = weather.GetSunRotation()
	end

	local step = math.rad(DEGREES_PER_SECOND) * dt
	rotation = QuatFromAxis(yaw * step, UP) * rotation
	rotation:RotatePitch(-pitch * step)
	rotation:Normalize()
	weather.SetSunRotation(rotation)
end)
