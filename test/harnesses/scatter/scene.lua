local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
-- hills with a steep rise at 70,10 and a bump at -40,60, scatter_forest_height(x, z) is the terrain height
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local presets = import("lua/autorun/render_3d/scatter_presets.lua")
local SET = presets[os.getenv("SET") or "crysis_meadow"] or ScatterSet.GetGrass()
-- BB_SCALE=0.3 scales the scatter billboard distance, BB_OFF=1 turns the billboards off
local pvars = import("goluwa/cli/pvars.lua")
if os.getenv("BB_SCALE") then pvars.SetSession("r_scatter_billboard_distance", tonumber(os.getenv("BB_SCALE"))) end
if os.getenv("GI_OFF") then pvars.SetSession("r_scatter_gi", false) end
if os.getenv("BB_OFF") then pvars.SetSession("r_scatter_billboards", false) end

local HEIGHT_GLSL = [=[
float terrain_height(vec2 w) {
	float h = 8.0 + 3.0 * sin(w.x * 0.045) * cos(w.y * 0.037);
	h += 22.0 * exp(-(pow(w.x - 70.0, 2.0) + pow(w.y - 10.0, 2.0)) / 900.0);
	h += 9.0 * exp(-(pow(w.x + 40.0, 2.0) + pow(w.y - 60.0, 2.0)) / 300.0);
	h += 1.2 * sin(w.x * 0.31 + w.y * 0.17) * sin(w.y * 0.23);
	return h;
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	float slope = 1.0 - n.y;
	float rock = smoothstep(0.12, 0.28, slope);
	float dirt = smoothstep(0.03, 0.12, slope) * (1.0 - rock);
	vec4 w = vec4(max(1.0 - rock - dirt, 0.0), dirt, rock, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	return vec3(1.0);
}
]=]
local function layer(name, scale, extra)
	local t = terrain_textures[name]
	local l = {name = name, albedo = t.albedo, normal = t.normal, scale = scale}
	for k, v in pairs(extra or {}) do l[k] = v end
	return l
end
if _G.scatter_terrain then _G.scatter_terrain:Stop() end
_G.scatter_terrain = Terrain.New{
	Name = "scatter_terrain",
	ScatterSet = SET,
	Source = ShaderSource.New{
		Header = noise.WORLD,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -20,
		MaxHeight = 80,
		Layers = {
			layer("grass", 3, {scatter = 1}),
			layer("dirt", 3, {scatter = 1}),
			layer("rock", 11, {scatter = 1}),
			layer("snow", 7),
		},
	},
	Levels = 5,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	BuildsPerFrame = 2,
}:Start()

function _G.scatter_height(x, z)
	local h = 8 + 3 * math.sin(x * 0.045) * math.cos(z * 0.037)
	h = h + 22 * math.exp(-((x - 70) ^ 2 + (z - 10) ^ 2) / 900)
	h = h + 9 * math.exp(-((x + 40) ^ 2 + (z - 60) ^ 2) / 300)
	h = h + 1.2 * math.sin(x * 0.31 + z * 0.17) * math.sin(z * 0.23)
	return h
end
