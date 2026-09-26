-- render3d first, material.lua can only load from inside it (material -> steam -> crylevel -> render3d -> material)
import("goluwa/render3d/render3d.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local weather = {}
local SUN_TOA_ILLUMINANCE = 126000
local SHADOW_CUTOFF_TRANSMITTANCE = 1e-5
weather.latitude = 21.176852
weather.longitude = 106.068101
-- 2026-06-21 10:00 local time at the default location
weather.time = 1782010800
weather.time_scale = 0
weather.sun_rotation_override = nil
weather.sun = nil
weather.shadow_maps = {}

-- world directions: east is +x, up is +y, north is -z
function weather.GetSunDirectionAt(unix_time, latitude, longitude)
	-- low precision solar position from the astronomical almanac, good to about 0.01 degrees
	local n = unix_time / 86400 - 10957.5
	local mean_longitude = math.rad(280.460 + 0.9856474 * n)
	local mean_anomaly = math.rad(357.528 + 0.9856003 * n)
	local ecliptic_longitude = mean_longitude + math.rad(1.915) * math.sin(mean_anomaly) + math.rad(0.020) * math.sin(2 * mean_anomaly)
	local obliquity = math.rad(23.439 - 0.0000004 * n)
	local right_ascension = math.atan2(math.cos(obliquity) * math.sin(ecliptic_longitude), math.cos(ecliptic_longitude))
	local declination = math.asin(math.sin(obliquity) * math.sin(ecliptic_longitude))
	local sidereal_time = math.rad((18.697374558 + 24.06570982441908 * n) * 15 + longitude)
	local hour_angle = sidereal_time - right_ascension
	local lat = math.rad(latitude)
	local east = -math.cos(declination) * math.sin(hour_angle)
	local north = math.cos(lat) * math.sin(declination) - math.sin(lat) * math.cos(declination) * math.cos(hour_angle)
	local up = math.sin(lat) * math.sin(declination) + math.cos(lat) * math.cos(declination) * math.cos(hour_angle)
	return Vec3(east, up, -north)
end

function weather.SetLocation(latitude, longitude)
	weather.latitude = latitude
	weather.longitude = longitude
	weather.UpdateSun()
end

function weather.GetLocation()
	return weather.latitude, weather.longitude
end

function weather.SetTime(unix_time)
	weather.time = unix_time
	weather.UpdateSun()
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
	weather.UpdateSun()
end

-- the sun light points along its rotation's backward vector, (0, 0, 1) unrotated
function weather.SetSunDirection(dir)
	weather.SetSunRotation(Quat(-dir.y, dir.x, 0, 1 + dir.z))
end

function weather.ClearSunRotation()
	weather.sun_rotation_override = nil
	weather.UpdateSun()
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

function weather.GetSun()
	return weather.sun
end

function weather.UpdateSun()
	if not weather.sun then return end

	local rotation = weather.GetSunRotation()
	weather.sun.transform:SetRotation(rotation)
	local sun_color = atmosphere.GetSunColor(rotation:GetBackward())
	weather.sun.light_sun:SetColor(Color(sun_color.x, sun_color.y, sun_color.z, 1))
	local transmittance = math.max(sun_color.x, sun_color.y, sun_color.z)

	for _, shadow_map in ipairs(weather.shadow_maps) do
		shadow_map:SetEnabled(transmittance > SHADOW_CUTOFF_TRANSMITTANCE)
	end
end

function weather.Initialize()
	weather.sun = Entity.New{
		Name = "sun",
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
			light = weather.sun,
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
			light = weather.sun,
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

	weather.UpdateSun()

	event.AddListener("Update", "weather", function(dt)
		if weather.time_scale == 0 then return end

		weather.time = weather.time + dt * weather.time_scale

		if not weather.sun_rotation_override then weather.UpdateSun() end
	end)
end

return weather
