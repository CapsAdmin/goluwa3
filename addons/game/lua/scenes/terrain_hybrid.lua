local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainHybridRenderer = import("addons/game/lua/terrain/procedural_terrain_hybrid_renderer.lua")
local ProceduralTerrainSource = import("addons/game/lua/terrain/procedural_terrain_source.lua")
local HEIGHT_SCALE = 280
local TERRAIN_FLOOR_OFFSET = -64
local VERTICAL_OFFSET = HEIGHT_SCALE * 0.5 + TERRAIN_FLOOR_OFFSET
local CELL_SIZE = 320

local function clamp(value, min_value, max_value)
	if value < min_value then return min_value end

	if value > max_value then return max_value end

	return value
end

local function smoothstep(edge0, edge1, value)
	if edge0 == edge1 then return value >= edge1 and 1 or 0 end

	local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function repeat_centered(value, period)
	return ((value + period * 0.5) % period) - period * 0.5
end

local function build_test_source()
	local source = ProceduralTerrainSource.New{
		Seed = 4242,
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		MaterialLayers = {
			{
				max_height01 = 0.38,
				blend_height01 = 0.08,
				max_slope = 0.28,
				slope_blend = 0.10,
				checker_scale = 1,
				roughness = 0.98,
				ambient_occlusion = 0.90,
				color_a = {0.12, 0.20, 0.34},
				color_b = {0.06, 0.10, 0.22},
			},
			{
				max_height01 = 0.52,
				blend_height01 = 0.08,
				min_slope = 0.08,
				max_slope = 0.52,
				slope_blend = 0.12,
				checker_scale = 1,
				roughness = 0.88,
				ambient_occlusion = 0.97,
				color_a = {0.16, 0.34, 0.18},
				color_b = {0.08, 0.20, 0.10},
			},
			{
				max_height01 = 0.66,
				blend_height01 = 0.08,
				min_slope = 0.22,
				max_slope = 0.86,
				slope_blend = 0.14,
				checker_scale = 1,
				roughness = 0.68,
				ambient_occlusion = 0.88,
				color_a = {0.56, 0.40, 0.16},
				color_b = {0.34, 0.22, 0.08},
			},
			{
				blend_height01 = 0.08,
				max_slope = 0.42,
				slope_blend = 0.12,
				checker_scale = 1,
				roughness = 0.38,
				ambient_occlusion = 0.82,
				color_a = {0.84, 0.84, 0.84},
				color_b = {0.58, 0.58, 0.58},
			},
		},
		MaterialBands = {
			{
				max_elevation = VERTICAL_OFFSET - HEIGHT_SCALE * 0.08,
				color = {0.10, 0.16, 0.20},
			},
			{
				max_elevation = VERTICAL_OFFSET + HEIGHT_SCALE * 0.02,
				color = {0.20, 0.27, 0.31},
			},
			{
				max_elevation = VERTICAL_OFFSET + HEIGHT_SCALE * 0.10,
				color = {0.36, 0.40, 0.34},
			},
			{
				max_elevation = VERTICAL_OFFSET + HEIGHT_SCALE * 0.18,
				color = {0.60, 0.58, 0.50},
			},
			{color = {0.84, 0.82, 0.78}},
		},
	}

	function source:GetRepeatedCoords(world_x, world_z)
		return repeat_centered(world_x, CELL_SIZE), repeat_centered(world_z, CELL_SIZE)
	end

	local INDENT1_CENTER_X = -CELL_SIZE * 0.24
	local INDENT1_CENTER_Z = -CELL_SIZE * 0.18
	local INDENT1_INV_RADIUS = 1 / (CELL_SIZE * 0.22)
	local INDENT1_DEPTH = 0.18
	local INDENT2_CENTER_X = CELL_SIZE * 0.20
	local INDENT2_CENTER_Z = CELL_SIZE * 0.12
	local INDENT2_INV_RADIUS = 1 / (CELL_SIZE * 0.16)
	local INDENT2_DEPTH = 0.13
	local INDENT3_CENTER_X = 0
	local INDENT3_CENTER_Z = CELL_SIZE * 0.02
	local INDENT3_INV_RADIUS = 1 / (CELL_SIZE * 0.10)
	local INDENT3_DEPTH = 0.07
	local GROOVE_X_INV_WIDTH = 1 / (CELL_SIZE * 0.11)
	local GROOVE_DIAG_INV_WIDTH = 1 / (CELL_SIZE * 0.10)
	local GROOVE_CROSS_INV_WIDTH = 1 / (CELL_SIZE * 0.16)
	local CENTER_PAD_INNER = CELL_SIZE * 0.12
	local CENTER_PAD_OUTER = CELL_SIZE * 0.20

	function source:SampleHeight01(world_x, world_z)
		local x = repeat_centered(world_x, CELL_SIZE)
		local z = repeat_centered(world_z, CELL_SIZE)
		local height = 0.56
		local dx = (x - INDENT1_CENTER_X) * INDENT1_INV_RADIUS
		local dz = (z - INDENT1_CENTER_Z) * INDENT1_INV_RADIUS
		local d2 = dx * dx + dz * dz

		if d2 < 1 then height = height - math.sqrt(1 - d2) * INDENT1_DEPTH end

		dx = (x - INDENT2_CENTER_X) * INDENT2_INV_RADIUS
		dz = (z - INDENT2_CENTER_Z) * INDENT2_INV_RADIUS
		d2 = dx * dx + dz * dz

		if d2 < 1 then height = height - math.sqrt(1 - d2) * INDENT2_DEPTH end

		dx = x * INDENT3_INV_RADIUS
		dz = (z - INDENT3_CENTER_Z) * INDENT3_INV_RADIUS
		d2 = dx * dx + dz * dz

		if d2 < 1 then height = height - math.sqrt(1 - d2) * INDENT3_DEPTH end

		local abs_x = math.abs(x)
		local abs_z = math.abs(z)
		local groove_x = math.max(0, 1 - abs_x * GROOVE_X_INV_WIDTH)
		local groove_diag = math.max(0, 1 - math.abs(z - x * 0.55) * GROOVE_DIAG_INV_WIDTH)
		local groove_cross = math.max(0, 1 - math.abs(x + z) * GROOVE_CROSS_INV_WIDTH)
		local center_pad = 1 - smoothstep(CENTER_PAD_INNER, CENTER_PAD_OUTER, math.max(abs_x, abs_z))
		height = height + groove_x * 0.06
		height = height + groove_diag * 0.05
		height = height + groove_cross * 0.03
		height = height + center_pad * 0.04
		return clamp(height, 0.18, 0.82)
	end

	function source:SampleDisplacement01(world_x, world_z, height01)
		local x, z = self:GetRepeatedCoords(world_x, world_z)
		local groove_x = math.max(0, 1 - math.abs(x) / (CELL_SIZE * 0.11))
		local groove_diag = math.max(0, 1 - math.abs(z - x * 0.55) / (CELL_SIZE * 0.10))
		local dents = clamp((0.56 - height01) * 2.0, 0, 1)
		local detail = 0.5 + groove_x * 0.08 + groove_diag * 0.07 - dents * 0.06
		return clamp(detail, 0, 1)
	end

	function source:SampleColorDetail(world_x, world_z, elevation, height01)
		return 1, 1, 1
	end

	return source
end

local function CreateHybridTerrainRenderer()
	return ProceduralTerrainHybridRenderer.New{
		Name = "terrain_hybrid_scene",
		Seed = 4242,
		Source = build_test_source(),
		ChunkWorldSize = 512,
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		UpdateInterval = 0.05,
		BuildsPerUpdate = 1,
		Roughness = 0.95,
		Metallic = 0.01,
		ChunkRings = {
			{
				chunk_world_size = 512,
				radius = 1,
				cast_shadows = false,
				mesh_resolution = Vec2() + 128,
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 512,
				height_texture_size = 512,
				normal_texture_size = 512,
				material_texture_size = 512,
				normal_strength = 1.4,
				height_layers = 20,
				tessellation_factor = 16,
			},
			{
				chunk_world_size = 1536,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 56,
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 192,
				height_texture_size = 256,
				normal_texture_size = 256,
				material_texture_size = 192,
				normal_strength = 1.15,
				height_layers = 12,
				tessellation_factor = 8,
			},
		},
		FarTerrain = {
			outer_half_size = 24576,
			snap_size = 3072,
			cast_shadows = false,
			mesh_resolution = Vec2() + 72,
			albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
			texture_size = 192,
			height_texture_size = 384,
			normal_texture_size = 192,
			material_texture_size = 192,
			normal_strength = 1.0,
			height_layers = 12,
			tessellation_factor = 6,
		},
	}:Start()
end

if _G.terrain_hybrid_scene_renderer then
	_G.terrain_hybrid_scene_renderer:Stop()
end

_G.terrain_hybrid_scene_renderer = CreateHybridTerrainRenderer()
print(
	"Hybrid terrain scene renderer created with repeated blob-and-groove test pattern!"
)

if not _G.terrain_hybrid_scene_renderer.SupportsTessellation then
	print(
		"Hybrid terrain scene warning: tessellation is unsupported on this device, so tiles will stay flat."
	)
end
