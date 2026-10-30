local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local commands = import("goluwa/cli/commands.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local precipitation = import("goluwa/render3d/precipitation.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local quality = import("goluwa/render3d/quality.lua")
local weather = {}
local SUN_TOA_ILLUMINANCE = atmosphere.DEFAULT_SUN_ILLUMINANCE
local SHADOW_CUTOFF_TRANSMITTANCE = 1e-5
local EARTH_RADIUS_KM = 6371
local MOON_RADIUS_KM = 1737.4
local MOON_MEAN_DISTANCE_KM = 384400
local SUN_COLOR = atmosphere.SUN_COLOR
local MOON_TINT = SUN_COLOR * Vec3(1.0, 0.94, 0.86)
local RAIN_FALL_SPEED = 6.5
local SNOW_FALL_SPEED = 1
local RAIN_SPREAD = 0.05
local SNOW_SPREAD = 0.3
local WIND_TURBULENCE = 0.25
local MAX_SHELTER_SLANT = 4
local SHELTER_SIZE = 1024
local SHELTER_HALF_SIZE = 96
local SHELTER_DEPTH = 600
local SHELTER_SNAP_TEXELS = 64
local CLOUD_LIGHT_ALTITUDE = Vec3(0, 2000, 0)
weather.latitude = 21.176852
weather.longitude = 106.068101
weather.time = 1782010800
weather.time_scale = 0
weather.moon_scale = 1
pvars.StartGroup("Environment", "Weather", {store = false, prefix = "weather_"})
local enabled = pvars.Setup2{
	key = "weather_enabled",
	default = true,
	help = "the sun, sky and air",
	callback = function(value, is_init)
		if is_init then return end

		atmosphere.SetEnabled(value)
		weather.UpdateSky()
	end,
}
pvars.EndGroup()
weather.light = nil
weather.shadow_maps = {}
weather.shelter_caster = nil
weather.shelter_map = nil

local function days_since_j2000(unix_time)
	return unix_time / 86400 - 10957.5
end

local function equatorial_vector(right_ascension, declination)
	return Vec3(
		math.cos(declination) * math.cos(right_ascension),
		math.cos(declination) * math.sin(right_ascension),
		math.sin(declination)
	)
end

local function ecliptic_to_equatorial(longitude, latitude, obliquity)
	local x = math.cos(latitude) * math.cos(longitude)
	local y = math.cos(latitude) * math.sin(longitude)
	local z = math.sin(latitude)
	return Vec3(
		x,
		y * math.cos(obliquity) - z * math.sin(obliquity),
		y * math.sin(obliquity) + z * math.cos(obliquity)
	)
end

local function get_sidereal(unix_time, longitude)
	return math.rad((18.697374558 + 24.06570982441908 * days_since_j2000(unix_time)) * 15 + longitude)
end

function weather.GetCelestialRotationAt(unix_time, latitude, longitude)
	local sidereal = get_sidereal(unix_time, longitude)
	local lat = math.rad(latitude)
	local s, c = math.sin(sidereal), math.cos(sidereal)
	return Vec3(-s, math.cos(lat) * c, math.sin(lat) * c),
	Vec3(c, math.cos(lat) * s, math.sin(lat) * s),
	Vec3(0, math.sin(lat), -math.cos(lat))
end

local function equatorial_to_world(e, x, y, z)
	return Vec3(
		x.x * e.x + y.x * e.y + z.x * e.z,
		x.y * e.x + y.y * e.y + z.y * e.z,
		x.z * e.x + y.z * e.y + z.z * e.z
	)
end

local function get_sun_equatorial(unix_time)
	local n = days_since_j2000(unix_time)
	local mean_longitude = math.rad(280.460 + 0.9856474 * n)
	local mean_anomaly = math.rad(357.528 + 0.9856003 * n)
	local ecliptic_longitude = mean_longitude + math.rad(1.915) * math.sin(mean_anomaly) + math.rad(0.020) * math.sin(2 * mean_anomaly)
	return ecliptic_to_equatorial(ecliptic_longitude, 0, math.rad(23.439 - 0.0000004 * n))
end

local function get_moon_equatorial(unix_time)
	local n = days_since_j2000(unix_time)
	local mean_longitude = math.rad(218.316 + 13.176396 * n)
	local mean_anomaly = math.rad(134.963 + 13.064993 * n)
	local argument_of_latitude = math.rad(93.272 + 13.229350 * n)
	local ecliptic_longitude = mean_longitude + math.rad(6.289) * math.sin(mean_anomaly)
	local ecliptic_latitude = math.rad(5.128) * math.sin(argument_of_latitude)
	local distance = 385001 - 20905 * math.cos(mean_anomaly)
	return ecliptic_to_equatorial(ecliptic_longitude, ecliptic_latitude, math.rad(23.439 - 0.0000004 * n)),
	distance
end

function weather.GetSunDirectionAt(unix_time, latitude, longitude)
	return equatorial_to_world(
		get_sun_equatorial(unix_time),
		weather.GetCelestialRotationAt(unix_time, latitude, longitude)
	)
end

function weather.GetMoonAt(unix_time, latitude, longitude)
	local equatorial, distance = get_moon_equatorial(unix_time)
	local geocentric = equatorial_to_world(equatorial, weather.GetCelestialRotationAt(unix_time, latitude, longitude))
	local topocentric = geocentric * distance - Vec3(0, EARTH_RADIUS_KM, 0)
	distance = topocentric:GetLength()
	local phase_angle = math.deg(math.acos(math.clamp(-get_sun_equatorial(unix_time):GetDot(equatorial), -1, 1)))
	local magnitude = -12.73 + 0.026 * phase_angle + 4e-9 * phase_angle ^ 4
	local illuminance = 10 ^ (-0.4 * (magnitude + 14.18)) * (MOON_MEAN_DISTANCE_KM / distance) ^ 2
	return topocentric / distance, distance, illuminance
end

function weather.SetLocation(latitude, longitude)
	weather.latitude = latitude
	weather.longitude = longitude
	weather.UpdateSky()
end

function weather.GetLocation()
	return weather.latitude, weather.longitude
end

function weather.SetTime(unix_time)
	weather.time = unix_time
	weather.UpdateSky()
end

function weather.GetTime()
	return weather.time
end

function weather.SetTimeScale(scale)
	weather.time_scale = scale
end

function weather.GetSolarHours()
	return (weather.time + weather.longitude * 240) % 86400 / 3600
end

function weather.SetSolarHours(hours)
	local offset = weather.longitude * 240
	weather.SetTime(math.floor((weather.time + offset) / 86400) * 86400 + hours * 3600 - offset)
end

function weather.GetDayOfYear()
	return tonumber(os.date("!%j", math.floor(weather.time)))
end

function weather.SetDayOfYear(day)
	weather.SetTime(weather.time + (math.floor(day + 0.5) - weather.GetDayOfYear()) * 86400)
end

function weather.GetTimeScale()
	return weather.time_scale
end

do
	local SIDEREAL_RADIANS_PER_SECOND = math.rad(24.06570982441908 * 15) / 86400
	local MAX_LATITUDE = math.rad(89)
	local MAX_SIN_DECLINATION = math.sin(math.rad(23.43))
	local LATITUDE_STEP = math.rad(0.1)
	local DECLINATION_COST = 2
	local POLAR_LATITUDE = math.rad(66.5)
	local POLAR_COST = 4

	local function wrap_angle(a)
		return (a + math.pi) % (2 * math.pi) - math.pi
	end

	function weather.SetSunDirection(dir)
		local time = weather.time
		local latitude = math.rad(weather.latitude)
		local r = math.sqrt(dir.y * dir.y + dir.z * dir.z)
		local theta = math.atan2(-dir.z, dir.y)
		local declination = math.asin(get_sun_equatorial(time).z)

		do
			local best, best_declination, best_cost = latitude, declination, math.huge
			local roots = math.asin(math.clamp(math.sin(declination) / r, -1, 1))
			local lat = wrap_angle(roots - theta)
			local i = -2

			while true do
				if lat >= -MAX_LATITUDE and lat <= MAX_LATITUDE then
					local sin_declination = r * math.sin(lat + theta)

					if math.abs(sin_declination) <= MAX_SIN_DECLINATION then
						local needed = math.asin(sin_declination)
						local cost = math.abs(lat - latitude) + math.abs(needed - declination) * DECLINATION_COST + math.max(0, math.abs(lat) - POLAR_LATITUDE) * POLAR_COST

						if cost < best_cost then
							best, best_declination, best_cost = lat, needed, cost
						end
					end
				end

				i = i + 1

				if i == -1 then
					lat = wrap_angle(math.pi - roots - theta)
				elseif i * LATITUDE_STEP > 2 * MAX_LATITUDE then
					break
				else
					lat = -MAX_LATITUDE + i * LATITUDE_STEP
				end
			end

			latitude = best

			if math.abs(best_declination - declination) > 1e-6 then
				local before, after = declination, declination

				for day = 1, 183 do
					local next_after = math.asin(get_sun_equatorial(time + day * 86400).z)

					if (after - best_declination) * (next_after - best_declination) <= 0 then
						time = time + (day - 1 + (best_declination - after) / (next_after - after)) * 86400

						break
					end

					local next_before = math.asin(get_sun_equatorial(time - day * 86400).z)

					if (before - best_declination) * (next_before - best_declination) <= 0 then
						time = time - (day - 1 + (best_declination - before) / (next_before - before)) * 86400

						break
					end

					after, before = next_after, next_before
				end
			end
		end

		for _ = 1, 4 do
			local sun = get_sun_equatorial(time)
			local roots = math.asin(math.clamp(sun.z / r, -1, 1))
			local a = wrap_angle(roots - theta)
			local b = wrap_angle(math.pi - roots - theta)
			latitude = math.clamp(
				math.abs(a - latitude) < math.abs(b - latitude) and a or b,
				-math.pi / 2,
				math.pi / 2
			)
			local meridian = math.cos(latitude) * dir.y + math.sin(latitude) * dir.z
			local sidereal = math.atan2(sun.y, sun.x) - math.atan2(dir.x, meridian)
			time = time + wrap_angle(sidereal - get_sidereal(time, weather.longitude)) / SIDEREAL_RADIANS_PER_SECOND
		end

		weather.latitude = math.deg(latitude)
		weather.time = time
		weather.UpdateSky()
	end
end

function weather.SetSunRotation(rotation)
	weather.SetSunDirection(rotation:GetBackward())
end

-- undefined for a sun straight down, so the shortest arc from up is used
local UP = Vec3(0, 1, 0)
local BACK_TO_UP = QuatFromAxis(-math.pi / 2, Vec3(1, 0, 0))

function weather.GetSunRotationFromDirection(dir)
	local axis = UP:GetCross(dir)
	return Quat(axis.x, axis.y, axis.z, 1 + UP:GetDot(dir)):Normalize() * BACK_TO_UP
end

function weather.GetSunRotation()
	return weather.GetSunRotationFromDirection(weather.GetSunDirection())
end

function weather.GetSunDirection()
	return weather.GetSunDirectionAt(weather.time, weather.latitude, weather.longitude)
end

function weather.SetAerosolVisibility(meters)
	atmosphere.SetAerosolVisibility(meters)
end

function weather.GetAerosolVisibility()
	return atmosphere.GetAerosolVisibility()
end

function weather.SetAerosol(params)
	atmosphere.SetAerosol(params)
end

function weather.GetAerosol()
	return atmosphere.GetAerosol()
end

function weather.SetGroundFogVisibility(meters)
	atmosphere.SetGroundFogVisibility(meters)
end

function weather.GetGroundFogVisibility()
	return atmosphere.GetGroundFogVisibility()
end

function weather.GetVisibility()
	return atmosphere.GetVisibility()
end

function weather.SetWind(velocity)
	atmosphere.SetWind(velocity)
end

function weather.GetWind()
	return atmosphere.GetWind()
end

function weather.SetWindTimeScale(scale)
	atmosphere.SetWindTimeScale(scale)
end

function weather.GetWindTimeScale()
	return atmosphere.GetWindTimeScale()
end

function weather.SetTemperature(celsius)
	atmosphere.SetTemperature(celsius)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetTemperature()
	return atmosphere.GetTemperature()
end

function weather.SetRain(mm_per_hour)
	precipitation.SetRain(mm_per_hour)
	surface_weather.rain_rate = mm_per_hour
	surface_weather.rain_impact_rate = precipitation.GetRainImpactRate(surface_weather.AGITATION_MIN_DIAMETER)
	surface_weather.splash_rate = precipitation.GetRainImpactRate(surface_weather.SPLASH_MIN_DIAMETER)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetRain()
	return precipitation.GetRain()
end

function weather.SetSnow(mm_per_hour)
	precipitation.SetSnow(mm_per_hour)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetSnow()
	return precipitation.GetSnow()
end

function weather.SetWetness(wetness)
	surface_weather.wetness = wetness
end

function weather.GetWetness()
	return surface_weather.wetness
end

function weather.SetSnowDepth(meters)
	surface_weather.snow_depth = meters
end

function weather.GetSnowDepth()
	return surface_weather.snow_depth
end

function weather.SetCloudLayers(layers)
	clouds.SetLayers(layers)
	weather.UpdateSky()
end

function weather.GetCloudLayers()
	return clouds.GetLayers()
end

function weather.GetCloudCover()
	return clouds.GetCover()
end

function weather.SetMoonScale(scale)
	weather.moon_scale = scale
	weather.UpdateSky()
end

function weather.GetMoonScale()
	return weather.moon_scale
end

function weather.IsEnabled()
	return enabled:Get()
end

function weather.GetLight()
	return weather.light
end

function weather.GetController()
	return weather.light.atmosphere_controller
end

function weather.GetMoonDirection()
	return (weather.GetMoonAt(weather.time, weather.latitude, weather.longitude))
end

function weather.SetEnvironmentMap(path)
	atmosphere.SetEnvironmentMap(path)
	weather.UpdateSky()
end

function weather.GetEnvironmentMap()
	return atmosphere.GetEnvironmentMap()
end

function weather.SetEnvironmentMapIntensity(intensity)
	atmosphere.SetEnvironmentMapIntensity(intensity)
end

function weather.GetEnvironmentMapIntensity()
	return atmosphere.GetEnvironmentMapIntensity()
end

function weather.UpdateSky()
	local sun_dir = weather.GetSunDirection()
	local moon_dir, moon_distance, moon_illuminance = weather.GetMoonAt(weather.time, weather.latitude, weather.longitude)
	local x, y, z = weather.GetCelestialRotationAt(weather.time, weather.latitude, weather.longitude)
	atmosphere.SetSky{
		sun_direction = sun_dir,
		moon_direction = moon_dir,
		moon_illuminance = moon_illuminance,
		moon_angular_radius = math.asin(MOON_RADIUS_KM / moon_distance) * weather.moon_scale,
		celestial_x = x,
		celestial_y = y,
		celestial_z = z,
	}

	if
		moon_illuminance * atmosphere.GetTransmittance(moon_dir, CLOUD_LIGHT_ALTITUDE):GetLuminance() > SUN_TOA_ILLUMINANCE * atmosphere.GetTransmittance(sun_dir, CLOUD_LIGHT_ALTITUDE):GetLuminance()
	then
		clouds.SetLight(moon_dir, MOON_TINT * moon_illuminance)
	else
		clouds.SetLight(sun_dir, SUN_COLOR * SUN_TOA_ILLUMINANCE)
	end

	if not weather.light then return end

	local sun_transmittance = atmosphere.GetTransmittance(sun_dir)
	local moon_transmittance = atmosphere.GetTransmittance(moon_dir)
	local dir, color, illuminance

	if
		moon_illuminance * moon_transmittance:GetLuminance() > SUN_TOA_ILLUMINANCE * sun_transmittance:GetLuminance()
	then
		dir, color, illuminance = moon_dir, moon_transmittance * MOON_TINT, moon_illuminance
	else
		dir, color, illuminance = sun_dir, sun_transmittance * SUN_COLOR, SUN_TOA_ILLUMINANCE
	end

	weather.syncing_light = true
	weather.light.transform:SetRotation(weather.GetSunRotationFromDirection(dir))
	weather.syncing_light = false
	weather.light.light_sun:SetColor(Color(color.x, color.y, color.z, 1))
	clouds.SetShadowDirection(dir)
	local active = atmosphere.IsEnabled()
	weather.light.light_sun:SetLux(active and illuminance or 0)
	local transmittance = active and
		math.max(color.x, color.y, color.z) * clouds.GetMaxTransmittance(dir)
		or
		0

	for _, shadow_map in pairs(weather.shadow_maps) do
		shadow_map:SetEnabled(transmittance > SHADOW_CUTOFF_TRANSMITTANCE)
	end
end

commands.Add("envmap=string|nil,number|nil", function(path, intensity)
	if intensity then weather.SetEnvironmentMapIntensity(intensity) end

	weather.SetEnvironmentMap(path)
end)

local SUN_SHADOW_DEFAULTS = {
	cascades = {
		enabled = true,
		count = 1,
		size = 8192,
		format = "d16_unorm",
		distance = 1500,
		split_lambda = 0.5,
		zoom = {2, 1, 1, 1},
		min_caster_texel_size = 4,
		update_interval = 8,
		cache_far_cascade = true,
		far_cascade_move = 96,
	},
	exact = {
		enabled = true,
		size = 4096,
		format = "d32_sfloat",
		distance = 30,
		zoom = 4,
		min_caster_texel_size = 1,
		update_interval = 1,
	},
	bias = {normal = 1, light = 1},
}
local SUN_SHADOW_STRUCTURE = {enabled = true, count = true, size = true, format = true}
weather.sun_shadow = table.copy(SUN_SHADOW_DEFAULTS)

function weather.GetSunShadow(category)
	return table.copy(weather.sun_shadow[category])
end

local function apply_sun_shadow()
	directional_shadows.bias.normal = weather.sun_shadow.bias.normal
	directional_shadows.bias.light = weather.sun_shadow.bias.light
	local cascades = weather.sun_shadow.cascades
	local exact = weather.sun_shadow.exact
	local map = weather.shadow_maps.sun

	if not map then return end

	local offset = exact.enabled and 1 or 0
	local zoom, min_caster_texel_sizes, update_intervals = {}, {}, {}

	if exact.enabled then
		zoom[1] = exact.zoom
		min_caster_texel_sizes[1] = exact.min_caster_texel_size
		update_intervals[1] = exact.update_interval
		map.cascade_fixed_splits = {exact.distance}
	else
		map.cascade_fixed_splits = {}
	end

	for i = 1, map:GetCascadeCount() - offset do
		zoom[offset + i] = cascades.zoom[i]
		min_caster_texel_sizes[offset + i] = cascades.min_caster_texel_size
		update_intervals[offset + i] = cascades.update_interval
	end

	map.max_shadow_distance = cascades.enabled and cascades.distance or exact.distance
	map.cascade_split_lambda = cascades.split_lambda
	map.cascade_zoom_factors = zoom
	map.cascade_min_caster_texel_sizes = min_caster_texel_sizes
	map.cascade_update_intervals = update_intervals
	map:SetUpdatePolicy{
		shadow_update_mode = "continuous",
		farthest_cascade_update_mode = cascades.enabled and cascades.cache_far_cascade and "world_changed" or nil,
		farthest_cascade_camera_position_threshold = cascades.far_cascade_move,
	}
	map:Invalidate()
end

function weather.BuildSunShadows()
	for _, shadow_map in pairs(weather.shadow_maps) do
		shadow_map:Remove()
	end

	weather.shadow_maps = {}
	local cascades = weather.sun_shadow.cascades
	local exact = weather.sun_shadow.exact
	local scale = quality.Get().shadow_size_scale
	local config = {mode = "sun", light = weather.light}

	if cascades.enabled then
		config.size = Vec2() + cascades.size * scale
		config.format = cascades.format
		config.cascade_count = cascades.count
	end

	if exact.enabled then
		config.cascade_sizes = {Vec2() + exact.size * scale}
		config.cascade_formats = {exact.format}
		config.cascade_count = (config.cascade_count or 0) + 1

		if not cascades.enabled then
			config.size = config.cascade_sizes[1]
			config.format = exact.format
		end
	end

	if config.cascade_count then weather.shadow_maps.sun = ShadowMap.New(config) end

	apply_sun_shadow()
	weather.UpdateSky()
end

function weather.SetSunShadow(category, changes)
	local defaults = SUN_SHADOW_DEFAULTS[category]
	local settings = weather.sun_shadow[category]
	local rebuild = false

	for key, value in pairs(changes) do
		assert(defaults[key] ~= nil, "no sun shadow setting " .. category .. "." .. key)

		if SUN_SHADOW_STRUCTURE[key] and settings[key] ~= value then rebuild = true end

		settings[key] = table.copy(value)
	end

	if not weather.light then
		apply_sun_shadow()
		return
	end

	if rebuild then weather.BuildSunShadows() else apply_sun_shadow() end
end

function weather.ResetSunShadow()
	weather.sun_shadow = table.copy(SUN_SHADOW_DEFAULTS)

	if weather.light then weather.BuildSunShadows() else apply_sun_shadow() end
end

event.AddListener("RenderQualityChanged", "weather_sun_shadows", function()
	if weather.light then weather.BuildSunShadows() end
end)

function weather.Initialize()
	if weather.light and weather.light:IsValid() then return end

	weather.light = Entity.New{
		Name = "atmosphere",
		transform = {},
		light_sun = {
			Color = Color(1.0, 0.98, 1),
			Lux = SUN_TOA_ILLUMINANCE,
		},
		atmosphere_controller = {},
		Singleton = true,
		Transient = false,
	}
	weather.light:SetGUID("atmosphere")
	atmosphere.SetSunIlluminance(SUN_TOA_ILLUMINANCE)
	weather.BuildSunShadows()
	weather.shelter_caster = Entity.New{Name = "shelter_caster", transform = {}}
	weather.shelter_map = ShadowMap.New{
		mode = "directional",
		directional_projection_mode = "orthographic",
		light = weather.shelter_caster,
		size = Vec2() + SHELTER_SIZE,
		format = "d16_unorm",
		cascade_count = 1,
		ortho_size = SHELTER_HALF_SIZE,
		far_plane = SHELTER_DEPTH,
		role = "shelter",
	}
	weather.shelter_map:SetUpdatePolicy{shadow_update_mode = "on_move"}
	surface_weather.shelter_map = weather.shelter_map
	weather.UpdateSky()

	event.AddListener("Update", "weather_shelter", function(dt)
		weather.shelter_map:SetEnabled(
			precipitation.IsActive() or
				enabled:Get() and
				(
					surface_weather.wetness > 0 or
					surface_weather.snow_depth > 0
				)
		)

		if not weather.shelter_map.enabled then return end

		local wind = atmosphere.GetWind()
		local snowing = precipitation.GetSnow() > precipitation.GetRain() or
			precipitation.GetRain() == 0 and
			surface_weather.snow_depth > 0
		local fall_speed = snowing and
			SNOW_FALL_SPEED * (
				1 + surface_weather.GetSnowWetness()
			)
			or
			RAIN_FALL_SPEED
		surface_weather.precipitation_spread = (
				snowing and
				SNOW_SPREAD or
				RAIN_SPREAD
			) + WIND_TURBULENCE * math.sqrt(wind.x * wind.x + wind.z * wind.z) / fall_speed
		local wind_speed = math.sqrt(wind.x * wind.x + wind.z * wind.z)
		local slant = math.min(wind_speed / fall_speed, MAX_SHELTER_SLANT) / math.max(wind_speed, 0.0001)
		local dir = Vec3(-wind.x * slant, 1, -wind.z * slant):GetNormalized()
		local rotation = Quat(-dir.y, dir.x, 0, 1 + dir.z):Normalize()
		local right = rotation:GetRight()
		local up = rotation:GetUp()
		local step = SHELTER_HALF_SIZE * 2 / SHELTER_SIZE * SHELTER_SNAP_TEXELS
		local cam = render3d.GetCamera():GetPosition()
		surface_weather.precipitation_direction = dir
		weather.shelter_caster.transform:SetRotation(rotation)
		weather.shelter_caster.transform:SetPosition(
			right * (
					math.floor(cam:Dot(right) / step + 0.5) * step
				) + up * (
					math.floor(cam:Dot(up) / step + 0.5) * step
				) + dir * (
					math.floor(cam:Dot(dir) / step + 0.5) * step
				)
		)
	end)

	event.AddListener("Update", "weather", function(dt)
		clouds.Update(dt)

		if weather.time_scale == 0 then return end

		weather.time = weather.time + dt * weather.time_scale
		weather.UpdateSky()
	end)
end

return weather
