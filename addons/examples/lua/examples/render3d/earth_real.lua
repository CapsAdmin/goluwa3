local earth = import("lua/earth/earth.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local weather = import("goluwa/render3d/weather.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {
		name = name,
		albedo = textures.albedo,
		normal = textures.normal,
		scale = scale,
		detail = 0.35,
		fade_distance = 600,
	}
end

earth.Start{
	lat = tonumber(os.getenv("EARTH_LAT")),
	lon = tonumber(os.getenv("EARTH_LON")),
	Layers = {layer("grass", 3), layer("sand", 4), layer("rock", 11), layer("snow", 7)},
	Terrain = {Levels = tonumber(os.getenv("LEVELS")) or 15},
	Clouds = true,
	Buildings = true,
}
weather.SetTimeScale(0)

if os.getenv("EARTH_HOUR") then
	weather.SetSolarHours(tonumber(os.getenv("EARTH_HOUR")))
end

render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{WindSpeed = 8, WindDirection = 0}
return earth
