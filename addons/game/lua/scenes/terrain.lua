local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralHeightfield = import("addons/game/lua/terrain/procedural_heightfield.lua")
local HEIGHT_SCALE = 2200
local TERRAIN_FLOOR_OFFSET = -64
local VERTICAL_OFFSET = HEIGHT_SCALE * 0.5 + TERRAIN_FLOOR_OFFSET
local ELEVATION_SHIFT = VERTICAL_OFFSET - (-420)

local function CreateTerrainStreamer()
	return ProceduralHeightfield.New{
		Name = "terrain_scene",
		Seed = 4242,
		TerrainProfile = "alpine",
		ChunkWorldSize = 768,
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		UpdateInterval = 0.05,
		BuildsPerUpdate = 1,
		Roughness = 0.95,
		Metallic = 0.01,
		ChunkRings = {
			{
				chunk_world_size = 768,
				radius = 1,
				cast_shadows = false,
				mesh_resolution = Vec2() + 128,
				height_smoothing = 0.6,
				texture_size = 512,
				displacement_texture_size = 1024,
				displacement_scale = 2.5,
				height_layers = 20,
				tessellation_factor = 16,
			},
			{
				chunk_world_size = 1536,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 56,
				height_smoothing = 0.6,
				texture_size = 192,
				displacement_texture_size = 512,
				displacement_scale = 0.06,
				height_layers = 12,
				tessellation_factor = 4,
			},
		},
		FarTerrain = {
			outer_half_size = 49152,
			snap_size = 6144,
			cast_shadows = false,
			mesh_resolution = Vec2() + 56,
			texture_size = 256,
		},
		MaterialBands = {
			{max_elevation = -350 + ELEVATION_SHIFT, color = {0.09, 0.17, 0.11}},
			{max_elevation = 120 + ELEVATION_SHIFT, color = {0.20, 0.31, 0.18}},
			{max_elevation = 700 + ELEVATION_SHIFT, color = {0.34, 0.39, 0.28}},
			{max_elevation = 1350 + ELEVATION_SHIFT, color = {0.46, 0.47, 0.44}},
			{max_elevation = 1850 + ELEVATION_SHIFT, color = {0.64, 0.64, 0.66}},
			{color = {0.95, 0.97, 1.0}},
		},
	}:Start()
end

if _G.terrain_scene_streamer then _G.terrain_scene_streamer:Stop() end

_G.terrain_scene_streamer = CreateTerrainStreamer()
print("Terrain scene streamer created!")
