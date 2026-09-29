-- render3d first, material.lua can only load from inside it (material -> steam -> crylevel -> render3d -> material)
local render3d = import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local precipitation = import("goluwa/render3d/precipitation.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local weather = {}
local SUN_TOA_ILLUMINANCE = 126000
local SHADOW_CUTOFF_TRANSMITTANCE = 1e-5
local EARTH_RADIUS_KM = 6371
local MOON_RADIUS_KM = 1737.4
local MOON_MEAN_DISTANCE_KM = 384400
local SUN_TINT = Vec3(1.0, 0.98, 0.95)
-- moonlight is sunlight off a slightly red rock
local MOON_TINT = SUN_TINT * Vec3(1.0, 0.94, 0.86)
-- a 2 mm raindrop's terminal velocity (Gunn and Kinzer 1949), the wind slants the rain by it
local RAIN_FALL_SPEED = 6.5
-- a dry snowflake's (Locatelli and Hobbs 1974), wet ones fall about twice as fast
local SNOW_FALL_SPEED = 1
-- how far rain and snow stray from their mean direction in still air, as the tangent of the angle:
-- flakes flutter and tumble, drops fall nearly straight
local RAIN_SPREAD = 0.05
local SNOW_SPREAD = 0.3
-- the wind's gusts near the ground, its turbulence intensity, stray them further
local WIND_TURBULENCE = 0.25
-- the shelter's edges are softened by meters, finer texels would be wasted
local SHELTER_SIZE = 1024
-- half the width of the ground the shelter map covers around the camera, in meters
local SHELTER_HALF_SIZE = 96
local SHELTER_DEPTH = 600
-- the map follows the camera in steps of this many texels and only renders again when it moves
local SHELTER_SNAP_TEXELS = 64
-- the clouds are lit by whichever of the sun and the moon is brighter up here, the sun still lights
-- them for a while after it set on the ground
local CLOUD_LIGHT_ALTITUDE = Vec3(0, 2000, 0)
weather.latitude = 21.176852
weather.longitude = 106.068101
-- 2026-06-21 10:00 local time at the default location
weather.time = 1782010800
weather.time_scale = 0
-- the drawn moon's size relative to the real 0.52 degrees, the eye sees it bigger than a camera does
weather.moon_scale = 1
-- off: no sun, moon, sky, air, fog, rain or snow, a black void
weather.enabled = true
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

-- the angle the earth has turned at this longitude, from facing the vernal equinox
local function get_sidereal(unix_time, longitude)
	return math.rad((18.697374558 + 24.06570982441908 * days_since_j2000(unix_time)) * 15 + longitude)
end

-- the rows turn a world direction into an equatorial one (x toward the vernal equinox, z the celestial
-- north pole), the sky turns around the pole once a sidereal day
-- world directions: east is +x, up is +y, north is -z
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

-- low precision solar position from the astronomical almanac, good to about 0.01 degrees
local function get_sun_equatorial(unix_time)
	local n = days_since_j2000(unix_time)
	local mean_longitude = math.rad(280.460 + 0.9856474 * n)
	local mean_anomaly = math.rad(357.528 + 0.9856003 * n)
	local ecliptic_longitude = mean_longitude + math.rad(1.915) * math.sin(mean_anomaly) + math.rad(0.020) * math.sin(2 * mean_anomaly)
	return ecliptic_to_equatorial(ecliptic_longitude, 0, math.rad(23.439 - 0.0000004 * n))
end

-- low precision lunar position from the astronomical almanac, good to a few tenths of a degree
-- returns the geocentric equatorial direction and the distance in km
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

-- the moon's direction from the observer (so shifted by up to a degree from the earth's center),
-- its distance in km and its top of atmosphere illuminance in lux
function weather.GetMoonAt(unix_time, latitude, longitude)
	local equatorial, distance = get_moon_equatorial(unix_time)
	local geocentric = equatorial_to_world(equatorial, weather.GetCelestialRotationAt(unix_time, latitude, longitude))
	local topocentric = geocentric * distance - Vec3(0, EARTH_RADIUS_KM, 0)
	distance = topocentric:GetLength()
	-- phase angle, sun to moon to observer, the sun being far enough to use its direction from here
	local phase_angle = math.deg(math.acos(math.clamp(-get_sun_equatorial(unix_time):GetDot(equatorial), -1, 1)))
	-- allen's lunar magnitude by phase, with magnitude 0 at 2.08e-6 lux
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

function weather.GetTimeScale()
	return weather.time_scale
end

do
	local SIDEREAL_RADIANS_PER_SECOND = math.rad(24.06570982441908 * 15) / 86400
	local MAX_LATITUDE = math.rad(89)
	-- just under the obliquity so the date search always finds a day that reaches it
	local MAX_SIN_DECLINATION = math.sin(math.rad(23.43))
	local LATITUDE_STEP = math.rad(0.1)
	-- how many degrees of latitude moving the date by one degree of declination is worth
	local DECLINATION_COST = 2
	-- and how much each degree past the polar circles costs on top, so the sun doesn't end up
	-- somewhere nobody lives
	local POLAR_LATITUDE = math.rad(66.5)
	local POLAR_COST = 4

	local function wrap_angle(a)
		return (a + math.pi) % (2 * math.pi) - math.pi
	end

	-- moves the latitude, the date and the time of day to where and when the sun stands in dir, the
	-- longitude stays. the celestial pole (0, sin(lat), -cos(lat)) has to be 90 degrees minus the sun's
	-- declination away from dir, so each latitude asks for a declination and so a date. the latitude
	-- that needs the least change of both is kept. then the time of day turns the sky around the pole
	-- until the sun is in dir, the nearest such time to the current one is kept
	function weather.SetSunDirection(dir)
		local time = weather.time
		local latitude = math.rad(weather.latitude)
		local r = math.sqrt(dir.y * dir.y + dir.z * dir.z)
		local theta = math.atan2(-dir.z, dir.y)
		local declination = math.asin(get_sun_equatorial(time).z)

		do
			local best, best_declination, best_cost = latitude, declination, math.huge
			local roots = math.asin(math.clamp(math.sin(declination) / r, -1, 1))
			-- the exact latitudes for today's declination first, then the others on a grid
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

			-- the nearest day, before or after, that the declination passes the one needed
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

		-- the declination drifts a little with the date and time found, so settle the exact latitude
		-- nearest the chosen one and the time of day together
		for _ = 1, 4 do
			local sun = get_sun_equatorial(time)
			local roots = math.asin(math.clamp(sun.z / r, -1, 1))
			local a = wrap_angle(roots - theta)
			local b = wrap_angle(math.pi - roots - theta)
			latitude = math.clamp(math.abs(a - latitude) < math.abs(b - latitude) and a or b, -math.pi / 2, math.pi / 2)
			local meridian = math.cos(latitude) * dir.y + math.sin(latitude) * dir.z
			local sidereal = math.atan2(sun.y, sun.x) - math.atan2(dir.x, meridian)
			time = time + wrap_angle(sidereal - get_sidereal(time, weather.longitude)) / SIDEREAL_RADIANS_PER_SECOND
		end

		weather.latitude = math.deg(latitude)
		weather.time = time
		weather.UpdateSky()
	end
end

-- the sun light points along its rotation's backward vector, (0, 0, 1) unrotated
function weather.SetSunRotation(rotation)
	weather.SetSunDirection(rotation:GetBackward())
end

-- yaw around up, then pitch around the horizontal right axis, no roll
function weather.GetSunRotation()
	local dir = weather.GetSunDirection()
	return QuatFromAxis(math.atan2(dir.x, dir.z), Vec3(0, 1, 0)) * QuatFromAxis(-math.asin(dir.y), Vec3(1, 0, 0))
end

function weather.GetSunDirection()
	return weather.GetSunDirectionAt(weather.time, weather.latitude, weather.longitude)
end

-- meteorological visibility at sea level in meters
function weather.SetVisibility(meters)
	atmosphere.SetVisibility(meters)
end

function weather.GetVisibility()
	return atmosphere.GetVisibility()
end

-- velocity in m/s, only x and z bend vegetation
function weather.SetWind(velocity)
	atmosphere.SetWind(velocity)
end

function weather.GetWind()
	return atmosphere.GetWind()
end

-- air temperature near the ground in degrees celsius. snow near and above freezing is wet: it falls in
-- bigger, faster flakes and lies darker and smoother
function weather.SetTemperature(celsius)
	atmosphere.SetTemperature(celsius)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetTemperature()
	return atmosphere.GetTemperature()
end

-- the falling rain in mm/h: 1 is light rain, 5 moderate, 25 heavy, 100 a cloudburst. it only falls, what
-- it leaves on surfaces is SetWetness
function weather.SetRain(mm_per_hour)
	precipitation.SetRain(mm_per_hour)
	surface_weather.rain_impact_rate = precipitation.GetRainImpactRate(surface_weather.AGITATION_MIN_DIAMETER)
	surface_weather.splash_rate = precipitation.GetRainImpactRate(surface_weather.SPLASH_MIN_DIAMETER)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetRain()
	return precipitation.GetRain()
end

-- the falling snow in mm/h of melted water: 0.5 is light snow, 1 moderate, 3 heavy. it only falls, what
-- lies on the ground is SetSnowDepth
function weather.SetSnow(mm_per_hour)
	precipitation.SetSnow(mm_per_hour)
	atmosphere.SetPrecipitationExtinction(precipitation.GetExtinction())
end

function weather.GetSnow()
	return precipitation.GetSnow()
end

-- 0 is dry, 1 is soaked. sheltered and downward facing surfaces stay dry
function weather.SetWetness(wetness)
	surface_weather.wetness = wetness
end

function weather.GetWetness()
	return surface_weather.wetness
end

-- meters of snow on open, flat ground: 0.01 is a dusting that lies in patches, 0.05 and more hides the
-- ground. it slides off steep slopes and sheltered and downward facing surfaces stay bare
function weather.SetSnowDepth(meters)
	surface_weather.snow_depth = meters
end

function weather.GetSnowDepth()
	return surface_weather.snow_depth
end

-- a list of layers, see clouds.LAYER_DEFAULTS for their fields. render3d/climate.lua has presets
function weather.SetCloudLayers(layers)
	clouds.SetLayers(layers)
	weather.UpdateSky()
end

function weather.GetCloudLayers()
	return clouds.GetLayers()
end

-- the fraction of the sky the clouds hide
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

-- the directional light, aimed at whichever of the sun and the moon lights the ground more
function weather.SetEnabled(enabled)
	weather.enabled = enabled
	atmosphere.SetEnabled(enabled)
	weather.UpdateSky()
end

function weather.IsEnabled()
	return weather.enabled
end

function weather.GetLight()
	return weather.light
end

function weather.GetMoonDirection()
	return (weather.GetMoonAt(weather.time, weather.latitude, weather.longitude))
end

local function luminance(v)
	return v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722
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
		moon_illuminance * luminance(atmosphere.GetTransmittance(moon_dir, CLOUD_LIGHT_ALTITUDE)) > SUN_TOA_ILLUMINANCE * luminance(atmosphere.GetTransmittance(sun_dir, CLOUD_LIGHT_ALTITUDE))
	then
		clouds.SetLight(moon_dir, MOON_TINT * moon_illuminance)
	else
		clouds.SetLight(sun_dir, SUN_TINT * SUN_TOA_ILLUMINANCE)
	end

	if not weather.light then return end

	local sun_transmittance = atmosphere.GetTransmittance(sun_dir)
	local moon_transmittance = atmosphere.GetTransmittance(moon_dir)
	local dir, color, illuminance

	-- they cross over while both are close to nothing, so the switch is continuous
	if
		moon_illuminance * luminance(moon_transmittance) > SUN_TOA_ILLUMINANCE * luminance(sun_transmittance)
	then
		dir, color, illuminance = moon_dir, moon_transmittance * MOON_TINT, moon_illuminance
	else
		dir, color, illuminance = sun_dir, sun_transmittance * SUN_TINT, SUN_TOA_ILLUMINANCE
	end

	weather.light.transform:SetRotation(Quat(-dir.y, dir.x, 0, 1 + dir.z):Normalize())
	weather.light.light_sun:SetColor(Color(color.x, color.y, color.z, 1))
	-- the clouds' shadow map takes the direct light where they are, see render3d/clouds.lua
	clouds.SetShadowDirection(dir)
	weather.light.light_sun:SetLux(weather.enabled and illuminance or 0)
	-- no shadow maps under an overcast without gaps
	local transmittance = weather.enabled and
		math.max(color.x, color.y, color.z) * clouds.GetMaxTransmittance(dir)
		or
		0

	for _, shadow_map in ipairs(weather.shadow_maps) do
		shadow_map:SetEnabled(transmittance > SHADOW_CUTOFF_TRANSMITTANCE)
	end
end

function weather.Initialize()
	if weather.light and weather.light:IsValid() then return end

	weather.light = Entity.New{
		Name = "sky_light",
		transform = {},
		light_sun = {
			Color = Color(1.0, 0.98, 1),
			Lux = SUN_TOA_ILLUMINANCE,
		},
	}
	atmosphere.SetSunIlluminance(SUN_TOA_ILLUMINANCE)
	weather.shadow_maps = {
		ShadowMap.New{
			mode = "sun",
			light = weather.light,
			size = Vec2() + 4096,
			cascade_count = 2,
			cascade_formats = {
				"d16_unorm",
				"d16_unorm",
			},
			cascade_sizes = {
				Vec2() + 4096,
				Vec2() + 4096,
			},
			cascade_zoom_factors = {
				3,
				1,
			},
			soup_cascade_from = 1,
			cascade_split_lambda = 0,
			max_shadow_distance = 2700,
			near_plane = 1,
			far_plane = 2700,
		},
		ShadowMap.New{
			mode = "sun",
			light = weather.light,
			size = Vec2() + 4096,
			cascade_count = 1,
			cascade_sizes = {Vec2() + 4096},
			cascade_formats = {"d16_unorm"},
			cascade_zoom_factors = {1.75},
			min_caster_texel_size = 1,
			cascade_split_lambda = 1,
			max_shadow_distance = 16,
			ortho_size = 50,
			near_plane = 1,
			far_plane = 16,
			role = "inset",
		},
	}

	for _, shadow_map in ipairs(weather.shadow_maps) do
		shadow_map:SetUpdatePolicy{
			shadow_update_mode = "continuous",
			shadow_update_interval = 2,
			farthest_cascade_update_mode = "world_changed",
			farthest_cascade_camera_position_threshold = 96,
		}
	end

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

	-- the shelter map follows the camera, looking along the falling rain or snow, whichever is heavier.
	-- what lies on surfaces is sheltered along the same direction
	event.AddListener("Update", "weather_shelter", function(dt)
		weather.shelter_map:SetEnabled(
			precipitation.IsActive() or
				weather.enabled and
				(
					surface_weather.wetness > 0 or
					surface_weather.snow_depth > 0
				)
		)

		if not weather.shelter_map.enabled then return end

		local wind = atmosphere.GetWind()
		-- the snow lying on the ground fell as snow
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
		local dir = Vec3(-wind.x, fall_speed, -wind.z):GetNormalized()
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

commands.Add("weather_enabled=boolean[true]", function(enabled)
	weather.SetEnabled(enabled)
end)

return weather
