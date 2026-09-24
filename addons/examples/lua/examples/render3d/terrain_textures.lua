--[[
	Terrain layer texture preview. A small, gently rolling terrain shows each
	layer in a strip along x (grass, dirt, rock, snow from -x to +x) through
	the real terrain shader path, and a sphere above each strip shows the
	same textures on an ordinary material.
]]
local Vec3 = import("goluwa/structs/vec3.lua")
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local shapes = import("lua/shapes.lua")
local assets = import("goluwa/assets.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local LAYER_NAMES = {"grass", "dirt", "rock", "snow"}
local LAYER_SCALES = {3, 3, 11, 7}
local STRIP_WIDTH = 12

local function layer(index)
	local textures = terrain_textures[LAYER_NAMES[index]]
	return {
		name = LAYER_NAMES[index],
		albedo = textures.albedo,
		normal = textures.normal,
		scale = LAYER_SCALES[index],
	}
end

if _G.terrain_textures_preview then _G.terrain_textures_preview:Stop() end

_G.terrain_textures_preview = Terrain.New{
	Name = "terrain_textures_preview",
	Source = ShaderSource.New{
		Header = noise.WORLD .. string.format("const float STRIP_WIDTH = %f;\n", STRIP_WIDTH),
		HeightGLSL = [=[
			float terrain_height(vec2 world) {
				float hills = pn_fbm(world * 0.08, 3) * 2.5;
				float mound = exp(-dot(world - vec2(0.0, -8.0), world - vec2(0.0, -8.0)) * 0.02) * 3.0;
				return hills + mound;
			}
		]=],
		SplatGLSL = [=[
			vec4 terrain_splat(vec2 world, float h, vec3 n) {
				float strip = (world.x + STRIP_WIDTH * 2.0) / STRIP_WIDTH;
				vec4 w = vec4(0.0);
				w.x = 1.0 - smoothstep(0.75, 1.25, strip);
				w.y = smoothstep(0.75, 1.25, strip) * (1.0 - smoothstep(1.75, 2.25, strip));
				w.z = smoothstep(1.75, 2.25, strip) * (1.0 - smoothstep(2.75, 3.25, strip));
				w.w = smoothstep(2.75, 3.25, strip);
				return w;
			}
		]=],
		MinHeight = -10,
		MaxHeight = 10,
		Layers = {layer(1), layer(2), layer(3), layer(4)},
	},
	Levels = 3,
	BaseChunkSize = 16,
	Samples = 33,
	DetailSize = 256,
	SplatSize = 128,
	ShadowLevels = 2,
	BuildsPerUpdate = 4,
	Physics = {chunk_size = 16, samples = 33, radius = 2},
}:Start()

for index, name in ipairs(LAYER_NAMES) do
	local textures = terrain_textures[name]
	shapes.Sphere{
		Name = "terrain_texture_sphere_" .. name,
		Position = Vec3((index - 2.5) * STRIP_WIDTH, 6, 0),
		Radius = 2,
		Material = {
			AlbedoTexture = assets.GetTexture(textures.albedo),
			NormalTexture = assets.GetTexture(textures.normal),
			RoughnessMultiplier = 0.85,
			MetallicMultiplier = 0,
		},
		Collision = false,
	}
end
