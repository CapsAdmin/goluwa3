local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local timer = import("goluwa/timer.lua")
local event = import("goluwa/event.lua")
local weather = import("goluwa/render3d/weather.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local water = import("goluwa/render3d/water.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local TileSet = import("lua/earth/tile_set.lua")
-- the weather over the origin from Open-Meteo, hourly and followed as the weather's clock moves: temperature, rain,
-- snow, snow on the ground, wetness from the rain of the last hours, wind, haze from the aerosol optical depth (its
-- air quality model), fog from the forecast's visibility and the ocean's swell (its marine model, none inland)
local weather_feed = {}
weather_feed.ATTRIBUTION = "Weather: Open-Meteo.com (CC BY 4.0; ECMWF, DWD, NOAA, Copernicus CAMS)"
local HOST_LIMIT = 2
local CACHE_SECONDS = 3600
local RETRY_SECONDS = 60
local UPDATE_INTERVAL = 5
-- the rain over the last WET_HOURS that leaves the ground fully wet, millimeters
local WET_HOURS = 3
local WET_RAIN = 1.5
-- fog is only taken from the forecast's visibility below this, above it the haze is the aerosol's
local FOG_VISIBILITY = 20000
local directory = vfs.GetStorageDirectory("cache") .. "earth/open_meteo/"
local FEEDS = {
	forecast = {
		url = "https://api.open-meteo.com/v1/forecast",
		hourly = "temperature_2m,precipitation,rain,snowfall,snow_depth,wind_speed_10m,wind_direction_10m,visibility",
		extra = "&wind_speed_unit=ms",
	},
	air = {
		url = "https://air-quality-api.open-meteo.com/v1/air-quality",
		hourly = "aerosol_optical_depth",
		extra = "",
	},
	marine = {
		url = "https://marine-api.open-meteo.com/v1/marine",
		hourly = "swell_wave_height,swell_wave_direction,swell_wave_period",
		extra = "",
	},
}

local function fetch(name, lat, lon, callback)
	local feed = FEEDS[name]
	local path = string.format(
		"%s%s_%.2f_%.2f_%d.json",
		directory,
		name,
		lat,
		lon,
		math.floor(os.time() / CACHE_SECONDS)
	)
	local cached = fs.read_file(path)

	if cached then return callback(json.decode(cached).hourly) end

	local url = string.format(
		"%s?latitude=%.4f&longitude=%.4f&hourly=%s&past_days=1&forecast_days=2&timeformat=unixtime%s",
		feed.url,
		lat,
		lon,
		feed.hourly,
		feed.extra
	)

	local function retry(reason)
		llog("earth: open-meteo %s failed: %s", name, tostring(reason))

		timer.Delay(RETRY_SECONDS, function()
			if weather_feed.lat == lat and weather_feed.lon == lon then
				fetch(name, lat, lon, callback)
			end
		end)
	end

	TileSet.HostRequest(
		url,
		{},
		HOST_LIMIT,
		function(response)
			-- the marine model answers 400 for a point with no sea near
			if response.code == 400 then return end

			if response.code ~= 200 then return retry("http " .. tostring(response.code)) end

			fs.create_directory_recursive(directory)
			fs.write_file(path, response.body)
			callback(json.decode(response.body).hourly)
		end,
		retry
	)
end

-- a series' value at a time, linear between its hours, nil without the series
local function sample(hourly, key, time)
	local series = hourly and hourly[key]

	if not series then return end

	local times = hourly.time
	local t = 1

	while t < #times - 1 and times[t + 1] <= time do
		t = t + 1
	end

	local f = math.clamp((time - times[t]) / (times[t + 1] - times[t]), 0, 1)
	local a, b = series[t], series[t + 1]

	if type(a) ~= "number" then return type(b) == "number" and b or nil end

	if type(b) ~= "number" then return a end

	return math.lerp(f, a, b)
end

local function apply()
	local time = weather.GetTime()
	local forecast, air, marine = weather_feed.forecast, weather_feed.air, weather_feed.marine

	if forecast then
		local temperature = sample(forecast, "temperature_2m", time)
		local precipitation = sample(forecast, "precipitation", time) or 0
		local rain = sample(forecast, "rain", time) or 0
		local recent = 0

		for hour = 0, WET_HOURS - 1 do
			recent = recent + (sample(forecast, "rain", time - hour * 3600) or 0)
		end

		if temperature then weather.SetTemperature(temperature) end

		weather.SetRain(rain)
		weather.SetSnow(math.max(precipitation - rain, 0))
		weather.SetWetness(math.clamp(recent / WET_RAIN, 0, 1))
		weather.SetSnowDepth(sample(forecast, "snow_depth", time) or 0)
		local speed = sample(forecast, "wind_speed_10m", time)
		local from = sample(forecast, "wind_direction_10m", time)

		-- the direction is where the wind comes from, clockwise from north; the world's north is -z
		if speed and from then
			local to = math.rad(from + 180)
			weather.SetWind(Vec3(math.sin(to), 0, -math.cos(to)) * speed)
		end

		local visibility = sample(forecast, "visibility", time)
		weather.SetGroundFogVisibility(
			visibility and
				visibility < FOG_VISIBILITY and
				visibility or
				atmosphere.DEFAULT_GROUND_FOG_VISIBILITY
		)
	end

	local depth = sample(air, "aerosol_optical_depth", time)

	-- an optical depth spread over the aerosol's scale height is an extinction, and Koschmieder's 3.912 over it the
	-- distance at which contrast falls to 2%
	if depth then
		weather.SetAerosolVisibility(3.912 * atmosphere.GetAerosol().scale_height * 1000 / math.max(depth, 0.01))
	end

	local swell = sample(marine, "swell_wave_height", time)
	local hour = math.floor(time / 3600)

	if swell and hour ~= weather_feed.swell_hour then
		weather_feed.swell_hour = hour
		local period = sample(marine, "swell_wave_period", time) or 8
		-- the swell comes from its direction, clockwise from north; the ocean's directions are angles from +x toward +z
		local to = math.rad((sample(marine, "swell_wave_direction", time) or 0) + 180)
		water.SetOceanGradually{
			SwellHeight = swell,
			SwellWavelength = 9.81 * period * period / (2 * math.pi),
			SwellDirection = math.deg(math.atan2(-math.cos(to), math.sin(to))),
		}
	end
end

function weather_feed.Start(lat, lon)
	weather_feed.Stop()
	weather_feed.lat, weather_feed.lon = lat, lon

	for name in pairs(FEEDS) do
		fetch(
			name,
			lat,
			lon,
			function(hourly)
				if weather_feed.lat ~= lat or weather_feed.lon ~= lon then return end

				weather_feed[name] = hourly
				apply()
			end
		)
	end

	timer.Repeat("earth_weather_feed", UPDATE_INTERVAL, 0, apply)
end

function weather_feed.Stop()
	timer.RemoveTimer("earth_weather_feed")
	weather_feed.lat, weather_feed.lon = nil, nil
	weather_feed.forecast, weather_feed.air, weather_feed.marine = nil, nil, nil
	weather_feed.swell_hour = nil
end

return weather_feed
