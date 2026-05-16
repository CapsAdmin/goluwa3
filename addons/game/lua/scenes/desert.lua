local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralHeightfield = import("addons/game/lua/terrain/procedural_heightfield.lua")

local function CreateDesertTerrainStreamer()
	return ProceduralHeightfield.New{
		Name = "desert_terrain",
		Seed = 1337,
		ChunkWorldSize = 1024,
		HeightScale = 640,
		VerticalOffset = -96,
		UpdateInterval = 0.05,
		BuildsPerUpdate = 1,
		Roughness = 0.92,
		Metallic = 0.02,
		ChunkRings = {
			{
				chunk_world_size = 1024,
				radius = 1,
				cast_shadows = false,
				mesh_resolution = Vec2() + 96,
				texture_size = 512,
			},
			{
				chunk_world_size = 2048,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 40,
				texture_size = 128,
			},
		},
		FarTerrain = {
			outer_half_size = 32768,
			snap_size = 4096,
			cast_shadows = false,
			mesh_resolution = Vec2() + 48,
			texture_size = 256,
		},
		MaterialBands = {
			{max_elevation = -120, color = {0.26, 0.22, 0.18}},
			{max_elevation = -20, color = {0.48, 0.38, 0.25}},
			{max_elevation = 80, color = {0.72, 0.61, 0.39}},
			{max_elevation = 170, color = {0.84, 0.73, 0.49}},
			{color = {0.95, 0.88, 0.76}},
		},
	}:Start()
end

if _G.desert_terrain_streamer then _G.desert_terrain_streamer:Stop() end

_G.desert_terrain_streamer = CreateDesertTerrainStreamer()
print("Desert terrain streamer created!")
