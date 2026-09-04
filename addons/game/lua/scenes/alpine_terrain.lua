--[[
	Alpine terrain: the look of this landscape lives here. The engine only
	provides the streaming, LOD, physics and the GLSL bake helpers.
]]
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local SEED = 4242
local BASE_HEIGHT = 0
local MOUNTAIN_HEIGHT = 1800
local FEATURE_SCALE = 0.001
local HEIGHT_GLSL = [=[
// octaves finer than the bake step fade out, so far LOD levels stay smooth instead of aliasing
float terrain_height(vec2 world) {
	vec2 p = (world + SEED_OFFSET) * FEATURE_SCALE;
	float step = terrain_bake_step();
	float unit = 1.0 / FEATURE_SCALE;
	float continent = pn_fbm(p * 0.12 + vec2(3.7, -2.1), 3);
	float mountain_mask = smoothstep(-0.35, 0.45, continent);
	vec2 warp = vec2(pn_fbm(p * 0.6 + vec2(11.3, 4.2), 3), pn_fbm(p * 0.6 - vec2(7.1, 2.9), 3)) * 0.35;
	float ridges = pn_ridged_lod((p + warp) * 0.55, 7, 1.0, 2.0, unit / 0.55, step);
	float hills = pn_fbm_lod(p * 1.3 + vec2(5.0, 1.5), 5, unit / 1.3, step);
	float detail = pn_fbm_lod(p * 9.0 + vec2(1.0, 8.0), 4, unit / 9.0, step);
	float valley = smoothstep(0.12, 0.5, ridges);
	float h = BASE_HEIGHT;
	h += hills * 45.0 * (1.0 - mountain_mask * 0.6) + hills * 25.0;
	h += pow(ridges, 1.6) * MOUNTAIN_HEIGHT * mountain_mask;
	h += detail * (3.0 + 14.0 * mountain_mask * valley);
	return h;
}
]=]
-- layer weights: x = grass, y = dirt, z = rock, w = snow
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	vec2 p = world + SEED_OFFSET;
	float slope = 1.0 - n.y;
	float breakup = pn_fbm(p * 0.002 + vec2(3.0, 5.0), 3) * 0.5;
	float breakup_fine = pn_fbm(p * 0.012 + vec2(9.0, -4.0), 3) * 0.5;
	float altitude = clamp((h - BASE_HEIGHT) / MOUNTAIN_HEIGHT, 0.0, 1.0);
	float snow_line = 0.68 + breakup * 0.25;
	float snow = smoothstep(snow_line - 0.05, snow_line + 0.1, altitude) * (1.0 - smoothstep(0.25, 0.5, slope + breakup_fine * 0.1));
	float rock = smoothstep(0.16, 0.34, slope + breakup_fine * 0.14);
	float dirt = smoothstep(0.06, 0.2, slope + breakup_fine * 0.1) + smoothstep(0.28, 0.5, altitude + breakup * 0.3) * 0.7;
	dirt = clamp(dirt, 0.0, 1.0);
	float grass_dirt = dirt * (1.0 - rock);
	float rock_left = rock * (1.0 - snow);
	vec4 w;
	w.w = snow;
	w.z = rock_left;
	w.y = grass_dirt * (1.0 - snow);
	w.x = max(1.0 - w.w - w.z - w.y, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
-- low frequency tint multiplied over the layers so the tiling textures do not read as a grid.
-- keep it smooth: the colour texture is 1 m per texel near the camera and 32 m far away,
-- anything finer aliases into a dot pattern on distant slopes
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	vec2 p = world + SEED_OFFSET;
	float patches = pn_fbm(p * 0.008 + vec2(1.0, 7.0), 3);
	float dry = smoothstep(0.05, 0.45, patches);
	float shade = 0.9 + pn_fbm(p * 0.003 + vec2(8.0, 3.0), 2) * 0.12;
	vec3 tint = mix(vec3(1.0), vec3(1.0, 0.9, 0.64), dry * 0.5);
	return clamp(tint * shade, 0.0, 1.0);
}
]=]

local function build_header()
	return noise.WORLD .. string.format(
			[=[
const vec2 SEED_OFFSET = vec2(%f, %f);
const float BASE_HEIGHT = %f;
const float MOUNTAIN_HEIGHT = %f;
const float FEATURE_SCALE = %f;
]=],
			math.sin(SEED * 12.9898) * 16384.0,
			math.cos(SEED * 78.2330) * 16384.0,
			BASE_HEIGHT,
			MOUNTAIN_HEIGHT,
			FEATURE_SCALE
		)
end

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}
end

if _G.alpine_terrain then _G.alpine_terrain:Stop() end

_G.alpine_terrain = Terrain.New{
	Name = "alpine_terrain",
	Source = ShaderSource.New{
		Header = build_header(),
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = BASE_HEIGHT - 120,
		MaxHeight = BASE_HEIGHT + MOUNTAIN_HEIGHT + 120,
		Layers = {
			layer("grass", 3),
			layer("dirt", 3),
			layer("rock", 11),
			layer("snow", 7),
		},
	},
	Levels = 8,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 3,
	BuildsPerUpdate = 3,
	Physics = {
		chunk_size = 64,
		samples = 65,
		radius = 2,
	},
}:Start()
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(100)
