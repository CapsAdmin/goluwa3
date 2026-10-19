local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local desktop = import("goluwa/render2d/ui/desktop.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local weather = import("goluwa/render3d/weather.lua")
local SunShadowEditor = import("lua/sun_shadow_editor.lua")
local WIDTH = 604
local HEIGHT = 412
local HEADER = 36
local TAB_BAR = 40
local DOME_RADIUS, DOME_MARGIN = 108, 22
local DOME_SIZE = (DOME_RADIUS + DOME_MARGIN) * 2
local CHART_H = 130
local STRIP_H = 28
local CHART_MIN, CHART_MAX = -60, 90
local SAMPLES = 48
local SYNODIC_DAYS = 29.530588
local MONTHS = {"J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"}
local MONTH_STARTS = {1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366}
local HOUR_LABELS = {"00", "06", "12", "18", "24"}
local LATITUDE_LABELS = {"-60", "-30", "0", "30", "60"}
local TEXT_DIM = Color(0.5, 0.55, 0.65, 1)
local TEXT_COMPASS = Color(0.78, 0.82, 0.9, 1)
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

-- the positions of the sun and the moon over the day and the noon height of the sun over the year, made again when the day or the place changes
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

-- a point of the dome seen from above with north up and east to the right, the center of the dome is (cx, cy)
local function dome_point(cx, cy, x, y, z)
	local elevation = math.deg(math.asin(math.clamp(y, -1, 1)))
	local azimuth = math.atan2(x, -z)
	local radius = elevation >= 0 and
		DOME_RADIUS * (1 - elevation / 90) or
		DOME_RADIUS - elevation / 90 * DOME_MARGIN

	return cx + math.sin(azimuth) * radius, cy - math.cos(azimuth) * radius, elevation, azimuth
end

local function chart_y(elevation, height)
	return height * (1 - (math.clamp(elevation, CHART_MIN, CHART_MAX) - CHART_MIN) / (CHART_MAX - CHART_MIN))
end

local function elevation_of(y)
	return math.deg(math.asin(math.clamp(y, -1, 1)))
end

local function draw_dome(self)
	update_cache()
	local size = self.Owner.transform:GetSize()
	local cx, cy = size.x / 2, size.y / 2
	local time = weather.GetTime()
	local latitude, longitude = weather.GetLocation()
	local sun = weather.GetSunDirectionAt(time, latitude, longitude)
	local elongation, waxing, _, moon = get_lunar_state()
	render2d.SetTexture(nil)
	local rings = 24
	local daylight = math.lerp(math.clamp(sun.y * 3, 0, 1), 0.35, 1)

	for i = 0, rings - 1 do
		local f = i / (rings - 1)
		render2d.SetColor(
			math.lerp(f, 0.55, 0.05) * daylight,
			math.lerp(f, 0.6, 0.1) * daylight,
			math.lerp(f, 0.75, 0.3) * daylight,
			1
		)
		render2d.DrawFilledCircle(cx, cy, DOME_RADIUS * (1 - f * 0.97))
	end

	render2d.SetColor(1, 1, 1, 0.14)

	for _, elevation in ipairs{30, 60} do
		render2d.DrawCircle(cx, cy, DOME_RADIUS * (1 - elevation / 90), 1, 48)
	end

	render2d.DrawLine(cx - DOME_RADIUS, cy, cx + DOME_RADIUS, cy, 1)
	render2d.DrawLine(cx, cy - DOME_RADIUS, cx, cy + DOME_RADIUS, 1)
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.DrawCircle(cx, cy, DOME_RADIUS, 1.5, 64)

	for _, compass in ipairs{
		{"N", cx - 4, cy - DOME_RADIUS - DOME_MARGIN + 2},
		{"S", cx - 4, cy + DOME_RADIUS + 4},
		{"E", cx + DOME_RADIUS + 8, cy - 7},
		{"W", cx - DOME_RADIUS - 16, cy - 7},
	} do
		render2d.DrawText{text = compass[1], x = compass[2], y = compass[3], size = 12, foreground_color = TEXT_COMPASS}
	end

	render2d.SetColor(1, 0.85, 0.4, 0.55)

	for i = 0, SAMPLES do
		if sun_dy[i] > 0 then
			local x, y = dome_point(cx, cy, sun_dx[i], sun_dy[i], sun_dz[i])
			render2d.DrawFilledCircle(x, y, 1.4)
		end
	end

	render2d.SetColor(0.7, 0.8, 1, 0.45)

	for i = 0, SAMPLES do
		if moon_dy[i] > 0 then
			local x, y = dome_point(cx, cy, moon_dx[i], moon_dy[i], moon_dz[i])
			render2d.DrawFilledCircle(x, y, 1.2)
		end
	end

	local mx, my = dome_point(cx, cy, moon.x, moon.y, moon.z)
	draw_moon(mx, my, 8, elongation, waxing, moon.y > 0 and 1 or 0.45)
	local sx, sy = dome_point(cx, cy, sun.x, sun.y, sun.z)
	local alpha = sun.y > 0 and 1 or 0.45

	for i = 3, 1, -1 do
		render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 0.12 * alpha)
		render2d.DrawFilledCircle(sx, sy, 9 + i * 5)
	end

	render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, alpha)
	render2d.DrawFilledCircle(sx, sy, 9)
end

local function draw_day(self)
	update_cache()
	local size = self.Owner.transform:GetSize()
	local w, h = size.x, size.y
	local time = weather.GetTime()
	local latitude, longitude = weather.GetLocation()
	local sun = weather.GetSunDirectionAt(time, latitude, longitude)
	local moon = weather.GetMoonAt(time, latitude, longitude)
	render2d.SetTexture(nil)
	rect(0, 0, w, h, 0.08, 0.1, 0.16, 1, 4)
	local horizon = chart_y(0, h)
	rect(0, horizon, w, h - horizon, 0, 0, 0, 0.35)
	render2d.SetColor(1, 1, 1, 0.12)

	for hour = 3, 21, 3 do
		render2d.DrawLine(hour / 24 * w, 0, hour / 24 * w, h, 1)
	end

	render2d.SetColor(1, 1, 1, 0.4)
	render2d.DrawLine(0, horizon, w, horizon, 1)

	for pass = 1, 2 do
		local dys = pass == 1 and moon_dy or sun_dy
		local color = pass == 1 and MOON_COLOR or SUN_COLOR
		render2d.SetColor(color.r, color.g, color.b, pass == 1 and 0.6 or 1)

		for i = 1, SAMPLES do
			render2d.DrawLine(
				(i - 1) / SAMPLES * w,
				chart_y(elevation_of(dys[i - 1]), h),
				i / SAMPLES * w,
				chart_y(elevation_of(dys[i]), h),
				2
			)
		end
	end

	local x = weather.GetSolarHours() / 24 * w
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.DrawLine(x, 0, x, h, 1)
	render2d.SetColor(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 1)
	render2d.DrawFilledCircle(x, chart_y(elevation_of(moon.y), h), 4)
	render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 1)
	render2d.DrawFilledCircle(x, chart_y(elevation_of(sun.y), h), 7)
end

local function draw_year(self)
	update_cache()
	local size = self.Owner.transform:GetSize()
	local w, h = size.x, size.y
	render2d.SetTexture(nil)
	rect(0, 0, w, h, 0.08, 0.1, 0.16, 1, 4)
	render2d.SetColor(SUN_COLOR.r, SUN_COLOR.g, SUN_COLOR.b, 0.6)

	for i = 1, 24 do
		render2d.DrawLine(
			(i - 1) / 24 * w,
			h * (1 - math.clamp(noon_elevation[i - 1] / 90, 0, 1)),
			i / 24 * w,
			h * (1 - math.clamp(noon_elevation[i] / 90, 0, 1)),
			1.5
		)
	end

	local x = (weather.GetDayOfYear() - 1) / 365 * w
	render2d.SetColor(1, 1, 1, 0.9)
	render2d.DrawLine(x, 0, x, h, 2)
end

local function draw_latitude(self)
	local size = self.Owner.transform:GetSize()
	local w, h = size.x, size.y
	local latitude = weather.GetLocation()
	render2d.SetTexture(nil)
	rect(0, 0, w, h, 0.08, 0.1, 0.16, 1, 4)
	render2d.SetColor(1, 1, 1, 0.2)

	for degrees = -60, 60, 30 do
		local x = (degrees + 90) / 180 * w
		render2d.DrawLine(x, 4, x, h - 4, 1)
	end

	local x = (latitude + 90) / 180 * w
	render2d.SetColor(1, 1, 1, 0.9)
	render2d.DrawLine(x, 0, x, h, 2)
end

local function draw_moon_phase(self)
	local size = self.Owner.transform:GetSize()
	local w, h = size.x, size.y
	local _, _, phase = get_lunar_state()
	render2d.SetTexture(nil)
	rect(0, 0, w, h, 0.08, 0.1, 0.16, 1, 4)

	for i = 0, 8 do
		local f = i / 8
		local e = (f <= 0.5 and f or 1 - f) * 2 * math.pi
		draw_moon(14 + f * (w - 28), h / 2, 8, e, f <= 0.5, 0.55)
	end

	local x = phase * w
	render2d.SetColor(MOON_COLOR.r, MOON_COLOR.g, MOON_COLOR.b, 1)
	render2d.DrawLine(x, 0, x, h, 2)
end

local last_sky

-- what the captions and the readouts say, rounded to what they show and the same table while it is the same, so that a quiet sky is not a render
local function read_sky()
	local time = weather.GetTime()
	local latitude, longitude = weather.GetLocation()
	local sun = weather.GetSunDirectionAt(time, latitude, longitude)
	local elongation, _, phase, moon = get_lunar_state()
	local sky = {
		sun_elevation = math.floor(elevation_of(sun.y) * 10 + 0.5) / 10,
		sun_azimuth = math.floor(math.deg(math.atan2(sun.x, -sun.z)) % 360 * 10 + 0.5) / 10,
		moon_elevation = math.floor(elevation_of(moon.y) * 10 + 0.5) / 10,
		phase_name = get_phase_name(phase),
		illumination = math.floor((1 - math.cos(elongation)) * 50),
		day = math.floor(weather.GetDayOfYear()),
		latitude = math.floor(latitude * 10 + 0.5) / 10,
	}

	if last_sky then
		local same = true

		for key, value in pairs(sky) do
			if last_sky[key] ~= value then same = false end
		end

		if same then return last_sky end
	end

	last_sky = sky

	return sky
end

-- a canvas that is dragged to set something, OnDrag(local_position, size) is called when the button goes down and while it is held, also outside of the canvas
local DragSurface = react.Component(|props| -> do
	local drag = react.UseDrag{OnDrag = props.OnDrag}

	return ui.Panel{
		transform = true,
		layout = props.layout,
		mouse_input = {Cursor = "hand"},
		visual = {OnDraw = props.Draw},
		OnMouseInput = drag.OnMouseInput,
		OnGlobalMouseMove = drag.OnGlobalMouseMove,
		OnGlobalMouseInput = drag.OnGlobalMouseInput,
	}
end)

local function caption(text)
	return ui.Text{Key = "caption", Text = text, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true}
end

local function axis(labels, layout)
	return ui.Row{Key = "axis", layout = layout}{
		list.map(labels, |text, index| -> ui.Text{Key = index, Text = text, Font = "body XS", Color = "text_disabled", IgnoreMouseInput = true}),
	}
end

local function strip(title, height, draw, on_drag, labels)
	return ui.Column{layout = {GrowWidth = 1, ChildGap = 2, AlignmentX = "stretch"}}{
		caption(title),
		DragSurface{
			Key = "surface",
			Draw = draw,
			OnDrag = on_drag,
			layout = {GrowWidth = 1, MinSize = Vec2(0, height), MaxSize = Vec2(0, height)},
		},
		labels,
	}
end

local SunDial = react.Component(|| -> do
	local sky = react.UsePoll(read_sky, 0.1)
	local on_dome = |position, size| -> do
		local dx, dy = position.x - size.x / 2, size.y / 2 - position.y
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
	end
	local on_time = |position, size| -> weather.SetSolarHours(math.clamp(position.x / size.x, 0, 1) * 24)
	local on_day = |position, size| -> weather.SetDayOfYear(1 + math.clamp(position.x / size.x, 0, 1) * 365)
	local on_latitude = |position, size| -> weather.SetLocation(
		-90 + math.clamp(position.x / size.x, 0, 1) * 180,
		select(2, weather.GetLocation())
	)
	local on_moon = |position, size| -> do
		local _, _, phase = get_lunar_state()
		local target = math.clamp(position.x / size.x, 0, 1)
		weather.SetTime(weather.GetTime() + wrap(target - phase) * SYNODIC_DAYS * 86400)
	end

	return ui.Row{layout = {GrowWidth = 1, GrowHeight = 1, ChildGap = "M", AlignmentY = "start"}}{
		ui.Column{layout = {ChildGap = "XS", AlignmentX = "start", GrowWidth = 0, FitWidth = true}}{
			DragSurface{
				Key = "dome",
				Draw = draw_dome,
				OnDrag = on_dome,
				layout = {MinSize = Vec2(DOME_SIZE, DOME_SIZE), MaxSize = Vec2(DOME_SIZE, DOME_SIZE), GrowWidth = 0},
			},
			ui.Text{
				Key = "sun",
				Text = string.format("sun   %5.1f° up   %5.1f° az", sky.sun_elevation, sky.sun_azimuth),
				Font = "body S",
				IgnoreMouseInput = true,
			},
			ui.Text{
				Key = "moon",
				Text = string.format("moon %5.1f° up   %s %d%%", sky.moon_elevation, sky.phase_name, sky.illumination),
				Font = "body S",
				IgnoreMouseInput = true,
			},
		},
		ui.Column{layout = {GrowWidth = 1, ChildGap = "S", AlignmentX = "stretch"}}{
			strip(
				"day   drag to set the time of day",
				CHART_H,
				draw_day,
				on_time,
				axis(HOUR_LABELS, {GrowWidth = 1, AlignmentX = "space_between"})
			),
			strip(
				string.format("year   drag to set the date   day %d", sky.day),
				STRIP_H,
				draw_year,
				on_day,
				-- the width of a month is its days, so each letter sits in the middle of its month
				ui.Row{Key = "axis", layout = {GrowWidth = 1}}{
					list.map(
						MONTHS,
						|month, index| -> ui.Text{
							Key = index,
							Text = month,
							Font = "body XS",
							Color = "text_disabled",
							AlignX = 0.5,
							IgnoreMouseInput = true,
							layout = {GrowWidth = MONTH_STARTS[index + 1] - MONTH_STARTS[index]},
						}
					),
				}
			),
			strip(
				string.format("latitude   %.1f° %s", math.abs(sky.latitude), sky.latitude < 0 and "S" or "N"),
				STRIP_H,
				draw_latitude,
				on_latitude,
				axis(LATITUDE_LABELS, {GrowWidth = 1, AlignmentX = "space_evenly"})
			),
			strip("moon   drag to change the phase", STRIP_H, draw_moon_phase, on_moon, nil),
		},
	}
end)
-- closing the window only hides it, nothing reads the sky or the shadow settings while it is hidden, and only the open tab is mounted
local SunDialWindow = react.Component(|| -> do
	local shown, set_shown = react.UseState(true)
	local hud, set_hud = react.UseState(false)
	local tab, set_tab = react.UseState("Dial")
	local position = react.UseMemo(|| -> do
		local world_size = Panel.World.transform:GetSize()

		return Vec2(world_size.x - WIDTH - 16, world_size.y - HEIGHT - HEADER - TAB_BAR - 16)
	end, {})

	return ui.Window{
		Title = "SUN DIAL",
		Pinnable = true,
		Maximizable = false,
		Padding = "S",
		Size = Vec2(WIDTH, HEIGHT + HEADER + TAB_BAR),
		MinSize = Vec2(WIDTH, HEIGHT + HEADER + TAB_BAR),
		Position = position,
		OnHudChanged = |_, value| -> set_hud(value),
		OnVisibilityChanged = |_, visible| -> set_shown(visible),
	}{
		ui.Tabs{Value = tab, OnChange = set_tab, BarHidden = hud, layout = {GrowWidth = 1, GrowHeight = 1}}{
			ui.Column{Key = "dial", Tab = "Dial", layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch"}}{
				shown && tab == "Dial" && SunDial{},
			},
			ui.Column{Key = "shadows", Tab = "Shadows", layout = {GrowWidth = 1, GrowHeight = 1, AlignmentX = "stretch"}}{
				shown && tab == "Shadows" && SunShadowEditor{Height = HEIGHT - 24},
			},
		},
	}
end)

desktop.RegisterProgram{
	Name = "Sun",
	Icon = "light",
	Positioned = true,
	Create = function()
		return react.Mount(SunDialWindow{}, Panel.World):GetEntity()
	end,
}
