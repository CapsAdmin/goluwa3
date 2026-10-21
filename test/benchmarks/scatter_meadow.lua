-- glw: --3d
local frame_benchmark = import("goluwa/render3d/frame_benchmark.lua")
local pvars = import("goluwa/cli/pvars.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local presets = import("lua/autorun/render_3d/scatter_presets.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local set_name = os.getenv("SCATTER_SET") or "crysis_meadow"
local scatter_set = presets[set_name] or ScatterSet.GetGrass()
set_name = scatter_set:GetName()

local HEIGHT_GLSL = [=[
float terrain_height(vec2 w) {
	return 8.0 + 3.0 * sin(w.x * 0.045) * cos(w.y * 0.037) + 1.2 * sin(w.x * 0.31 + w.y * 0.17) * sin(w.y * 0.23);
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	return vec4(1.0, 0.0, 0.0, 0.0);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	return vec3(1.0);
}
]=]
local textures = terrain_textures.grass
frame_benchmark.Run{
	name = "Scatter meadow " .. set_name .. (os.getenv("SCATTER_OFF") and " (off)" or ""),
	warmup = 12,
	load = function()
		if os.getenv("SCATTER_OFF") then pvars.SetSession("r_feature_scatter", false) end

		Terrain.New{
			Name = "scatter_meadow",
			ScatterSet = scatter_set,
			Source = ShaderSource.New{
				Header = noise.WORLD,
				HeightGLSL = HEIGHT_GLSL,
				SplatGLSL = SPLAT_GLSL,
				ColorGLSL = COLOR_GLSL,
				MinHeight = -20,
				MaxHeight = 40,
				Layers = {{name = "grass", albedo = textures.albedo, normal = textures.normal, scale = 3, scatter = 1}},
			},
			Levels = 5,
			BaseChunkSize = 64,
			Samples = 65,
			DetailSize = 256,
			SplatSize = 128,
			ColorSize = 64,
			BuildsPerFrame = 2,
		}:Start()
	end,
	view = function()
		return Vec3(0, 10, 0), -3, 0
	end,
	phases = {
		{name = "static"},
		{name = "rotating 90 deg/s", yaw_speed = 90},
		{name = "moving 10 m/s", speed = 10, travel = 100},
	},
}
