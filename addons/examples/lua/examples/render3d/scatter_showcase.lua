-- hills and a steep rise, grown over with a scatter set. the terrain's layers are grass, dirt and rock by
-- slope, so the set's slope rules and layer weights show. SCATTER_SET picks the set (crysis_meadow,
-- crysis_forest, crysis_jungle, crysis_rocky with Crysis installed, grass without)
-- luajit glw --3d lua "import('addons/examples/lua/examples/render3d/scatter_showcase.lua')"
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local presets = import("lua/autorun/render_3d/scatter_presets.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local scatter_set = presets[_G.SCATTER_SET or "crysis_jungle"] or ScatterSet.GetGrass()

-- 3 times the density and 10 times the distance of the set
scatter_set:SetDensityMultiplier(3)
scatter_set:SetDistanceMultiplier(10)

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

local function layer(name, scale, scatter)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale, scatter = scatter}
end

if _G.scatter_showcase then _G.scatter_showcase:Stop() end

_G.scatter_showcase = Terrain.New{
	Name = "scatter_showcase",
	ScatterSet = scatter_set,
	Source = ShaderSource.New{
		Header = noise.WORLD,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -20,
		MaxHeight = 80,
		Layers = {
			layer("grass", 3, 1),
			layer("dirt", 3, 1),
			layer("rock", 11, 1),
			layer("snow", 7, 0),
		},
	},
	Levels = 5,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	BuildsPerFrame = 2,
	Physics = {
		chunk_size = 64,
		samples = 65,
		radius = 2,
	},
}:Start()
