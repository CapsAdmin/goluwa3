local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local weather = import("goluwa/render3d/weather.lua")
local WIDTH = 604
local HEIGHT = 412
local DOME_X, DOME_Y, DOME_RADIUS, DOME_MARGIN = 142, 150, 108, 22
local COLUMN_X, COLUMN_W = 292, 300
local CHART_Y, CHART_H = 34, 130
local YEAR_Y, YEAR_H = 218, 28
local LATITUDE_Y, LATITUDE_H = 294, 28
local MOON_Y, MOON_H = 370, 28
local CHART_MIN, CHART_MAX = -60, 90
local SAMPLES = 48
local SYNODIC_DAYS = 29.530588
local MONTHS = {"J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"}
local MONTH_STARTS = {1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366}
local TEXT = Color(0.78, 0.82, 0.9, 1)
local TEXT_DIM = Color(0.5, 0.55, 0.65, 1)
local SUN_COLOR = Color(1, 0.82, 0.35, 1)
local MOON_COLOR = Color(0.72, 0.8, 1, 1)
local cache_key
local sun_dx, sun_dy, sun_dz = {}, {}, {}
local moon_dx, moon_dy, moon_dz = {}, {}, {}
local noon_key
local noon_elevation = {}

local function rect(x, y, w, h, r, g, b, a, radius)
	render2d.SetColor(r, g, b, a)
	render2d.DrawRoundedRect(x, y, w, h, radius or 0)
end

local function label(text, x, y, color)
	render2d.DrawText{text = text, x = x, y = y, size = 12, foreground_color = color or TEXT_DIM}
end

local function wrap(value)
	return (value + 0.5) % 1 - 0.5
end

local function get_lunar_state()
	local time = weather.GetTime()
	local latitude, longitude = weather.GetLocation()
	local sun = weather.GetSunDirectionAt(time, latitude, longitude)
	local moon = weather.GetMoonAt(time, latitude, longitude)
	local elongation = math.acos(math.clamp(sun:GetDot(moon), -1, 1))
	local later = math.acos(
		math.clamp(
			weather.GetSunDirectionAt(time + 21600, latitude, longitude):GetDot(weather.GetMoonAt(time + 21600, latitude, longitude)),
			-1,
			1
		)
	)
	local waxing = later > elongation
	return elongation, waxing, waxing and elongation / (2 * math.pi) or 1 - elongation / (2 * math.pi), moon
end

local function get_phase_name(phase)
	if phase < 0.03 or phase > 0.97 then return "new moon" end

	if phase < 0.22 then return "waxing crescent" end

	if phase < 0.28 then return "first quarter" end

	if phase < 0.47 then return "waxing gibbous" end

	if phase < 0.53 then return "full moon" end

	if phase < 0.72 then return "waning gibbous" end

	if phase < 0.78 then return "last quarter" end

	return "waning crescent"
end

local function draw_moon(x, y, radius, elongation, waxing, alpha)
	render2d.SetColor(0.1, 0.12, 0.18, alpha)
	render2d.DrawFilledCircle(x, y, radius)
	render2d.SetColor(0.86, 0.9, 1, alpha)
	local cos_e = math.cos(elongation)
	local step = 1
	local row = -radius

	while row < radius do
		local mid = row + step / 2
		local half = math.sqrt(math.max(radius * radius - mid * mid, 0))
		local terminator = half * cos_e
		local x0, x1 = terminator, half

		if not waxing then x0, x1 = -half, -terminator end

		if x1 > x0 then render2d.DrawRect(x + x0, y + row, x1 - x0, step + 0.3) end

		row = row + step
	end
end

local function update_cache()
	local latitude, longitude = weather.GetLocation()
	local time = weather.GetTime()
	local solar_day = math.floor((time + longitude * 240) / 86400)
	local key = solar_day .. ":" .. latitude .. ":" .. longitude

	if key ~= cache_key then
		cache_key = key
		local base = time - weather.GetSolarHours() * 3600

		for i = 0, SAMPLES do
			local t = base + i / SAMPLES * 86400
			local sun = weather.GetSunDirectionAt(t, latitude, longitude)
			local moon = weather.GetMoonAt(t, latitude, longitude)
			sun_dx[i], sun_dy[i], sun_dz[i] = sun.x, sun.y, sun.z
			moon_dx[i], moon_dy[i], moon_dz[i] = moon.x, moon.y, moon.z
		end
	end

	local year_key = math.floor(time / (365.25 * 86400)) .. ":" .. latitude

	if year_key ~= noon_key then
		noon_key = year_key
		local noon = time + (12 - weather.GetSolarHours()) * 3600 - weather.GetDayOfYear() * 86400

		for i = 0, 24 do
			local peak = -1

			for half_hour = -6, 6 do
				peak = math.max(peak, weather.GetSunDirectionAt(noon + (1 + i * 15) * 86400 + half_hour * 1800, latitude, longitude).y)
			end

			noon_elevation[i] = math.deg(math.asin(peak))
		end
	end
end

local function dome_point(x, y, z)
	local elevation = math.deg(math.asin(math.clamp(y, -1, 1)))
	local azimuth = math.atan2(x, -z)
	local radius = elevation >= 0 and
		DOME_RADIUS * (1 - elevation / 90) or
		DOME_RADIUS - elevation / 90 * DOME_MARGIN
	return DOME_X + math.sin(azimuth) * radius, DOME_Y - math.cos(azimuth) * radius, elevation, azimuth
end

local function chart_y(elevation)
	return CHART_Y + CHART_H * (1 - (math.clamp(elevation, CHART_MIN, CHART_MAX) - CHART_MIN) / (CHART_MAX - CHART_MIN))
end

local REGIONS = {
	{name = "dome", x = DOME_X - DOME_RADIUS - DOME_MARGIN, y = DOME_Y - DOME_RADIUS - DOME_MARGIN, w = (DOME_RADIUS + DOME_MARGIN) * 2, h = (DOME_RADIUS + DOME_MARGIN) * 2},
	{name = "time", x = COLUMN_X, y = CHART_Y, w = COLUMN_W, h = CHART_H},
	{name = "day", x = COLUMN_X, y = YEAR_Y, w = COLUMN_W, h = YEAR_H},
	{name = "latitude", x = COLUMN_X, y = LATITUDE_Y, w = COLUMN_W, h = LATITUDE_H},
	{name = "moon", x = COLUMN_X, y = MOON_Y, w = COLUMN_W, h = MOON_H},
}

local META = Panel:CreateTemplate("sky_dial")
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 0, FitWidth = false, FitHeight = false}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function META:IsDragging()
	return self._drag ~= nil
end

function META:drag_to(local_pos)
	local drag = self._drag
	local x, y = local_pos.x, local_pos.y

	if drag == "dome" then
		local dx, dy = x - DOME_X, DOME_Y - y
		local radius = math.sqrt(dx * dx + dy * dy)
		local azimuth = math.atan2(dx, dy)
		local elevation = radius <= DOME_RADIUS and
			90 * (1 - radius / DOME_RADIUS) or
			-math.min((radius - DOME_RADIUS) / DOME_MARGIN, 1) * 90
		elevation = math.rad(elevation)
		weather.SetSunDirection(
			Vec3(
				math.sin(azimuth) * math.cos(elevation),
				math.sin(elevation),
				-math.cos(azimuth) * math.cos(elevation)
			)
		)
	elseif drag == "time" then
		weather.SetSolarHours(math.clamp((x - COLUMN_X) / COLUMN_W, 0, 1) * 24)
	elseif drag == "day" then
		weather.SetDayOfYear(1 + math.clamp((x - COLUMN_X) / COLUMN_W, 0, 1) * 365)
	elseif drag == "latitude" then
		weather.SetLocation(-90 + math.clamp((x - COLUMN_X) / COLUMN_W, 0, 1) * 180, select(2, weather.GetLocation()))
	elseif drag == "moon" then
		local _, _, phase = get_lunar_state()
		local target = math.clamp((x - COLUMN_X) / COLUMN_W, 0, 1)
		weather.SetTime(weather.GetTime() + wrap(target - phase) * SYNODIC_DAYS * 86400)
	end
end

function META:OnMouseInput(button, press, local_pos)
	if button ~= "button_1" then return end

	if press then
		for _, region in ipairs(REGIONS) do
			if
				local_pos.x >= region.x and
				local_pos.x <= region.x + region.w and
				local_pos.y >= region.y - 4 and
				local_pos.y <= region.y + region.h + 4
			then
				self._drag = region.name
				self:drag_to(local_pos)

				break
			end
		end
	end

	return true
end

function META:OnGlobalMouseMove(pos)
	if not self._drag then return end

	self:drag_to(self.transform:GlobalToLocal(pos))
	return true
end

function META:OnGlobalMouseInput(button, press)
	if button == "button_1" and not press and self._drag then
		self._drag = nil
		return true
	end
end

function META:OnDraw()
	update_cache()
	render2d.SetTexture(nil)
	rect(0, 0, WIDTH, HEIGHT, 0.03, 0.04, 0.07, 0.9, 10)
	local time = weather.GetTime()
	local latitude, longitude = weather.GetLocation()
	local sun = weather.GetSunDirectionAt(time, latitude, longitude)
	local elongation, waxing, phase, moon = get_lunar_state()

	do -- the dome, seen from above with north up and east to the right
		local rings = 24

		for i = 0, rings - 1 do
			local f = i / (rings - 1)
			render2d.SetColor(
				math.lerp(f, 0.55, 0.05) * math.lerp(math.clamp(sun.y * 3, 0, 1), 0.35, 1),
				math.lerp(f, 0.6, 0.1) * math.lerp(math.clamp(sun.y * 3, 0, 1), 0.35, 1),
				math.lerp(f, 0.75, 0.3) * math.lerp(math.clamp(sun.y * 3, 0, 1), 0.35, 1),
				1
			)
			render2d.DrawFilledCircle(DOME_X, DOME_Y, DOME_RADIUS * (1 - f * 0.97))
		end

		render2d.SetColor(1, 1, 1, 0.14)

		for _, elevation in ipairs{30, 60} do
			render2d.DrawCircle(DOME_X, DOME_Y, DOME_RADIUS * (1 - elevation / 90), 1, 48)
		end

		render2d.DrawLine(DOME_X - DOME_RADIUS, DOME_Y, DOME_X + DOME_RADIUS, DOME_Y, 1)
		render2d.DrawLine(DOME_X, DOME_Y - DOME_RADIUS, DOME_X, DOME_Y + DOME_RADIUS, 1)
		render2d.SetColor(1, 1, 1, 0.5)
		render2d.DrawCircle(DOME_X, DOME_Y, DOME_RADIUS, 1.5, 64)
		label("N", DOME_X - 4, DOME_Y - DOME_RADIUS - DOME_MARGIN + 2, TEXT)
		label("S", DOME_X - 4, DOME_Y + DOME_RADIUS + 4, TEXT)
		label("E", DOME_X + DOME_RADIUS + 8, DOME_Y - 7, TEXT)
		label("W", DOME_X - DOME_RADIUS - 16, DOME_Y - 7, TEXT)
		render2d.SetColor(1, 0.85, 0.4, 0.55)

		for i = 0, SAMPLES do
			if sun_dy[i] > 0 then
				local x, y = dome_point(sun_dx[i], sun_dy[i], sun_dz[i])
				render2d.DrawFilledCircle(x, y, 1.4)
			end
		end

		render2d.SetColor(0.7, 0.8, 1, 0.45)

		for i = 0, SAMPLES do
			if moon_dy[i] > 0 then
				local x, y = dome_point(moon_dx[i], moon_dy[i], moon_dz[i])
				render2d.DrawFilledCircle(x, y, 1.2)
			end
		end

		local mx, my = dome_point(moon.x, moon.y, moon.z)
		draw_moon(mx, my, 8, elongation, waxing, moon.y > 0 and 1 or 0.45)
		local sx, sy = dome_point(sun.x, sun.y, sun.z)
		local alpha = sun.y > 0 and 1 or 0.45

		for i = 3, 1, -1 do
			render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 0.12 * alpha)
			render2d.DrawFilledCircle(sx, sy, 9 + i * 5)
		end

		render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, alpha)
		render2d.DrawFilledCircle(sx, sy, 9)
		local _, _, sun_elevation, sun_azimuth = dome_point(sun.x, sun.y, sun.z)
		local _, _, moon_elevation = dome_point(moon.x, moon.y, moon.z)
		label(
			string.format("sun   %5.1f° up   %5.1f° az", sun_elevation, math.deg(sun_azimuth) % 360),
			12,
			DOME_Y + DOME_RADIUS + DOME_MARGIN + 8,
			SUN_COLOR
		)
		label(
			string.format("moon %5.1f° up   %s %d%%", moon_elevation, get_phase_name(phase), (1 - math.cos(elongation)) * 50),
			12,
			DOME_Y + DOME_RADIUS + DOME_MARGIN + 26,
			MOON_COLOR
		)
	end

	do -- the day: elevation against local solar time
		label("day   drag to set the time of day", COLUMN_X, CHART_Y - 18)
		rect(COLUMN_X, CHART_Y, COLUMN_W, CHART_H, 0.08, 0.1, 0.16, 1, 4)
		local horizon = chart_y(0)
		rect(COLUMN_X, horizon, COLUMN_W, CHART_Y + CHART_H - horizon, 0, 0, 0, 0.35)
		render2d.SetColor(1, 1, 1, 0.12)

		for hour = 3, 21, 3 do
			render2d.DrawLine(COLUMN_X + hour / 24 * COLUMN_W, CHART_Y, COLUMN_X + hour / 24 * COLUMN_W, CHART_Y + CHART_H, 1)
		end

		render2d.SetColor(1, 1, 1, 0.4)
		render2d.DrawLine(COLUMN_X, horizon, COLUMN_X + COLUMN_W, horizon, 1)

		for hour = 0, 24, 6 do
			label(string.format("%02d", hour), COLUMN_X + hour / 24 * COLUMN_W - 6, CHART_Y + CHART_H + 1)
		end

		for pass = 1, 2 do
			local dys = pass == 1 and moon_dy or sun_dy
			local color = pass == 1 and MOON_COLOR or SUN_COLOR
			render2d.SetColor(color.r, color.g, color.b, pass == 1 and 0.6 or 1)

			for i = 1, SAMPLES do
				render2d.DrawLine(
					COLUMN_X + (i - 1) / SAMPLES * COLUMN_W,
					chart_y(math.deg(math.asin(math.clamp(dys[i - 1], -1, 1)))),
					COLUMN_X + i / SAMPLES * COLUMN_W,
					chart_y(math.deg(math.asin(math.clamp(dys[i], -1, 1)))),
					2
				)
			end
		end

		local x = COLUMN_X + weather.GetSolarHours() / 24 * COLUMN_W
		render2d.SetColor(1, 1, 1, 0.5)
		render2d.DrawLine(x, CHART_Y, x, CHART_Y + CHART_H, 1)
		local moon_x = x
		render2d.SetColor(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 1)
		render2d.DrawFilledCircle(moon_x, chart_y(math.deg(math.asin(math.clamp(moon.y, -1, 1)))), 4)
		render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 1)
		render2d.DrawFilledCircle(x, chart_y(math.deg(math.asin(math.clamp(sun.y, -1, 1)))), 7)
	end

	do -- the season: the sun's noon height across the year
		label(
			string.format("year   drag to set the date   day %d", weather.GetDayOfYear()),
			COLUMN_X,
			YEAR_Y - 18
		)
		rect(COLUMN_X, YEAR_Y, COLUMN_W, YEAR_H, 0.08, 0.1, 0.16, 1, 4)
		render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 0.6)

		for i = 1, 24 do
			render2d.DrawLine(
				COLUMN_X + (i - 1) / 24 * COLUMN_W,
				YEAR_Y + YEAR_H * (1 - math.clamp(noon_elevation[i - 1] / 90, 0, 1)),
				COLUMN_X + i / 24 * COLUMN_W,
				YEAR_Y + YEAR_H * (1 - math.clamp(noon_elevation[i] / 90, 0, 1)),
				1.5
			)
		end

		for i, month in ipairs(MONTHS) do
			label(month, COLUMN_X + (MONTH_STARTS[i] + MONTH_STARTS[i + 1] - 2) / 2 / 365 * COLUMN_W - 3, YEAR_Y + YEAR_H + 1)
		end

		local x = COLUMN_X + (weather.GetDayOfYear() - 1) / 365 * COLUMN_W
		render2d.SetColor(1, 1, 1, 0.9)
		render2d.DrawLine(x, YEAR_Y, x, YEAR_Y + YEAR_H, 2)
	end

	do -- the place
		label(string.format("latitude   %.1f° %s", math.abs(latitude), latitude < 0 and "S" or "N"), COLUMN_X, LATITUDE_Y - 18)
		rect(COLUMN_X, LATITUDE_Y, COLUMN_W, LATITUDE_H, 0.08, 0.1, 0.16, 1, 4)
		render2d.SetColor(1, 1, 1, 0.2)

		for degrees = -60, 60, 30 do
			local x = COLUMN_X + (degrees + 90) / 180 * COLUMN_W
			render2d.DrawLine(x, LATITUDE_Y + 4, x, LATITUDE_Y + LATITUDE_H - 4, 1)
			label(tostring(degrees), x - 8, LATITUDE_Y + LATITUDE_H + 1)
		end

		local x = COLUMN_X + (latitude + 90) / 180 * COLUMN_W
		render2d.SetColor(1, 1, 1, 0.9)
		render2d.DrawLine(x, LATITUDE_Y, x, LATITUDE_Y + LATITUDE_H, 2)
	end

	do -- the moon's phase, dragging it moves the date
		label("moon   drag to change the phase", COLUMN_X, MOON_Y - 18)
		rect(COLUMN_X, MOON_Y, COLUMN_W, MOON_H, 0.08, 0.1, 0.16, 1, 4)

		for i = 0, 8 do
			local f = i / 8
			local e = (f <= 0.5 and f or 1 - f) * 2 * math.pi
			draw_moon(COLUMN_X + 14 + f * (COLUMN_W - 28), MOON_Y + MOON_H / 2, 8, e, f <= 0.5, 0.55)
		end

		local x = COLUMN_X + phase * COLUMN_W
		render2d.SetColor(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 1)
		render2d.DrawLine(x, MOON_Y, x, MOON_Y + MOON_H, 2)
	end
end

META:Register()
local panel = NULL
local shown = false

event.AddListener("Update", "sun_dial", function()
	local down = input.IsKeyDown("q")

	if down and not shown then
		if not panel:IsValid() then
			panel = Panel.World:Ensure(META{Key = "SunDial", Size = Vec2(WIDTH, HEIGHT), RequestMouse = true})
		end

		local size = Panel.World.transform:GetSize()
		panel.transform:SetPosition(Vec2(size.x - WIDTH - 16, size.y - HEIGHT - 16))
		panel.visual:SetVisible(true)
		shown = true
	elseif not down and shown and not panel:IsDragging() then
		panel.visual:SetVisible(false)
		shown = false
	end
end)
