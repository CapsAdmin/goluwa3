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
local SHELTER_SIZE = 2048
-- half the width of the ground the shelter map covers around the camera, in meters
local SHELTER_HALF_SIZE = 96
local SHELTER_DEPTH = 600
-- the map follows the camera in steps of this many texels and only renders again when it moves
local SHELTER_SNAP_TEXELS = 128
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
weather.sun_rotation_override = nil
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

-- the rows turn a world direction into an equatorial one (x toward the vernal equinox, z the celestial
-- north pole), the sky turns around the pole once a sidereal day
-- world directions: east is +x, up is +y, north is -z
function weather.GetCelestialRotationAt(unix_time, latitude, longitude)
	local sidereal = math.rad((18.697374558 + 24.06570982441908 * days_since_j2000(unix_time)) * 15 + longitude)
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

function weather.SetSunRotation(rotation)
	weather.sun_rotation_override = rotation:GetNormalized()
	weather.UpdateSky()
end

-- the sun light points along its rotation's backward vector, (0, 0, 1) unrotated
function weather.SetSunDirection(dir)
	weather.SetSunRotation(Quat(-dir.y, dir.x, 0, 1 + dir.z))
end

function weather.ClearSunRotation()
	weather.sun_rotation_override = nil
	weather.UpdateSky()
end

function weather.GetSunRotation()
	if weather.sun_rotation_override then
		return weather.sun_rotation_override:Copy()
	end

	local dir = weather.GetSunDirectionAt(weather.time, weather.latitude, weather.longitude)
	return Quat(-dir.y, dir.x, 0, 1 + dir.z):Normalize()
end

function weather.GetSunDirection()
	return weather.GetSunRotation():GetBackward()
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

-- 0 is a clear sky, 1 a full overcast that hides the sun. in between, cumulus that grow and spread
-- into stratocumulus. SetClouds picks the kind of clouds instead
function weather.SetCloudCover(cover)
	clouds.SetCover(cover)
	weather.UpdateSky()
end

-- the fraction of the sky the clouds hide
function weather.GetCloudCover()
	return clouds.GetCover()
end

-- the name of one of render3d/clouds.lua's presets (clear, fair, cumulus, congestus, stratocumulus,
-- altocumulus, altostratus, overcast, rain, storm, cirrus, cirrostratus, mixed), or a list of layers,
-- see clouds.LAYER_DEFAULTS for their fields
function weather.SetClouds(clouds_or_preset)
	if type(clouds_or_preset) == "string" then
		clouds.SetPreset(clouds_or_preset)
	else
		clouds.SetLayers(clouds_or_preset)
	end

	weather.UpdateSky()
end

-- the preset's name, or the layers when they were set by hand
function weather.GetClouds()
	return clouds.GetPreset() or clouds.GetLayers()
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
			size = Vec2() + 2048,
			cascade_count = 3,
			cascade_formats = {
				"d16_unorm",
				"d16_unorm",
				"d16_unorm",
			},
			cascade_sizes = {
				Vec2() + 2048,
				Vec2() + 2048,
				Vec2() + 2048,
			},
			cascade_zoom_factors = {
				3,
				1.5,
				1,
			},
			soup_cascade_from = 2,
			disable_vertex_animation_cascades = {[3] = true},
			cascade_split_lambda = 0.5,
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
		local fall_speed = precipitation.GetSnow() > precipitation.GetRain() and
			SNOW_FALL_SPEED * (
				1 + surface_weather.GetSnowWetness()
			)
			or
			RAIN_FALL_SPEED
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

		if not weather.sun_rotation_override then weather.UpdateSky() end
	end)
end

commands.Add("weather_enabled=boolean[true]", function(enabled)
	weather.SetEnabled(enabled)
end)

commands.Add("clouds=string", function(preset)
	weather.SetClouds(preset)
end)

commands.Add("cloud_cover=number", function(cover)
	weather.SetCloudCover(cover)
end)

return weather
