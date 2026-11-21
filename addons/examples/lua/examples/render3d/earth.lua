local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local SEED = tonumber(os.getenv("EARTH_SEED")) or 3
local HEADER = noise.WORLD .. string.format(
		"const vec2 SEED_OFFSET = vec2(%f, %f);\n",
		math.sin(SEED * 12.9898) * 1000.0,
		math.cos(SEED * 78.2330) * 1000.0
	)
local HEIGHT_GLSL = [=[
const float CONTINENT_SCALE = 2000000.0;
const float COAST_SCALE = 40000.0;
const float LOCAL_SCALE = 1500.0;
const float SEA_THRESHOLD = 0.08;

float earth_coast(vec2 p, float step) {
	vec2 q = p / CONTINENT_SCALE + SEED_OFFSET;
	vec2 warp = vec2(pn_fbm_lod(q * 1.7 + vec2(3.0, 1.0), 4, CONTINENT_SCALE / 1.7, step), pn_fbm_lod(q * 1.7 + vec2(-5.0, 7.0), 4, CONTINENT_SCALE / 1.7, step)) * 0.35;
	float continent = pn_fbm_lod(q + warp, 8, CONTINENT_SCALE, step);
	float coast = pn_fbm_lod(p / COAST_SCALE + SEED_OFFSET * 3.1 + vec2(11.0, 4.0), 6, COAST_SCALE, step);
	float local_detail = pn_fbm_lod(p / LOCAL_SCALE + SEED_OFFSET * 7.3 + vec2(-2.0, 9.0), 5, LOCAL_SCALE, step);
	return continent + coast * 0.06 + local_detail * 0.008 - SEA_THRESHOLD;
}

float earth_mountains(vec2 p, float step) {
	vec2 q = p / CONTINENT_SCALE + SEED_OFFSET + vec2(17.0, -3.0);
	float belt = smoothstep(0.05, 0.3, pn_fbm_lod(q * 2.3, 4, CONTINENT_SCALE / 2.3, step));
	float ridges = pn_ridged_lod(p / 260000.0 + SEED_OFFSET + vec2(5.0, 2.0), 9, 1.0, 2.0, 260000.0, step);
	return belt * ridges * ridges;
}

float terrain_height(vec2 p) {
	float step = terrain_bake_step();
	float s = earth_coast(p, step);

	if (s < 0.0) {
		float shelf = -140.0 * smoothstep(0.0, 0.015, -s);
		float basin = -3900.0 * smoothstep(0.012, 0.09, -s);
		return -1800.0 * s * (1.0 - smoothstep(0.0, 0.015, -s)) + shelf + basin;
	}

	float inland = smoothstep(0.0, 0.25, s);
	float hills = pn_fbm_lod(p / 90000.0 + SEED_OFFSET + vec2(-8.0, 2.0), 7, 90000.0, step) * 0.5 + 0.5;
	return 1800.0 * s * (1.0 - inland) + inland * (450.0 + 500.0 * hills) * smoothstep(0.0, 0.08, s) + 5200.0 * earth_mountains(p, step) * smoothstep(0.02, 0.12, s);
}
]=]
local SPLAT_GLSL = [=[
float earth_dryness(vec2 p) {
	return smoothstep(-0.1, 0.35, pn_fbm(p / 700000.0 + SEED_OFFSET + vec2(2.0, -6.0), 5));
}

vec4 terrain_splat(vec2 p, float h, vec3 n) {
	float slope = 1.0 - n.y;
	float detail = pn_fbm(p / 300.0, 3) * 0.5;
	float beach = 1.0 - smoothstep(2.0, 8.0, h + detail * 4.0);
	float desert = smoothstep(0.55, 0.8, earth_dryness(p) + detail * 0.1) * (1.0 - smoothstep(900.0, 1600.0, h));
	float rock = max(smoothstep(0.25, 0.45, slope + detail * 0.1), smoothstep(2200.0, 3000.0, h + detail * 300.0));
	float snow = smoothstep(3400.0, 3900.0, h + detail * 400.0) * (1.0 - smoothstep(0.5, 0.7, slope));
	vec4 w;
	w.w = snow;
	w.z = rock * (1.0 - snow);
	w.y = max(beach, desert) * (1.0 - w.z - w.w);
	w.x = max(1.0 - w.y - w.z - w.w, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 p, float h, vec3 n) {
	float dry = earth_dryness(p);
	float patches = pn_fbm(p / 25000.0 + SEED_OFFSET, 4) * 0.5 + 0.5;
	vec3 forest = vec3(0.55, 0.75, 0.5);
	vec3 savanna = vec3(1.15, 1.0, 0.62);
	vec3 tint = mix(forest, savanna, smoothstep(0.2, 0.7, dry + (patches - 0.5) * 0.3));
	return clamp(tint * (0.85 + patches * 0.25), 0.0, 1.5);
}
]=]

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}
end

if _G.earth then _G.earth.terrain:Stop() end

local earth = {}
_G.earth = earth
earth.terrain = Terrain.New{
	Name = "earth_terrain",
	Source = ShaderSource.New{
		Header = HEADER,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -4200,
		MaxHeight = 6000,
		Layers = {layer("grass", 3), layer("sand", 4), layer("rock", 11), layer("snow", 7)},
	},
	Levels = tonumber(os.getenv("LEVELS")) or 15,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 4,
	BuildsPerFrame = 4,
}:Start()
weather.SetTimeScale(0)
weather.SetSunDirection(Vec3(-0.5, 0.6, 0.35):GetNormalized())
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{WindSpeed = 8, WindDirection = 0}
return earth
