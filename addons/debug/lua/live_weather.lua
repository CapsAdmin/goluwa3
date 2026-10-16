local codec = import("goluwa/codec.lua")
local http = import("goluwa/sockets/http.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local climate = import("goluwa/render3d/climate.lua")
local weather = import("goluwa/render3d/weather.lua")
local live_weather = {}
-- the observation that gives the cloud bases, the closest airport to Bac Ninh
live_weather.METAR_STATION = "VVNB"
local FEET_TO_METERS = 0.3048
local METAR_COVERAGE = {FEW = 0.2, SCT = 0.4, BKN = 0.7, OVC = 1}
local CLEAN = atmosphere.DEFAULT_AEROSOL
local SMOG = {angstrom = 1.8, albedo = 0.88, g = 0.62, scale_height = 0.7}
-- the cloud layers of the cumulus preset, by the altitude class they stand for, bottom and coverage are replaced
local CLOUD_CLASSES = {
	{name = "low", max_base = 2500, default_bottom = 1400, template = climate.presets.cumulus.clouds[1]},
	{name = "mid", max_base = 6000, default_bottom = 4800, template = climate.presets.cumulus.clouds[3]},
	{name = "high", max_base = math.huge, default_bottom = 9000, template = climate.presets.cumulus.clouds[2]},
}
-- the extra optical depth the thin haze above the boundary layer adds, in km of boundary layer (atmosphere.lua mie_density)
local UPPER_HAZE_KM = 0.56

local function get_class(base)
	for _, class in ipairs(CLOUD_CLASSES) do
		if base <= class.max_base then return class end
	end
end

local function build_clouds(metar, cover_percent)
	local found = {}

	for _, layer in ipairs(metar and metar.clouds or {}) do
		local coverage = METAR_COVERAGE[layer.cover]
		local base = layer.base and layer.base * FEET_TO_METERS

		if coverage and base then
			local class = get_class(base)
			local best = found[class.name]

			if not best or coverage > best.coverage then
				found[class.name] = {class = class, bottom = base, coverage = coverage}
			end
		end
	end

	-- a ceilometer does not see above 12000 feet, and without an observation the model's cover is all there is
	for _, class in ipairs(CLOUD_CLASSES) do
		if not found[class.name] and (class.name == "high" or not metar) then
			local coverage = cover_percent[class.name] / 100

			if coverage >= 0.05 then
				found[class.name] = {class = class, bottom = class.default_bottom, coverage = coverage}
			end
		end
	end

	local layers = {}

	for _, class in ipairs(CLOUD_CLASSES) do
		local layer = found[class.name]

		if layer then
			local params = table.copy(class.template)
			params.name = class.name
			params.bottom = layer.bottom
			params.coverage = layer.coverage
			list.insert(layers, params)
		end
	end

	return layers
end

-- the weather as a climate preset: `forecast` and `air` are the decoded open-meteo answers, `metar` the decoded
-- observation or nil
function live_weather.BuildPreset(forecast, air, metar)
	local current = forecast.current
	local interval = current.interval
	local preset = {temperature = current.temperature_2m}
	-- the direction is where the wind comes from, in degrees clockwise from north. -z is north and +x is east
	local bearing = math.rad(current.wind_direction_10m + 180)
	preset.wind = Vec3(math.sin(bearing), 0, -math.cos(bearing)) * current.wind_speed_10m
	-- the precipitation is the sum over the last interval
	local rain = current.rain * 3600 / interval
	local snow = (current.precipitation - current.rain) * 3600 / interval

	if current.temperature_2m < 1 then rain, snow = 0, current.precipitation * 3600 / interval end

	preset.rain = rain
	preset.snow = snow
	preset.wetness = rain > 0 and 1 or 0
	preset.clouds = build_clouds(
		metar,
		{
			low = current.cloud_cover_low,
			mid = current.cloud_cover_mid,
			high = current.cloud_cover_high,
		}
	)
	local fog_visibility = current.visibility

	if current.relative_humidity_2m >= 95 then
		preset.ground_fog_visibility = math.max(fog_visibility, 200)
	else
		preset.ground_fog_visibility = atmosphere.DEFAULT_GROUND_FOG_VISIBILITY
	end

	if air then
		local smog = math.clamp((air.current.pm2_5 - 10) / 60, 0, 1)
		preset.aerosol_angstrom = math.lerp(smog, CLEAN.angstrom, SMOG.angstrom)
		preset.aerosol_albedo = math.lerp(smog, CLEAN.albedo, SMOG.albedo)
		preset.aerosol_g = math.lerp(smog, CLEAN.g, SMOG.g)
		preset.aerosol_height = math.lerp(smog, CLEAN.scale_height, SMOG.scale_height)
		-- the optical depth of the column spread over the layer is the extinction at the ground, and the visibility is
		-- how far that sees, the model's own visibility is the other estimate
		local extinction = air.current.aerosol_optical_depth / (preset.aerosol_height + UPPER_HAZE_KM)
		local derived = extinction > 0 and 3912 / extinction or math.huge
		preset.aerosol_visibility = math.clamp(math.min(derived, current.visibility), 500, 200000)
	else
		preset.aerosol_visibility = math.clamp(current.visibility, 500, 200000)
	end

	return preset
end

-- fetches the weather at the weather's location and blends into it, `on_done(preset or nil, error)` is called after
function live_weather.Apply(on_done)
	local latitude, longitude = weather.GetLocation()
	local position = string.format("latitude=%.4f&longitude=%.4f", latitude, longitude)
	local results = {}
	local failure
	local pending = 3

	local function finish()
		pending = pending - 1

		if pending > 0 then return end

		if not results.forecast then return on_done(nil, failure or "no forecast") end

		local preset = live_weather.BuildPreset(results.forecast, results.air, results.metar)
		weather.SetTime(os.time())
		climate.SetPreset(preset)
		on_done(preset)
	end

	local function fetch(name, url)
		http.Download(url):Then(function(body)
			local ok, decoded = pcall(codec.Decode, "json", body)

			if ok and decoded and not decoded.error then
				results[name] = name == "metar" and decoded[1] or decoded
			else
				failure = name .. ": " .. tostring(ok and decoded.reason or decoded)
			end

			finish()
		end):Catch(function(reason)
			failure = name .. ": " .. tostring(reason)
			finish()
		end)
	end

	fetch(
		"forecast",
		"https://api.open-meteo.com/v1/forecast?" .. position .. "&wind_speed_unit=ms&current=temperature_2m,relative_humidity_2m,precipitation,rain,cloud_cover_low,cloud_cover_mid,cloud_cover_high,wind_speed_10m,wind_direction_10m,visibility"
	)
	fetch(
		"air",
		"https://air-quality-api.open-meteo.com/v1/air-quality?" .. position .. "&current=pm2_5,aerosol_optical_depth"
	)
	fetch("metar", "https://aviationweather.gov/api/data/metar?format=json&ids=" .. live_weather.METAR_STATION)
end

return live_weather
