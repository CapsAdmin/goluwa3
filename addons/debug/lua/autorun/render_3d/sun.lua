local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weather = import("goluwa/render3d/weather.lua")
local DEGREES_PER_SECOND = 30
local UP = Vec3(0, 1, 0)
local rotation
local home_latitude, home_longitude = weather.GetLocation()
-- what the sun was moved to, as a place and a time on earth: the sun's direction decides the latitude, the date and the
-- time of day (weather.SetSunDirection), and the moon and the stars follow them. Shown while the keys are down
local FADE_IN = 8
local FADE_OUT = 1.5
local HOLD = 1.5
local alpha = 0
local idle = math.huge

event.AddListener("Update", "debug_sun", function(dt)
	local pitch = (input.IsKeyDown("numpad_8") and 1 or 0) - (input.IsKeyDown("numpad_2") and 1 or 0)
	local yaw = (input.IsKeyDown("numpad_6") and 1 or 0) - (input.IsKeyDown("numpad_4") and 1 or 0)

	if pitch == 0 and yaw == 0 then
		rotation = nil
		idle = idle + dt
		alpha = math.max(alpha - (idle > HOLD and FADE_OUT * dt or 0), 0)
		return
	end

	idle = 0
	alpha = math.min(alpha + FADE_IN * dt, 1)

	rotation = rotation or weather.GetSunRotation()

	local step = math.rad(DEGREES_PER_SECOND) * dt
	rotation = QuatFromAxis(yaw * step, UP) * rotation
	rotation:RotatePitch(-pitch * step)
	rotation:Normalize()
	weather.SetSunRotation(rotation)
end)

input.Bind("numpad_5", "sun_reset", function()
	weather.SetLocation(home_latitude, home_longitude)
	weather.SetTime(os.time())
	rotation = nil
	idle = 0
	alpha = 1
end)

if RENDER_2D then
	local render2d = import("goluwa/render2d/render2d.lua")
	local LINE_HEIGHT = 16
	local PADDING = 8
	local WIDTH = 330

	local function format_hours(hours)
		hours = hours % 24

		return string.format("%02d:%02d", math.floor(hours), math.floor((hours % 1) * 60))
	end

	event.AddListener("Draw2D", "debug_sun_info", function()
		if alpha <= 0 then return end

		local time = weather.GetTime()
		local latitude, longitude = weather.GetLocation()
		local direction = weather.GetSunDirection()
		local utc_hours = time % 86400 / 3600
		local lines = {
			string.format("%s UTC", os.date("!%Y-%m-%d %H:%M:%S", math.floor(time))),
			string.format("local solar time %s (day %d of the year)", format_hours(utc_hours + longitude / 15), tonumber(os.date("!%j", math.floor(time)))),
			string.format("latitude %.2f %s, longitude %.2f %s", math.abs(latitude), latitude < 0 and "S" or "N", math.abs(longitude), longitude < 0 and "W" or "E"),
			string.format("sun elevation %.1f, azimuth %.1f", math.deg(math.asin(direction.y)), math.deg(math.atan2(direction.x, -direction.z)) % 360),
		}
		local x, y = 20, 60
		render2d.SetTexture(nil)
		render2d.SetColor(0, 0, 0, 0.7 * alpha)
		render2d.DrawRect(x - PADDING, y - PADDING, WIDTH, #lines * LINE_HEIGHT + PADDING * 2)

		for i, line in ipairs(lines) do
			render2d.DrawText{text = line, x = x, y = y + (i - 1) * LINE_HEIGHT, foreground_color = Color(1, 0.92, 0.6, alpha)}
		end
	end)
end
