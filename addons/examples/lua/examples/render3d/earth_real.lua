local earth = import("lua/earth/earth.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local weather = import("goluwa/render3d/weather.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local foliage_sets = import("lua/foliage/scatter_sets.lua")
local foliage = import("lua/foliage/foliage.lua")

local function layer(name, scale, scatter)
	local textures = terrain_textures[name]
	return {
		name = name,
		albedo = textures.albedo,
		normal = textures.normal,
		scale = scale,
		detail = 0.35,
		fade_distance = 600,
		scatter = scatter and 1 or 0,
	}
end

local function is_tree(definition)
	return definition.model:find("/trees/", 1, true) ~= nil
end

local function is_grass(definition)
	return definition.model:find("/grass/", 1, true) ~= nil
end

-- meadows on grass, undergrowth on the forest floor (the trees are the canopy map's, placed by the earth's objects),
-- scree on rock and a dense even crop on fields
local scatter_set = os.getenv("EARTH_SCATTER") ~= "0" and
	foliage_sets.Combine(
		{Name = "earth"},
		{
			{
				set = foliage_sets.foliage_meadow,
				layers = {1, 0, 0, 0},
				only = function(definition)
					return not is_tree(definition)
				end,
			},
			{
				set = foliage_sets.foliage_tropical,
				layers = {0, 1, 0, 0},
				only = function(definition)
					return not is_tree(definition)
				end,
			},
			{set = foliage_sets.foliage_rocky, layers = {0, 0, 1, 0}},
			{
				set = foliage_sets.foliage_meadow,
				layers = {0, 0, 0, 1},
				only = is_grass,
				override = {cluster = {scale = 4, amount = 0.15}},
			},
		}
	) or
	nil
earth.Start{
	lat = tonumber(os.getenv("EARTH_LAT")),
	lon = tonumber(os.getenv("EARTH_LON")),
	Layers = {
		layer("grass", 3, true),
		layer("dirt", 3, true),
		layer("rock", 11, true),
		layer("grass", 3, true),
		layer("sand", 4),
		layer("snow", 7),
		layer("dirt", 3),
		layer("gravel", 2.5),
	},
	Terrain = {Levels = tonumber(os.getenv("LEVELS")) or 15, ScatterSet = scatter_set},
	Clouds = true,
	Buildings = true,
	Water = true,
	Land = os.getenv("EARTH_LAND") ~= "0",
	Roads = os.getenv("EARTH_ROADS") ~= "0",
	RoadMesh = os.getenv("EARTH_ROADS") ~= "0" and os.getenv("EARTH_ROAD_MESH") ~= "0",
	Canopy = os.getenv("EARTH_CANOPY") ~= "0",
	Weather = os.getenv("EARTH_WEATHER") ~= "0",
	Objects = os.getenv("EARTH_OBJECTS") ~= "0" and
		{
			Trees = {
				foliage.GetModelPath("trees", "oak_a"),
				foliage.GetModelPath("trees", "oak_b"),
				foliage.GetModelPath("trees", "palm_a"),
				foliage.GetModelPath("trees", "palm_b"),
			},
			Canopy = os.getenv("EARTH_CANOPY") ~= "0",
			TreeHeight = 12,
		} or
		nil,
}
weather.SetTimeScale(1)
weather.SetTime(os.time())

if os.getenv("EARTH_HOUR") then
	weather.SetTimeScale(0)
	weather.SetSolarHours(tonumber(os.getenv("EARTH_HOUR")))
end

render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{
	WindSpeed = 8,
	WindDirection = 0,
	WindFromClimate = os.getenv("EARTH_WEATHER") ~= "0",
}
return earth
