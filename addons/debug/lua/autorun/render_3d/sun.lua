local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local weather = import("goluwa/render3d/weather.lua")
local HOURS_PER_SECOND = 1

event.AddListener("Update", "debug_sun", function(dt)
	if input.IsKeyDown("u") or input.IsKeyDown("i") then
		weather.ClearSunRotation()
		weather.SetTime(
			weather.GetTime() + dt * HOURS_PER_SECOND * 3600 * (
					input.IsKeyDown("i") and
					1 or
					-1
				)
		)
		return
	end

	local rot = weather.GetSunRotation()

	if input.IsKeyDown("m") then
		rot:RotateYaw(dt)
	elseif input.IsKeyDown(",") then
		rot:RotateYaw(-dt)
	elseif input.IsKeyDown("k") then
		rot:RotatePitch(dt)
	elseif input.IsKeyDown("l") then
		rot:RotatePitch(-dt)
	else
		return
	end

	weather.SetSunRotation(rot)
end)
