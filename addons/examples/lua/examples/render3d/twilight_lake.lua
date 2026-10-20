-- a mountain lake at the last of the sun: snow capped ridges over a lake of calm water, forest on the western hills,
-- a meadow in the east, and a camp on the south shore with a pier, a glass pavilion, lanterns and a fire. the sun is a
-- few degrees above the ridge behind the camera, the clouds are lit from below and the valley is hazy.
-- luajit glw --3d lua "import('addons/examples/lua/examples/render3d/twilight_lake.lua')"
-- `twilight_view N` goes to a view (0 lists them and gives the camera back), `twilight_tour` flies through them,
-- `twilight_sun` and `twilight_weather` change the sky (docs/twilight-lake.md)
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local water = import("goluwa/render3d/water.lua")
local pvars = import("goluwa/cli/pvars.lua")
local weather = import("goluwa/render3d/weather.lua")
local climate = import("goluwa/render3d/climate.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local View = import("goluwa/render3d/view.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local sets = import("lua/foliage/scatter_sets.lua")
local twilight = {}
-- the layout in meters, x east, z south, the camera looks north (-z) over the lake. the same numbers are in the glsl
local LAKE = Vec3(0, 0, -330)
local LAKE_RADII = {330, 250}
local CAMP = Vec3(0, 0, -25)
local CAMP_HEIGHT = 3.4
local HILLS_WEST = Vec3(-520, 0, -60)
local HILLS_EAST = Vec3(470, 0, -140)
local SUN_ELEVATION = tonumber(os.getenv("TWILIGHT_SUN_ELEVATION") or 4)
local SUN_AZIMUTH = tonumber(os.getenv("TWILIGHT_SUN_AZIMUTH") or 145)
local HEIGHT_GLSL = (
	[=[
const vec2 LAKE = vec2(%f, %f);
const vec2 LAKE_RADII = vec2(%f, %f);
const vec2 CAMP = vec2(%f, %f);
const float CAMP_HEIGHT = %f;
const vec2 HILLS_WEST = vec2(%f, %f);
const vec2 HILLS_EAST = vec2(%f, %f);

float lake_distance(vec2 p) {
	return length((p - LAKE) / LAKE_RADII);
}

// low ground round the lake, rolling away from it, the wooded hills in the west and the meadow rise in the east
float land_height(vec2 p) {
	float d = lake_distance(p);
	float rolling = 2.5 * sin(p.x * 0.011 + 0.7) * cos(p.y * 0.013) + 1.5 * sin(p.x * 0.027 + p.y * 0.019 + 1.3);
	float h = 2.0 + 4.0 * smoothstep(0.9, 1.6, d) + rolling * smoothstep(0.95, 1.8, d);
	vec2 w = (p - HILLS_WEST) / vec2(380.0, 300.0);
	vec2 e = (p - HILLS_EAST) / vec2(320.0, 260.0);
	h += (52.0 * exp(-dot(w, w)) + 28.0 * exp(-dot(e, e))) * smoothstep(1.0, 1.7, d);
	return h + 16.0 * smoothstep(1.2, 2.8, d);
}

// the ridges that close the valley, rising from 2.2 lake radii out, lower behind the camp
float mountain_height(vec2 p, float bake_step) {
	float ring = smoothstep(2.2, 6.0, lake_distance(p));
	float behind = mix(0.45, 1.0, smoothstep(250.0, -500.0, p.y));
	float ridges = pn_ridged_lod(p / 1100.0 + vec2(8.0, 3.0), 6, 1.0, 2.0, 1100.0, bake_step);
	float mass = pn_fbm_lod(p / 2500.0 + vec2(2.0, 9.0), 3, 2500.0, bake_step);
	return ring * behind * (160.0 + 900.0 * ridges + 250.0 * mass);
}

float camp_amount(vec2 p) {
	return smoothstep(75.0, 28.0, length(p - CAMP));
}

float terrain_height(vec2 p) {
	float bake_step = terrain_bake_step();
	float h = land_height(p) + mountain_height(p, bake_step);
	h = mix(h, -9.0, smoothstep(1.18, 0.62, lake_distance(p)));
	float camp = camp_amount(p);
	float detail = pn_fbm_lod(p / 40.0, 3, 40.0, bake_step);
	return mix(h, CAMP_HEIGHT, camp) + detail * 0.8 * (1.0 - camp);
}
]=]
):format(
	LAKE.x,
	LAKE.z,
	LAKE_RADII[1],
	LAKE_RADII[2],
	CAMP.x,
	CAMP.z,
	CAMP_HEIGHT,
	HILLS_WEST.x,
	HILLS_WEST.z,
	HILLS_EAST.x,
	HILLS_EAST.z
)
-- the layers: x the meadow, y the forest floor, z rock, w the camp's short lawn, and then sand on the beach
local SPLAT_GLSL = [=[
float forest_amount(vec2 p, float breakup) {
	float west = smoothstep(1.0, 0.45, length((p - HILLS_WEST) / vec2(520.0, 420.0)) + breakup * 0.5);
	float groves = smoothstep(0.6, 0.72, pn_fbm(p * 0.005 + vec2(11.0, 2.0), 3) * 0.5 + 0.5);
	return clamp(max(west, groves * 0.9) * (1.0 - camp_amount(p)), 0.0, 1.0);
}

vec4 terrain_splat(vec2 p, float h, vec3 n) {
	float slope = 1.0 - n.y;
	float fine = pn_fbm(p * 0.03 + vec2(9.0, -4.0), 3) * 0.5;
	float breakup = pn_fbm(p * 0.006 + vec2(3.0, 5.0), 3) * 0.5;
	float rock = smoothstep(0.2, 0.38, slope + fine * 0.1);
	rock = max(rock, smoothstep(220.0, 340.0, h + breakup * 60.0));
	float camp = smoothstep(0.25, 0.9, camp_amount(p) + fine * 0.2) * (1.0 - rock);
	float forest = forest_amount(p, breakup);
	vec4 w;
	w.w = camp;
	w.z = rock;
	w.y = forest * (1.0 - rock) * (1.0 - camp);
	w.x = max(1.0 - w.w - w.z - w.y, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
-- layers five and six: sand on the beach, and the snow, which is laid over the rest by its cover rule
local SPLAT2_GLSL = [=[
vec4 terrain_splat2(vec2 p, float h, vec3 n) {
	float fine = pn_fbm(p * 0.03 + vec2(9.0, -4.0), 3) * 0.5;
	float sand = 1.0 - smoothstep(0.7, 2.2, h + fine * 1.4);
	return vec4(sand, 0.0, 0.0, 0.0);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	float patches = pn_fbm(world * 0.008 + vec2(1.0, 7.0), 3);
	float shade = 0.92 + pn_fbm(world * 0.003 + vec2(8.0, 3.0), 2) * 0.1;
	vec3 lush = vec3(0.72, 1.0, 0.5);
	vec3 dry = vec3(1.0, 0.9, 0.62);
	float wet = 1.0 - smoothstep(0.0, 1.5, h);
	float green = 1.0 - smoothstep(60.0, 220.0, h);
	vec3 tint = mix(vec3(1.0), mix(lush, dry, smoothstep(0.1, 0.5, patches) * 0.5), green);
	return clamp(tint * shade * (1.0 - wet * 0.35), 0.0, 1.0);
}
]=]

-- the height without the glsl's small noise (at most 0.8 m off), and exactly the camp's on its plateau
function twilight.GetHeight(x, z)
	local lake_d = math.sqrt(((x - LAKE.x) / LAKE_RADII[1]) ^ 2 + ((z - LAKE.z) / LAKE_RADII[2]) ^ 2)
	local rolling = 2.5 * math.sin(x * 0.011 + 0.7) * math.cos(z * 0.013) + 1.5 * math.sin(x * 0.027 + z * 0.019 + 1.3)
	local h = 2 + 4 * math.smoothstep(0.9, 1.6, lake_d) + rolling * math.smoothstep(0.95, 1.8, lake_d)
	local wx, wz = (x - HILLS_WEST.x) / 380, (z - HILLS_WEST.z) / 300
	local ex, ez = (x - HILLS_EAST.x) / 320, (z - HILLS_EAST.z) / 260
	h = h + (
			52 * math.exp(-(wx * wx + wz * wz)) + 28 * math.exp(-(ex * ex + ez * ez))
		) * math.smoothstep(1.0, 1.7, lake_d)
	h = h + 16 * math.smoothstep(1.2, 2.8, lake_d)
	h = math.lerp(math.smoothstep(1.18, 0.62, lake_d), h, -9)
	local camp = math.smoothstep(75, 28, math.sqrt((x - CAMP.x) ^ 2 + (z - CAMP.z) ^ 2))
	return math.lerp(camp, h, CAMP_HEIGHT)
end

-- the foliage sets in one, each growing on its own layer. the camp's lawn only gets the grass, flowers and pebbles, shorter
local function build_scatter_set()
	local prototypes = {}

	local function add(set, layers, altitude, density, keep, overrides)
		for _, definition in ipairs(set.Prototypes) do
			if not keep or keep(definition) then
				local copy = {}

				for key, value in pairs(definition) do
					copy[key] = value
				end

				copy.layers = layers
				copy.altitude = altitude
				copy.density = definition.density * (density or 1)

				for key, value in pairs(overrides or {}) do
					copy[key] = value
				end

				prototypes[#prototypes + 1] = copy
			end
		end
	end

	local function is_ground_cover(definition)
		return definition.model:find("grass") or
			definition.model:find("pebbles") or
			definition.model:find("plants/[a-z]*s_a")
	end

	add(sets.foliage_meadow, {1, 0, 0, 0}, {1.2, 260, 4}, 2)
	add(sets.foliage_forest, {0, 1, 0, 0}, {1.2, 330, 6}, 2.5)
	add(sets.foliage_rocky, {0, 0.2, 1, 0}, {1.2, 480, 10}, 1.5)
	add(
		sets.foliage_meadow,
		{0, 0, 0, 1},
		{1.2, 20, 2},
		1.4,
		is_ground_cover,
		{scale = {0.45, 0.7}, height = {0.7, 0.9}}
	)
	add(sets.foliage_wetland, {1, 0.3, 0, 0}, {-0.3, 2.5, 0.6}, 1.2)
	return ScatterSet.New{Name = "twilight_lake", Prototypes = prototypes, DistanceMultiplier = 1.5}
end

local function layer(name, scale, extra)
	local textures = terrain_textures[name]
	local out = {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}

	for key, value in pairs(extra or {}) do
		out[key] = value
	end

	return out
end

if _G.twilight_lake then _G.twilight_lake.Remove() end

-- more than four layers need SelectChunkLayers: it hands each chunk the layers and their ids, and the ids of a fifth
-- layer is what makes the source bake the second weight texture
local LAYERS = {
	layer("grass", 3, {scatter = 1, anti_tiling = 1, far_scale = 29, far_distance = 240}),
	layer("dirt", 3, {scatter = 1, anti_tiling = 1}),
	layer("rock", 11, {scatter = 1, anti_tiling = 1, far_scale = 70, far_distance = 600}),
	layer("grass", 3, {scatter = 1, anti_tiling = 1}),
	layer("sand", 4),
	layer(
		"snow",
		7,
		{
			cover_slope = 0.5,
			cover_start = 330,
			cover_range = 520,
			cover_power = 0.8,
			cover_blend = 0.06,
		}
	),
}
local LAYER_IDS = {1, 2, 3, 4, 5, 6}
twilight.scatter_set = build_scatter_set()
twilight.terrain = Terrain.New{
	Name = "twilight_lake",
	ScatterSet = twilight.scatter_set,
	Source = ShaderSource.New{
		Header = noise.WORLD,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		Splat2GLSL = SPLAT2_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -20,
		MaxHeight = 1500,
		Layers = LAYERS,
		SelectChunkLayers = function()
			return LAYERS, LAYER_IDS
		end,
	},
	Levels = 9,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 6,
	ShadowExtent = 8192,
	BuildsPerFrame = 2,
	BVHStride = 2,
	BVHNearStride = 1,
	Physics = {chunk_size = 64, samples = 65, radius = 2},
}:Start()
twilight.root = Entity.New{Name = "twilight_lake", Parent = Entity.World}
twilight.root:AddComponent("transform")
-- sun, sky, water
local sun_elevation = math.rad(SUN_ELEVATION)
local sun_azimuth = math.rad(SUN_AZIMUTH)
weather.SetTimeScale(0)
weather.SetSunDirection(
	Vec3(
		-math.sin(sun_azimuth) * math.cos(sun_elevation),
		math.sin(sun_elevation),
		-math.cos(sun_azimuth) * math.cos(sun_elevation)
	)
)
climate.SetPreset(
	{
		clouds = {
			{
				name = "low",
				bottom = 1500,
				thickness = 1400,
				coverage = 0.38,
				density = 0.07,
				type = 1,
				detail_scale = 250,
				base_variation = 150,
				wind_scale = 3,
			},
			{
				name = "high",
				bottom = 9500,
				thickness = 400,
				coverage = 0.5,
				density = 0.25,
				flat = true,
				weather_scale = 30000,
				shape_scale = 6000,
				wind_scale = 6,
			},
		},
		aerosol_visibility = 35000,
		ground_fog_visibility = 60000,
	},
	0
)
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{
	WindSpeed = tonumber(os.getenv("TWILIGHT_WIND") or 3.5),
	WindDirection = 200,
	Choppiness = 0.4,
	SwellHeight = 0.06,
	SwellWavelength = 40,
	Absorption = water.presets.lake.Absorption:Copy(),
	ParticleScattering = water.presets.lake.ParticleScattering:Copy(),
}
-- the camp: a pier down to a torii in the lake, a glass pavilion, a fire and its seats, lanterns, a pair of
-- pedestals at the head of the pier with a gold sphere and a glass one, crystals on the shore
local ground = twilight.GetHeight
local root = twilight.root
local DECK_X = 0
local RAMP_START, PIER_END = -52, -108
local DECK_TOP_LOW = 1.4
local PIER_WIDTH = 2.6
local TORII_Z = -116
local PAVILION = Vec3(-15, CAMP_HEIGHT, -63)
local FIRE = Vec3(15, CAMP_HEIGHT, -34)
-- a glsl header for the wood: value noise, and boards laid along u and stacked along v
local WOOD_HEADER = [=[
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float sum = 0.0;
	float amp = 0.5;

	for (int i = 0; i < 5; i++) {
		sum += vnoise(p) * amp;
		p = p * 2.03 + vec2(3.1, 1.7);
		amp *= 0.5;
	}

	return sum;
}

// x: how far down the grooves are (0 is a gap between boards), y: the board's own tone, z: the grain
vec3 boards(vec2 uv, float rows, float length_units) {
	float row = floor(uv.y * rows);
	float row_hash = hash11(row * 7.13);
	float u = uv.x * length_units + row_hash * 13.0;
	float joint = hash21(vec2(floor(u), row));
	vec2 local = vec2(fract(u), fract(uv.y * rows));
	float gap = smoothstep(0.0, 0.05, local.y) * smoothstep(0.0, 0.05, 1.0 - local.y);
	gap *= smoothstep(0.0, 0.012, local.x) * smoothstep(0.0, 0.012, 1.0 - local.x);
	float grain = fbm(vec2(uv.x * 5.0 + joint * 9.0, uv.y * rows * 16.0 + joint * 40.0));
	float rings = 0.5 + 0.5 * sin((uv.y * rows * 9.0 + grain * 5.0 + joint * 20.0) * 3.14159);
	return vec3(gap * (0.7 + 0.3 * grain), mix(0.75, 1.15, joint), mix(grain, rings, 0.35));
}
]=]

local function wood_textures(rows, length_units, dark, light, roughness)
	local height = (
		[=[
		vec3 b = boards(uv, %f, %f);
		return vec4(b.x * (0.6 + 0.4 * b.z));
	]=]
	):format(rows, length_units)
	local albedo = (
		[=[
		vec3 b = boards(uv, %f, %f);
		vec3 wood = mix(vec3(%f, %f, %f), vec3(%f, %f, %f), b.z * b.y * 0.8 + 0.1);
		wood *= mix(0.85, 1.15, fbm(uv * vec2(3.0, %f * 2.0)));
		return vec4(wood * (0.25 + 0.75 * b.x), 1.0);
	]=]
	):format(rows, length_units, dark[1], dark[2], dark[3], light[1], light[2], light[3], rows)
	local normal = (
		[=[
		float e = 1.0 / 1024.0;
		vec3 c = boards(uv, %f, %f);
		float h0 = c.x * (0.6 + 0.4 * c.z);
		vec3 cx = boards(uv + vec2(e, 0.0), %f, %f);
		vec3 cy = boards(uv + vec2(0.0, e), %f, %f);
		float hx = cx.x * (0.6 + 0.4 * cx.z);
		float hy = cy.x * (0.6 + 0.4 * cy.z);
		vec3 n = normalize(vec3(-(hx - h0) * 6.0, -(hy - h0) * 6.0, 1.0));
		return vec4(n * 0.5 + 0.5, 1.0);
	]=]
	):format(rows, length_units, rows, length_units, rows, length_units)
	return {
		Albedo = shapes.Texture(albedo, WOOD_HEADER),
		Normal = shapes.Texture(normal, WOOD_HEADER),
		Roughness = shapes.Texture(
			(
				"float s = boards(uv, %f, %f).x; return vec4(mix(1.0, %f, s));"
			):format(rows, length_units, roughness),
			WOOD_HEADER
		),
		Height = shapes.Texture(height, WOOD_HEADER),
	}
end

local function wood(rows, length_units, dark, light, roughness)
	local textures = wood_textures(rows, length_units, dark, light, roughness)
	local material = shapes.Material{Albedo = textures.Albedo, Roughness = textures.Roughness, Metallic = 0}
	material:SetNormalTexture(textures.Normal)
	return material
end

local materials = {
	deck = wood(22, 1, {0.07, 0.045, 0.028}, {0.2, 0.14, 0.09}, 0.78),
	floor = wood(32, 1, {0.09, 0.06, 0.035}, {0.28, 0.19, 0.11}, 0.55),
	frame = wood(3, 1, {0.05, 0.03, 0.02}, {0.12, 0.08, 0.05}, 0.62),
	roof = wood(30, 3, {0.035, 0.032, 0.03}, {0.1, 0.085, 0.07}, 0.85),
	iron = shapes.Material{Color = Color(0.03, 0.03, 0.032, 1), Metallic = 1, Roughness = 0.45},
	stone = shapes.Material{Color = Color(0.32, 0.3, 0.27, 1), Metallic = 0, Roughness = 0.9},
	gold = shapes.Material{Color = Color(1.0, 0.76, 0.33, 1), Metallic = 1, Roughness = 0.07},
	red_lacquer = shapes.Material{
		Color = Color(0.5, 0.035, 0.025, 1),
		Metallic = 0,
		Roughness = 0.45,
		Clearcoat = 1,
		ClearcoatRoughness = 0.04,
	},
	black_lacquer = shapes.Material{
		Color = Color(0.012, 0.011, 0.012, 1),
		Metallic = 0,
		Roughness = 0.4,
		Clearcoat = 1,
		ClearcoatRoughness = 0.03,
	},
	glass = shapes.Material{
		Color = Color(0.9, 0.97, 1, 1),
		Metallic = 0,
		Roughness = 0.02,
		Refraction = 1,
		IndexOfRefraction = 1.5,
		RefractionThickness = 0.02,
	},
	glass_orb = shapes.Material{
		Color = Color(1, 1, 1, 1),
		Metallic = 0,
		Roughness = 0.0,
		Refraction = 1,
		IndexOfRefraction = 1.52,
	},
	cloth = shapes.Material{
		Color = Color(0.55, 0.32, 0.17, 1),
		Metallic = 0,
		Roughness = 0.85,
		Sheen = 0.8,
		SheenRoughness = 0.4,
		DiffuseTransmission = 0.65,
		TransmissionColor = Color(1.0, 0.55, 0.22, 1),
		DoubleSided = true,
	},
}

local function emissive(color, strength)
	return shapes.Material{
		Color = color,
		Metallic = 0,
		Roughness = 0.5,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, strength),
	}
end

materials.lantern = emissive(Color(1, 0.62, 0.26, 1), 4)
materials.crystal = shapes.Material{
	Color = Color(0.25, 0.5, 1, 1),
	Metallic = 0,
	Roughness = 0.08,
	Clearcoat = 1,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, 2.2),
}
materials.paper = shapes.Material{
	Color = Color(1, 0.72, 0.4, 1),
	Metallic = 0,
	Roughness = 0.9,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, 1.6),
	DiffuseTransmission = 0.8,
	TransmissionColor = Color(1, 0.62, 0.3, 1),
}

local function box(name, position, size, material, rotation, static)
	return shapes.Box{
		Name = name,
		Parent = root,
		Position = position,
		Size = size,
		Rotation = rotation,
		Material = material,
		Collision = static and nil or false,
		RigidBody = static and {MotionType = "static", Friction = 0.8} or false,
	}
end

-- a solid of revolution standing on position, the profile is {radius, height} from the bottom's middle round to the top's
local function lathe(name, position, profile, material, segments, texture_scale)
	return shapes.Polygon{
		Name = name,
		Parent = root,
		Position = position,
		Polygon = function(poly)
			shapes.BuildLathe(poly, profile, segments or 24, texture_scale)
		end,
		Material = material,
		Collision = false,
		RigidBody = false,
	}
end

local function cylinder(name, position, radius, height, material, segments)
	return lathe(
		name,
		position,
		{{0, 0}, {radius, 0}, {radius, height}, {0, height}},
		material,
		segments or 16,
		1
	)
end

local function light(name, position, color, lumen, radius, range)
	local entity = Entity.New{Name = name, Parent = root}
	entity:AddComponent("transform"):SetPosition(position)
	local component = entity:AddComponent("light_point")
	component:SetColor(color)
	component:SetLumen(lumen)
	component:SetSourceRadius(radius or 0.05)

	if range then component:SetRange(range) end

	return component, entity
end

local function model(path, position, scale, yaw)
	local entity = Entity.New{Name = path, Parent = root}
	local transform = entity:AddComponent("transform")
	transform:SetPosition(position)
	transform:SetScale(Vec3(scale, scale, scale))
	transform:SetRotation(QuatDeg3(0, yaw or 0, 0))
	entity:AddComponent("visual"):SetModelPath(path)
	return entity
end

local LANTERN_COLOR = Color(1, 0.6, 0.26, 1)
twilight.lanterns = {}

-- a lantern standing at position: iron foot and cap, a glowing body, and its light
local function lantern(position, lumen)
	cylinder("lantern_foot", position, 0.17, 0.05, materials.iron, 12)
	lathe(
		"lantern_body",
		position + Vec3(0, 0.05, 0),
		{{0, 0}, {0.13, 0}, {0.17, 0.08}, {0.17, 0.3}, {0.13, 0.38}, {0, 0.38}},
		materials.lantern,
		14,
		1
	)
	lathe(
		"lantern_cap",
		position + Vec3(0, 0.43, 0),
		{
			{0, 0},
			{0.27, 0},
			{0.27, 0.025},
			{0.19, 0.04},
			{0.1, 0.17},
			{0.04, 0.19},
			{0.04, 0.24},
			{0, 0.24},
		},
		materials.iron,
		14,
		1
	)
	local component = light("lantern_light", position + Vec3(0, 0.25, 0), LANTERN_COLOR, lumen, 0.08)
	twilight.lanterns[#twilight.lanterns + 1] = {component = component, base = lumen}
end

-- the pier: boards across, in sections that follow the ground, on posts down to the lake bed
local sections = 0
local section_length = 4

-- the top of the deck at z: the ground and a little over it, but never under 1.4 m, where the lake begins
local function deck_top(z)
	return math.max(ground(DECK_X, z) + 0.3, DECK_TOP_LOW)
end

for z0 = RAMP_START, PIER_END + section_length, -section_length do
	local z1 = z0 - section_length
	local y0, y1 = deck_top(z0), deck_top(z1)
	local length = math.sqrt(section_length ^ 2 + (y1 - y0) ^ 2)
	local pitch = math.deg(math.atan2(y1 - y0, section_length))
	box(
		"pier_deck",
		Vec3(DECK_X, (y0 + y1) / 2 - 0.07, (z0 + z1) / 2),
		Vec3(PIER_WIDTH, 0.14, length + 0.02),
		materials.deck,
		QuatDeg3(pitch, 0, 0),
		true
	)

	for _, side in ipairs{-1, 1} do
		local x = DECK_X + side * (PIER_WIDTH / 2 - 0.12)
		local post_top = y1 + 0.95
		local post_bottom = ground(x, z1) < -1 and -12 or ground(x, z1) - 0.8
		cylinder(
			"pier_post",
			Vec3(x, post_bottom, z1),
			0.11,
			post_top - post_bottom,
			materials.frame,
			10
		)
		-- the rails between this post and the last
		box(
			"pier_rail",
			Vec3(x, (y0 + y1) / 2 + 0.88, (z0 + z1) / 2),
			Vec3(0.07, 0.07, length),
			materials.frame,
			QuatDeg3(pitch, 0, 0)
		)
		box(
			"pier_rail_low",
			Vec3(x, (y0 + y1) / 2 + 0.45, (z0 + z1) / 2),
			Vec3(0.05, 0.05, length),
			materials.frame,
			QuatDeg3(pitch, 0, 0)
		)

		if sections % 2 == (side == 1 and 0 or 1) then
			lantern(Vec3(x, post_top, z1), 240)
		end
	end

	sections = sections + 1
end

-- the torii, standing in the lake: two posts down to the bed, a tie beam, two lintels and the plaque
do
	local half = 5.2
	local top = 9.6

	for _, side in ipairs{-1, 1} do
		lathe(
			"torii_post",
			Vec3(side * half, -10, TORII_Z),
			{{0, 0}, {0.66, 0}, {0.63, 10.9}, {0.53, 10.9 + top}, {0, 10.9 + top}},
			materials.red_lacquer,
			20,
			3
		)
		cylinder(
			"torii_foot",
			Vec3(side * half, -0.35, TORII_Z),
			0.72,
			1.2,
			materials.black_lacquer,
			20
		)
	end

	box(
		"torii_nuki",
		Vec3(0, 7.2, TORII_Z),
		Vec3(12.8, 0.42, 0.62),
		materials.red_lacquer
	)
	box(
		"torii_shimaki",
		Vec3(0, top + 0.25, TORII_Z),
		Vec3(13.6, 0.42, 0.86),
		materials.red_lacquer
	)
	box(
		"torii_kasagi",
		Vec3(0, top + 0.85, TORII_Z),
		Vec3(14.8, 0.62, 1.2),
		materials.black_lacquer
	)
	box(
		"torii_kasagi_left",
		Vec3(-7.6, top + 0.98, TORII_Z),
		Vec3(1.7, 0.62, 1.2),
		materials.black_lacquer,
		QuatDeg3(0, 0, -12)
	)
	box(
		"torii_kasagi_right",
		Vec3(7.6, top + 0.98, TORII_Z),
		Vec3(1.7, 0.62, 1.2),
		materials.black_lacquer,
		QuatDeg3(0, 0, 12)
	)
	box(
		"torii_plaque",
		Vec3(0, 8.5, TORII_Z),
		Vec3(1.1, 1.55, 0.22),
		materials.black_lacquer
	)
	box(
		"torii_plaque_gold",
		Vec3(0, 8.5, TORII_Z + 0.13),
		Vec3(0.75, 1.2, 0.04),
		materials.gold
	)
end

-- the pavilion: a raised plank floor, a gabled roof of dark shingles on posts, glass between them to the north, east and west
do
	local size_x, size_z = 9, 6.5
	local wall_height = 3
	box(
		"pavilion_footing",
		PAVILION + Vec3(0, 0.55 - 0.05 - 1.25, 0),
		Vec3(size_x + 0.6, 2.5, size_z + 0.6),
		materials.stone,
		nil,
		true
	)
	box(
		"pavilion_floor",
		PAVILION + Vec3(0, 0.55 - 0.05, 0),
		Vec3(size_x, 0.1, size_z),
		materials.floor,
		nil,
		true
	)
	local posts = {}

	for i = 0, 3 do
		posts[#posts + 1] = -size_x / 2 + i * size_x / 3
	end

	for _, x in ipairs(posts) do
		for _, z in ipairs{-size_z / 2, size_z / 2} do
			box(
				"pavilion_post",
				PAVILION + Vec3(x, 0.55 + wall_height / 2, z),
				Vec3(0.24, wall_height, 0.24),
				materials.frame
			)
		end
	end

	box(
		"pavilion_beam_north",
		PAVILION + Vec3(0, 0.55 + wall_height, -size_z / 2),
		Vec3(size_x + 0.5, 0.28, 0.3),
		materials.frame
	)
	box(
		"pavilion_beam_south",
		PAVILION + Vec3(0, 0.55 + wall_height, size_z / 2),
		Vec3(size_x + 0.5, 0.28, 0.3),
		materials.frame
	)
	box(
		"pavilion_beam_east",
		PAVILION + Vec3(size_x / 2, 0.55 + wall_height, 0),
		Vec3(0.3, 0.28, size_z),
		materials.frame
	)
	box(
		"pavilion_beam_west",
		PAVILION + Vec3(-size_x / 2, 0.55 + wall_height, 0),
		Vec3(0.3, 0.28, size_z),
		materials.frame
	)
	-- glass between the posts, 2.5 m of it above a low sill
	local pane_height = wall_height - 0.45
	local pane_y = 0.55 + 0.1 + pane_height / 2

	for i = 1, 3 do
		local x = (posts[i] + posts[i + 1]) / 2
		local width = posts[i + 1] - posts[i] - 0.24
		box(
			"pavilion_glass_north",
			PAVILION + Vec3(x, pane_y, -size_z / 2),
			Vec3(width, pane_height, 0.025),
			materials.glass
		)
		box(
			"pavilion_sill_north",
			PAVILION + Vec3(x, 0.55 + 0.1, -size_z / 2),
			Vec3(width + 0.1, 0.12, 0.2),
			materials.frame
		)
	end

	for _, side in ipairs{-1, 1} do
		box(
			"pavilion_glass_side",
			PAVILION + Vec3(side * size_x / 2, pane_y, 0),
			Vec3(0.025, pane_height, size_z - 0.24),
			materials.glass
		)
		box(
			"pavilion_mullion",
			PAVILION + Vec3(side * size_x / 2, pane_y, 0),
			Vec3(0.14, pane_height, 0.1),
			materials.frame
		)
	end

	-- the south wall is planks, with a doorway
	box(
		"pavilion_wall_south_a",
		PAVILION + Vec3(-2.9, pane_y, size_z / 2),
		Vec3(3.1, pane_height, 0.14),
		materials.floor
	)
	box(
		"pavilion_wall_south_b",
		PAVILION + Vec3(2.9, pane_y, size_z / 2),
		Vec3(3.1, pane_height, 0.14),
		materials.floor
	)
	box(
		"pavilion_wall_south_top",
		PAVILION + Vec3(0, 0.55 + wall_height - 0.35, size_z / 2),
		Vec3(2.7, 0.7, 0.14),
		materials.floor
	)
	-- the roof, two slabs and a ridge
	local rise, run = 2.1, size_z / 2 + 1.1
	local slope = math.deg(math.atan2(rise, run))
	local slab = math.sqrt(rise ^ 2 + run ^ 2)

	for _, side in ipairs{-1, 1} do
		box(
			"pavilion_roof",
			PAVILION + Vec3(0, 0.55 + wall_height + rise / 2 + 0.2, side * run / 2),
			Vec3(size_x + 2.2, 0.14, slab),
			materials.roof,
			QuatDeg3(side * slope, 0, 0)
		)
	end

	box(
		"pavilion_ridge",
		PAVILION + Vec3(0, 0.55 + wall_height + rise + 0.28, 0),
		Vec3(size_x + 2.4, 0.22, 0.34),
		materials.black_lacquer
	)
	-- inside: a low table, cushions, and a paper lantern
	box(
		"table",
		PAVILION + Vec3(1.2, 0.6 + 0.2, -0.4),
		Vec3(1.9, 0.07, 1.0),
		materials.frame
	)

	for _, corner in ipairs{{-0.8, -0.4}, {0.8, -0.4}, {-0.8, 0.4}, {0.8, 0.4}} do
		box(
			"table_leg",
			PAVILION + Vec3(1.2 + corner[1], 0.6 + 0.1, -0.4 + corner[2]),
			Vec3(0.07, 0.2, 0.07),
			materials.frame
		)
	end

	for _, offset in ipairs{{-0.2, -0.5}, {2.6, -0.4}, {1.1, 1.0}} do
		box(
			"cushion",
			PAVILION + Vec3(offset[1], 0.65 + 0.07, offset[2]),
			Vec3(0.7, 0.14, 0.7),
			materials.cloth,
			QuatDeg3(0, offset[1] * 40, 0)
		)
	end

	lathe(
		"paper_lantern",
		PAVILION + Vec3(1.2, 2.65, -0.4),
		{
			{0, 0},
			{0.2, 0.04},
			{0.34, 0.2},
			{0.38, 0.4},
			{0.34, 0.6},
			{0.2, 0.76},
			{0, 0.8},
		},
		materials.paper,
		20,
		1
	)
	local lamp = light(
		"pavilion_light",
		PAVILION + Vec3(1.2, 3.0, -0.4),
		Color(1, 0.66, 0.34, 1),
		700,
		0.25
	)
	twilight.pavilion_light = lamp
	box(
		"pavilion_cord",
		PAVILION + Vec3(1.2, 0.55 + wall_height + 0.2 - 0.17, -0.4),
		Vec3(0.02, 1.3, 0.02),
		materials.iron
	)
end

-- a rowboat tied to the pier, rocking on the water: a bowl of revolution made long, and two seats
do
	local steps, wall = 12, 0.07
	local outer = {}

	for i = 0, steps do
		local angle = i / steps * math.rad(80)
		outer[#outer + 1] = {math.sin(angle), -math.cos(angle)}
	end

	local profile = {}

	for i, point in ipairs(outer) do
		profile[i] = point
	end

	for i = #outer, 1, -1 do
		profile[#profile + 1] = {outer[i][1] * (1 - wall), outer[i][2] * (1 - wall)}
	end

	local boat = shapes.Polygon{
		Name = "boat",
		Parent = root,
		Position = Vec3(2.45, 0.2, -90),
		Polygon = function(poly)
			shapes.BuildLathe(poly, profile, 28, 1, Vec3(0.62, 0.5, 2.3))
		end,
		Material = materials.floor,
		Collision = false,
		RigidBody = false,
	}

	for _, z in ipairs{-0.7, 0.8} do
		shapes.Box{
			Name = "boat_seat",
			Parent = boat,
			Position = Vec3(0, -0.12, z),
			Size = Vec3(1.15, 0.05, 0.24),
			Material = materials.deck,
			Collision = false,
			RigidBody = false,
		}
	end

	twilight.boat = boat
	twilight.boat_rocks = true
end

-- the head of the pier: two stone pedestals with a gold sphere and a glass one on them
do
	local function pedestal(x, top_material, radius)
		local position = Vec3(x, CAMP_HEIGHT, RAMP_START + 4)
		lathe(
			"pedestal",
			position,
			{
				{0, 0},
				{0.55, 0},
				{0.55, 0.12},
				{0.42, 0.18},
				{0.38, 0.95},
				{0.5, 1.0},
				{0.5, 1.12},
				{0, 1.12},
			},
			materials.stone,
			28,
			2
		)
		shapes.Sphere{
			Name = "pedestal_sphere",
			Parent = root,
			Position = position + Vec3(0, 1.12 + radius, 0),
			Radius = radius,
			Material = top_material,
			Collision = false,
			RigidBody = false,
		}
	end

	pedestal(-3.2, materials.gold, 0.5)
	pedestal(3.2, materials.glass_orb, 0.42)
end

-- a path of cobbles from the camp to the head of the pier, parallax mapped: the stones stand up from the mortar
do
	local COBBLE_HEADER = WOOD_HEADER .. [=[
// periodic voronoi with `period` cells across: x the distance to the nearest center, y to the second nearest, zw the
// nearest cell's id
vec4 cells(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	vec2 id = vec2(0.0);

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 cell = mod(i + g, period);
			vec2 o = vec2(hash21(cell), hash21(cell + 31.7));
			float d = length(g + 0.15 + 0.7 * o - f);

			if (d < d1) {
				d2 = d1;
				d1 = d;
				id = cell;
			} else if (d < d2) {
				d2 = d;
			}
		}
	}

	return vec4(d1, d2, id);
}

// 0 in the mortar, the stones domed
float cobble_height(vec2 uv) {
	vec4 c = cells(uv * 7.0, 7.0);
	float edge = smoothstep(0.0, 0.2, c.y - c.x);
	return edge * (0.55 + 0.35 * (1.0 - c.x * 0.8)) * (0.9 + 0.1 * fbm(uv * 70.0));
}
]=]
	local albedo = shapes.Texture(
		[=[
		vec4 c = cells(uv * 7.0, 7.0);
		float edge = smoothstep(0.0, 0.2, c.y - c.x);
		float tone = hash21(c.zw + 4.3);
		vec3 stone = mix(vec3(0.13, 0.125, 0.12), vec3(0.3, 0.27, 0.23), tone);
		stone = mix(stone, stone * vec3(0.8, 0.95, 0.7), smoothstep(0.55, 0.8, fbm(uv * 25.0 + c.zw)) * 0.7);
		stone *= 0.8 + 0.4 * fbm(uv * 90.0);
		vec3 mortar = vec3(0.035, 0.04, 0.025);
		return vec4(mix(mortar, stone, edge), 1.0);
	]=],
		COBBLE_HEADER
	)
	local normal = shapes.Texture(
		[=[
		float e = 1.0 / 1024.0;
		float h0 = cobble_height(uv);
		float hx = cobble_height(uv + vec2(e, 0.0));
		float hy = cobble_height(uv + vec2(0.0, e));
		vec3 n = normalize(vec3(-(hx - h0) * 4.0, -(hy - h0) * 4.0, 1.0));
		return vec4(n * 0.5 + 0.5, 1.0);
	]=],
		COBBLE_HEADER
	)
	local height = shapes.Texture("return vec4(cobble_height(uv));", COBBLE_HEADER)
	local cobbles = shapes.Material{
		Albedo = albedo,
		Roughness = 0.82,
		Metallic = 0,
		HeightTexture = height,
		HeightScale = 0.06,
	}
	cobbles:SetNormalTexture(normal)
	materials.cobbles = cobbles

	for z = -13, -50, -2.4 do
		box(
			"path_cobbles",
			Vec3(0, CAMP_HEIGHT + 0.01, z),
			Vec3(2.4, 0.06, 2.4),
			cobbles,
			nil,
			true
		)
	end
end

-- a stone basin by the pier with a little water in it: a water volume, with its own caustics on the floor, and a cool
-- light under the surface
do
	local center = Vec3(11, CAMP_HEIGHT, -58)
	local size = Vec3(6, 0, 4)
	local floor_top = CAMP_HEIGHT + 0.36
	local surface = floor_top + 0.2
	box(
		"basin_floor",
		center + Vec3(0, floor_top - 0.2 - CAMP_HEIGHT, 0),
		Vec3(size.x + 0.4, 0.4, size.z + 0.4),
		materials.stone,
		nil,
		true
	)
	-- a ring of boulders round it, sunk into the ground
	local perimeter = {}

	for i = 0, 6 do
		perimeter[#perimeter + 1] = Vec2(-size.x / 2 + i * size.x / 6, -size.z / 2)
		perimeter[#perimeter + 1] = Vec2(-size.x / 2 + i * size.x / 6, size.z / 2)
	end

	for i = 1, 3 do
		perimeter[#perimeter + 1] = Vec2(-size.x / 2, -size.z / 2 + i * size.z / 4)
		perimeter[#perimeter + 1] = Vec2(size.x / 2, -size.z / 2 + i * size.z / 4)
	end

	local models = {"boulder_a", "boulder_b", "mossy_boulder_a", "slab_a"}

	for i, point in ipairs(perimeter) do
		model(
			"models/foliage/rocks/" .. models[i % #models + 1] .. ".lua",
			center + Vec3(point.x * 1.08, 0.05, point.y * 1.12),
			0.34 + 0.07 * ((i * 5) % 4),
			i * 61
		)
	end

	twilight.pond = Entity.New{
		Name = "pond",
		Parent = root,
		transform = {Position = Vec3(center.x, surface, center.z)},
		water_volume = {
			Size = Vec3(size.x, 0.2, size.z),
			Absorption = water.presets.pool.Absorption:Copy(),
			ParticleScattering = water.presets.pool.ParticleScattering:Copy(),
			WaveHeight = 0.012,
			WaveLength = 0.6,
			Foam = 0,
		},
	}
	light(
		"pond_light",
		Vec3(center.x, surface + 0.35, center.z),
		Color(0.4, 0.8, 1, 1),
		110,
		0.1
	)
end

-- the fire: stones round it, logs to sit on, the light of it
do
	local stones = 9

	for i = 0, stones - 1 do
		local angle = i / stones * math.pi * 2
		model(
			"models/foliage/rocks/boulder_a.lua",
			FIRE + Vec3(math.cos(angle) * 0.85, 0, math.sin(angle) * 0.85),
			0.22 + 0.04 * ((i * 7) % 3),
			i * 47
		)
	end

	for i, angle in ipairs{0.3, 2.3, 4.2} do
		model(
			"models/foliage/plants/log_a.lua",
			FIRE + Vec3(math.cos(angle) * 3, 0, math.sin(angle) * 3),
			0.5,
			math.deg(-angle) + 90
		)
	end

	model("models/foliage/plants/stump_a.lua", FIRE + Vec3(-2.3, 0, 2.0), 0.7, 20)
	model("models/foliage/plants/stump_a.lua", FIRE + Vec3(3.4, 0, 1.6), 0.55, 140)
	local fire_light = light("fire_light", FIRE + Vec3(0, 0.7, 0), Color(1, 0.48, 0.16, 1), 2600, 0.25)
	twilight.fire_light = fire_light
	twilight.fire = FIRE
end

-- crystals on a rock by the shore, glowing blue, and the light they give
do
	local base = Vec3(24, ground(24, -64), -64)
	model("models/foliage/rocks/crag_a.lua", base + Vec3(0, -0.3, 0), 0.6, 30)
	local heights = {1.6, 1.1, 0.8, 1.3, 0.6, 0.9}

	for i, height in ipairs(heights) do
		local angle = i / #heights * math.pi * 2
		local spread = 0.3 + 0.12 * (i % 3)
		local position = base + Vec3(math.cos(angle) * spread, 0.1 + height / 2, math.sin(angle) * spread)
		shapes.Cone{
			Name = "crystal",
			Parent = root,
			Position = position,
			Radius = 0.1 + 0.03 * (i % 3),
			Height = height,
			Rotation = QuatDeg3(math.sin(angle) * 14, i * 53, -math.cos(angle) * 14),
			Material = materials.crystal,
			Collision = false,
			RigidBody = false,
		}
	end

	twilight.crystal_light = light("crystal_light", base + Vec3(0, 1.1, 0), Color(0.3, 0.5, 1, 1), 380, 0.1)
end

-- a sail of cloth over the seats, on three poles
do
	local poles = {Vec3(11.5, 0, -39), Vec3(20, 0, -37), Vec3(16.4, 0, -29)}
	local heights = {5.2, 4.8, 6.1}

	for i, pole in ipairs(poles) do
		cylinder(
			"pole",
			Vec3(pole.x, CAMP_HEIGHT - 0.2, pole.z),
			0.07,
			heights[i] + 0.2,
			materials.frame,
			8
		)
	end

	shapes.Polygon{
		Name = "sail",
		Parent = root,
		Polygon = function(poly)
			local a = Vec3(poles[1].x, CAMP_HEIGHT + heights[1], poles[1].z)
			local b = Vec3(poles[2].x, CAMP_HEIGHT + heights[2], poles[2].z)
			local c = Vec3(poles[3].x, CAMP_HEIGHT + heights[3], poles[3].z)
			local mid = (a + b + c) / 3 - Vec3(0, 0.35, 0)
			local normal = (b - a):GetCross(c - a):GetNormalized()

			if normal.y < 0 then normal = normal * -1 end

			local function vertex(p, u, v)
				poly:AddVertex{
					pos = p,
					uv = Vec2(u, v),
					normal = normal,
					tangent = {x = 1, y = 0, z = 0, w = 1},
				}
			end

			-- a flat sheet drooping to the middle: three triangles around it, drawn from both sides by DoubleSided
			vertex(a, 0, 0)
			vertex(mid, 0.5, 0.5)
			vertex(b, 1, 0)
			vertex(b, 1, 0)
			vertex(mid, 0.5, 0.5)
			vertex(c, 0.5, 1)
			vertex(c, 0.5, 1)
			vertex(mid, 0.5, 0.5)
			vertex(a, 0, 0)
		end,
		Material = materials.cloth,
		Collision = false,
		RigidBody = false,
	}
end

-- particles: the fire (flames, sparks, smoke) and the fireflies over the meadow
local function emitter(name, kind, position, direction)
	local entity = Entity.New{Name = name, Parent = root}
	local transform = entity:AddComponent("transform")
	transform:SetPosition(position)
	local dir = direction:GetNormalized()
	local axis = Vec3(0, 1, 0):GetCross(dir)
	transform:SetRotation(Quat(axis.x, axis.y, axis.z, 1 + dir.y):Normalize())
	return entity:AddComponent(kind)
end

do
	local origin = FIRE + Vec3(0, 0.3, 0)
	local up = Vec3(0, 1, 0)
	local flames = emitter("fire_flames", "particle_emitter_gpu", origin, up)
	flames:SetRate(150)
	flames:SetMaxParticles(700)
	flames:SetShape("sphere")
	flames:SetShapeSize(Vec3(0.4, 0.1, 0.4))
	flames:SetSpread(9)
	flames:SetSpeedMin(1.2)
	flames:SetSpeedMax(2.4)
	flames:SetLifetimeMin(0.45)
	flames:SetLifetimeMax(0.95)
	flames:SetGravityScale(-0.35)
	flames:SetDrag(1.1)
	flames:SetSizeStart(0.55)
	flames:SetSizeEnd(0.04)
	flames:SetLit(false)
	flames:SetEmissive(8e4)
	flames:SetColorStart(Color(1, 0.62, 0.18, 0.9))
	flames:SetColorEnd(Color(1, 0.12, 0.02, 0))
	local sparks = emitter("fire_sparks", "particle_emitter_gpu", origin + Vec3(0, 0.2, 0), up)
	sparks:SetRate(16)
	sparks:SetMaxParticles(240)
	sparks:SetShape("sphere")
	sparks:SetShapeSize(Vec3(0.2, 0.1, 0.2))
	sparks:SetSpread(38)
	sparks:SetSpeedMin(1.6)
	sparks:SetSpeedMax(3.8)
	sparks:SetLifetimeMin(1.2)
	sparks:SetLifetimeMax(2.8)
	sparks:SetGravityScale(0.12)
	sparks:SetDrag(0.35)
	sparks:SetSizeStart(0.022)
	sparks:SetSizeEnd(0.008)
	sparks:SetLit(false)
	sparks:SetEmissive(4e5)
	sparks:SetColorStart(Color(1, 0.72, 0.28, 1))
	sparks:SetColorEnd(Color(1, 0.25, 0.05, 0))
	local smoke = emitter("fire_smoke", "particle_emitter_gpu", origin + Vec3(0, 0.9, 0), up)
	smoke:SetRate(12)
	smoke:SetMaxParticles(260)
	smoke:SetShape("sphere")
	smoke:SetShapeSize(Vec3(0.3, 0.1, 0.3))
	smoke:SetSpread(16)
	smoke:SetSpeedMin(0.5)
	smoke:SetSpeedMax(1.1)
	smoke:SetLifetimeMin(5)
	smoke:SetLifetimeMax(9)
	smoke:SetGravityScale(-0.05)
	smoke:SetDrag(0.35)
	smoke:SetSizeStart(0.35)
	smoke:SetSizeEnd(2.4)
	smoke:SetLit(true)
	smoke:SetColorStart(Color(0.32, 0.3, 0.3, 0.4))
	smoke:SetColorEnd(Color(0.45, 0.44, 0.44, 0))
	twilight.fireflies = {}

	-- three swarms with soft edges: round the fire, over the east meadow and by the willows on the west shore
	for _, swarm in ipairs{
		{position = Vec3(14, CAMP_HEIGHT + 1.6, -30), radius = 20, rate = 22},
		{position = Vec3(46, CAMP_HEIGHT + 1.4, -48), radius = 26, rate = 30},
		{position = Vec3(-52, CAMP_HEIGHT + 1.2, -52), radius = 24, rate = 30},
	} do
		local fireflies = emitter("fireflies", "particle_emitter_gpu", swarm.position, up)
		fireflies:SetRate(swarm.rate)
		fireflies:SetMaxParticles(700)
		fireflies:SetShape("sphere")
		fireflies:SetShapeSize(Vec3(swarm.radius, swarm.radius * 0.12, swarm.radius))
		fireflies:SetSpread(180)
		fireflies:SetSpeedMin(0.12)
		fireflies:SetSpeedMax(0.5)
		fireflies:SetLifetimeMin(10)
		fireflies:SetLifetimeMax(18)
		fireflies:SetGravityScale(0)
		fireflies:SetDrag(0.5)
		fireflies:SetSizeStart(0.075)
		fireflies:SetSizeEnd(0.075)
		fireflies:SetLit(false)
		fireflies:SetEmissive(1.6e5)
		fireflies:SetColorStart(Color(0.85, 1, 0.3, 1))
		fireflies:SetColorEnd(Color(0.85, 1, 0.3, 0))
		twilight.fireflies[#twilight.fireflies + 1] = fireflies
	end

	twilight.emitters = {flames = flames, sparks = sparks, smoke = smoke}
end

-- the fire and the lanterns flicker
do
	local fire_light = twilight.fire_light
	local FIRE_LUMEN = fire_light:GetLumen()

	event.AddListener("Update", "twilight_lake_flicker", function()
		local time = system.GetElapsedTime()
		local flicker = 0.78 + 0.22 * math.sin(time * 9.1) * math.sin(time * 5.3 + 1.1) + 0.18 * math.sin(time * 23.7 + 0.4)
		fire_light:SetLumen(FIRE_LUMEN * flicker)

		-- a moving mesh changes the scene's bvh every frame, which a benchmark waiting for it to settle can't have
		if twilight.boat_rocks then
			local boat = twilight.boat.transform
			boat:SetPosition(
				Vec3(
					2.45 + 0.04 * math.sin(time * 0.5),
					0.2 + 0.035 * math.sin(time * 0.9),
					-90 + 0.05 * math.sin(time * 0.37)
				)
			)
			boat:SetRotation(
				QuatDeg3(
					1.6 * math.sin(time * 0.7),
					3 * math.sin(time * 0.23),
					2.4 * math.sin(time * 0.95 + 1)
				)
			)
		end

		for i, lantern in ipairs(twilight.lanterns) do
			lantern.component:SetLumen(
				lantern.base * (
						0.94 + 0.06 * math.sin(time * 3.1 + i * 1.7) * math.sin(time * 1.3 + i)
					)
			)
		end
	end)
end

-- the sun's height, in degrees above the horizon. under it the image is exposed like an eye (a dim scene stays dim and the
-- lights read) and not like a camera that would lift the night to a mid grey
function twilight.SetSunElevation(degrees)
	pvars.SetSession("r_eye", degrees < 0)
	local elevation = math.rad(degrees)
	weather.SetSunDirection(
		Vec3(
			-math.sin(sun_azimuth) * math.cos(elevation),
			math.sin(elevation),
			-math.cos(sun_azimuth) * math.cos(elevation)
		)
	)
end

commands.Add("twilight_sun=number[6]", function(degrees)
	twilight.SetSunElevation(degrees)
end)

local WEATHERS = {
	clear = {aerosol_visibility = 35000, ground_fog_visibility = 60000},
	mist = {aerosol_visibility = 12000, ground_fog_visibility = 700},
	rain = "rain",
	storm = "storm",
	snow = "snow",
}

function twilight.SetWeather(name)
	climate.SetPreset(
		WEATHERS[name] or
			error("unknown weather " .. name .. ", try clear mist rain storm snow"),
		4
	)
end

commands.Add("twilight_weather=string[clear]", twilight.SetWeather)
local spawn = Entity.New{Name = "twilight_spawn", Parent = twilight.root}
spawn:AddComponent("transform"):SetPosition(Vec3(CAMP.x + 6, CAMP_HEIGHT + 0.1, CAMP.z + 14))
spawn:AddComponent("spawn_point", {Group = "start"})

-- a rotation looking from one point at another
local function look(from, to)
	local dir = (to - from):GetNormalized()
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(math.atan2(-dir.x, -dir.z))
	rotation:RotatePitch(math.asin(dir.y))
	return rotation
end

local function on_ground(x, z, above)
	return Vec3(x, twilight.GetHeight(x, z) + above, z)
end

-- in the order of the tour, each leg is a straight flight from one to the next
twilight.views = {
	{
		name = "down the pier to the torii",
		from = on_ground(0, -43, 2.6),
		to = Vec3(0, 11, -300),
		fov = 58,
	},
	{
		name = "the pavilion",
		from = on_ground(7, -40, 1.7),
		to = Vec3(-15, 5.0, -63),
		fov = 66,
	},
	{
		name = "the basin",
		from = Vec3(5.5, 5.4, -49),
		to = Vec3(11, 3.9, -58),
		fov = 60,
	},
	{
		name = "the crystals",
		from = on_ground(30, -56, 1.5),
		to = Vec3(24, 4.4, -64),
		fov = 55,
	},
	{
		name = "the fire",
		from = on_ground(4, -20, 1.6),
		to = Vec3(FIRE.x, FIRE.y + 1.4, FIRE.z),
		fov = 60,
	},
	{
		name = "back from the pier",
		from = Vec3(8.5, 3.0, -116),
		to = Vec3(-8, 6.5, -30),
		fov = 66,
	},
	{
		name = "the torii",
		from = Vec3(-9, 2.4, -96),
		to = Vec3(0, 6.4, -126),
		fov = 55,
	},
	{
		name = "towards the sun",
		from = Vec3(3.5, 3.4, -104),
		to = Vec3(-146, 28, 154),
		fov = 66,
	},
}

function twilight.SetView(index)
	if twilight.view then
		twilight.view:Remove()
		twilight.view = nil
	end

	local view = twilight.views[index]

	if not view then return end

	twilight.view = View.New{
		Priority = 100,
		Position = view.from,
		Rotation = look(view.from, view.to),
		FOV = math.rad(view.fov or 70),
		ExposureLock = view.ev or false,
	}:Activate()
end

commands.Add("twilight_view=number[0]", function(index)
	if index == 0 then
		for i, view in ipairs(twilight.views) do
			logn(i, ": ", view.name)
		end
	end

	twilight.SetView(index)
end)

-- a slow camera tour through the views, seconds is how long each leg takes, 0 stops it
function twilight.SetTour(seconds)
	event.RemoveListener("Update", "twilight_lake_tour")
	twilight.SetView(nil)

	if seconds <= 0 then return end

	local leg, elapsed = 1, 0
	twilight.SetView(1)

	event.AddListener("Update", "twilight_lake_tour", function(dt)
		elapsed = elapsed + dt

		if elapsed >= seconds then
			elapsed = elapsed - seconds
			leg = leg % #twilight.views + 1
		end

		local a, b = twilight.views[leg], twilight.views[leg % #twilight.views + 1]
		local t = math.smoothstep(0, 1, elapsed / seconds)
		local from = a.from + (b.from - a.from) * t
		twilight.view:SetPosition(from)
		twilight.view:SetRotation(look(from, a.to + (b.to - a.to) * t))
		twilight.view:SetFOV(math.rad(math.lerp(t, a.fov or 70, b.fov or 70)))
	end)
end

commands.Add("twilight_tour=number[14]", function(seconds)
	twilight.SetTour(seconds)
end)

-- the look of the image: a warmer, richer grade, kept for this session only
local LOOK = {
	r_grade_warmth = 12,
	r_grade_contrast = 8,
	r_grade_saturation = 10,
	r_eye = false,
}
twilight.previous_look = {}

for key, value in pairs(LOOK) do
	twilight.previous_look[key] = pvars.Get(key)
	pvars.SetSession(key, value)
end

function twilight.Remove()
	for key, value in pairs(twilight.previous_look) do
		pvars.SetSession(key, value)
	end

	event.RemoveListener("Update", "twilight_lake_flicker")
	event.RemoveListener("Update", "twilight_lake_tour")
	twilight.SetView(nil)
	twilight.root:Remove()
	twilight.terrain:Stop()
	twilight.scatter_set:Remove()
	render3d.SetOceanEnabled(false)
	_G.twilight_lake = nil
end

_G.twilight_lake = twilight
return twilight
