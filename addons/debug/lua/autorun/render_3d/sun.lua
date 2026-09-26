local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local weather = import("goluwa/render3d/weather.lua")
local HOURS_PER_SECOND = 4

event.AddListener("Update", "debug_sun", function(dt)
	if input.IsKeyDown("k") or input.IsKeyDown("l") then
		weather.ClearSunRotation()
		weather.SetTime(
			weather.GetTime() + dt * HOURS_PER_SECOND * 3600 * (
					input.IsKeyDown("k") and
					1 or
					-1
				)
		)
	end
end)
