local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local HEADER = [=[
float bed_offset(vec2 world) {
	return world.y - sin(world.x * 0.012) * 70.0;
}
]=]
local HEIGHT_GLSL = [=[
float terrain_height(vec2 world) {
	float v = abs(bed_offset(world));
	float bank = smoothstep(30.0, 220.0, v);
	float hills = pn_fbm(world * 0.006, 5) * 90.0;
	float detail = pn_fbm(world * 0.05, 3) * 1.2;
	return v * 0.18 * smoothstep(20.0, 120.0, v) + hills * bank + detail * (1.0 - bank);
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	float steepness = 1.0 - (n.y * 0.5 + 0.5);
	float v = abs(bed_offset(world));
	float bed = 1.0 - smoothstep(25.0, 70.0, v);
	float field = smoothstep(0.5, 0.62, pn_fbm(world * 0.045 + 11.0, 4));
	float slope_rock = smoothstep(0.035, 0.07, steepness);
	float boulders = max(slope_rock, field * (1.0 - smoothstep(60.0, 120.0, v)) * 0.95);
	float gravel = bed * (1.0 - boulders) + (1.0 - boulders) * smoothstep(0.4, 0.7, pn_fbm(world * 0.02 + 3.0, 3)) * 0.45;
	float rest = max(1.0 - boulders - gravel, 0.0);
	float grass = rest * smoothstep(0.45, 0.6, pn_fbm(world * 0.015 + 7.0, 3));
	vec4 w = vec4(gravel, boulders, rest - grass, grass);
	return w / max(w.x + w.y + w.z + w.w, 0.001);
}
]=]

local function layer(name, scale, extra)
	local textures = terrain_textures[name]
	local out = {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}

	for k, v in pairs(extra or {}) do
		out[k] = v
	end

	return out
end

if _G.rocky_terrain then _G.rocky_terrain:Stop() end

_G.rocky_terrain = Terrain.New(
	table.merge(
		{
			Name = "rocky_terrain",
			Source = ShaderSource.New{
				Header = noise.WORLD .. HEADER,
				HeightGLSL = HEIGHT_GLSL,
				SplatGLSL = SPLAT_GLSL,
				MinHeight = -20,
				MaxHeight = 160,
				Layers = {
					layer(
						"gravel",
						2.5,
						{height = terrain_textures.gravel.height, height_scale = 0.025, height_blend = 1}
					),
					layer(
						"boulders",
						7,
						{
							height = terrain_textures.boulders.height,
							height_scale = 0.06,
							height_blend = 1,
						}
					),
					layer("dirt", 3),
					layer("grass", 3),
				},
			},
			Levels = 8,
			BaseChunkSize = 64,
			Samples = 65,
			DetailSize = 256,
			SplatSize = 128,
			ShadowLevels = 5,
			BuildsPerFrame = 3,
			Physics = {chunk_size = 64, samples = 65, radius = 2},
		},
		_G.TERRAIN_OVERRIDES or {}
	)
):Start()
