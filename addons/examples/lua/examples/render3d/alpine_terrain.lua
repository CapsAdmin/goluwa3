local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local foliage_sets = import("lua/foliage/scatter_sets.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local SEED = 4242
local HEIGHT_RANGE = 6000
local HEIGHT_OFFSET = 900
local MIN_HEIGHT = HEIGHT_OFFSET - HEIGHT_RANGE * 0.5
local MAX_HEIGHT = HEIGHT_OFFSET + HEIGHT_RANGE * 0.5
local OCEAN_LEVEL = 100
local SNOW_START = 1100
local SNOW_RANGE = 1500
local HEIGHT_GLSL = [=[
float lc_rnd(vec2 p, float seed) {
	p += vec2(seed, seed * 1.6180339);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 lc_value_noise(vec2 x, float seed) {
	vec2 pi = floor(x);
	vec2 pf = fract(x);
	float a = lc_rnd(pi, seed);
	float b = lc_rnd(pi + vec2(1.0, 0.0), seed);
	float c = lc_rnd(pi + vec2(0.0, 1.0), seed);
	float d = lc_rnd(pi + 1.0, seed);
	vec2 u = pf * pf * pf * (pf * (pf * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * pf * pf * (pf - 1.0) * (pf - 1.0);
	float k1 = b - a;
	float k2 = c - a;
	float k3 = a - b - c + d;
	return vec3(a + k1 * u.x + k2 * u.y + k3 * u.x * u.y, (k1 + k3 * u.y) * du.x, (k2 + k3 * u.x) * du.y);
}

float terrain_height(vec2 world) {
	const mat2 m = mat2(0.825, -0.6, 0.6, 0.825);
	const float erosion = 2.5;
	const float seed = 0.303586;
	vec2 p = (world + SEED_OFFSET) / 10000.0;
	float step_uv = terrain_bake_step() / 10000.0;
	float a = 0.0;
	float b = 1.0;
	float total = 0.0;
	float full_total = 0.0;
	float wavelength = 1.0;
	vec2 d = vec2(0.0);
	int used = 15;

	for (int i = 0; i < 15; i++) {
		full_total += b;
		b *= 0.5;
	}

	b = 1.0;

	for (int i = 0; i < 15; i++) {
		if (wavelength < step_uv * 2.0) {
			used = i;
			break;
		}

		vec3 n = lc_value_noise(p, seed);
		d += n.yz;
		a += b * n.x / (1.0 + dot(d, d) * erosion);
		b *= 0.5;
		p = m * p * 2.0;
		wavelength *= 0.5;
	}

	if (used < 15) a += b * 2.0 * (1.0 - pow(0.5, float(15 - used))) * 0.5 / (1.0 + dot(d, d) * erosion);

	return (a / full_total - 0.5) * HEIGHT_RANGE + HEIGHT_OFFSET;
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	float steepness = 1.0 - (n.y * 0.5 + 0.5);
	float rock = clamp((steepness - 0.075) / 0.025, 0.0, 1.0);
	float snow_amount = pow(clamp(h - SNOW_START, 0.0, SNOW_RANGE) / SNOW_RANGE, 0.75);
	float diff = mix(0.0, 0.3, snow_amount) - steepness;
	float snow = clamp(diff / 0.05, 0.0, 1.0);
	float rest = 1.0 - snow;
	return vec4((1.0 - rock) * rest, rock * rest, snow, 0.0);
}
]=]

local function build_header()
	return string.format(
		[=[
const vec2 SEED_OFFSET = vec2(%f, %f);
const float HEIGHT_RANGE = %f;
const float HEIGHT_OFFSET = %f;
const float SNOW_START = %f;
const float SNOW_RANGE = %f;
]=],
		math.sin(SEED * 12.9898) * 16384.0,
		math.cos(SEED * 78.2330) * 16384.0,
		HEIGHT_RANGE,
		HEIGHT_OFFSET,
		SNOW_START,
		SNOW_RANGE
	)
end

local function build_scatter_set()
	local prototypes = {}

	local function add(set, layers, altitude, density)
		for _, definition in ipairs(set.Prototypes) do
			local copy = table.copy(definition)
			copy.layers = layers
			copy.altitude = altitude
			copy.density = definition.density * density
			prototypes[#prototypes + 1] = copy
		end
	end

	add(foliage_sets.foliage_meadow, {1, 0, 0, 0}, {OCEAN_LEVEL + 3, 700, 150}, 2.5)
	add(foliage_sets.foliage_forest, {1, 0.3, 0, 0.3}, {OCEAN_LEVEL + 40, 1400, 250}, 4)
	add(foliage_sets.foliage_rocky, {0.15, 1, 0, 1}, {OCEAN_LEVEL + 3, 2000, 200}, 1.5)
	return ScatterSet.New{Name = "alpine_terrain", Prototypes = prototypes, DistanceMultiplier = 2.5}
end

local function layer(name, scale, extra)
	local textures = terrain_textures[name]
	local out = {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}

	for k, v in pairs(extra or {}) do
		out[k] = v
	end

	return out
end

if _G.alpine_terrain then _G.alpine_terrain:Stop() end

_G.alpine_terrain = Terrain.New(
	table.merge(
		{
			Name = "alpine_terrain",
			ScatterSet = build_scatter_set(),
			Source = ShaderSource.New{
				Header = build_header(),
				HeightGLSL = HEIGHT_GLSL,
				SplatGLSL = SPLAT_GLSL,
				MinHeight = MIN_HEIGHT,
				MaxHeight = MAX_HEIGHT,
				Layers = {
					layer("grass", 3, {scatter = 1}),
					layer("rock", 11, {scatter = 1}),
					layer("snow", 7),
					layer("rock", 11, {scatter = 1}),
				},
			},
			Levels = 12,
			BaseChunkSize = 64,
			Samples = 65,
			DetailSize = 256,
			SplatSize = 128,
			ShadowLevels = 6,
			ShadowExtent = 16384,
			BuildsPerFrame = 2,
			Physics = {
				chunk_size = 64,
				samples = 65,
				radius = 2,
			},
		},
		_G.TERRAIN_OVERRIDES or {}
	)
):Start()
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(OCEAN_LEVEL)
