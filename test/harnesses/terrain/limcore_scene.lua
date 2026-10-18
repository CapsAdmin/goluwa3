-- the Limcore Terrain project (local_stuff/terrain) as a goluwa terrain: its 15 octave eroded value noise height, grass and rock by steepness, snow by height, with its textures
-- luajit glw --3d --background shot tmp/out.png --setup test/harnesses/terrain/limcore_scene.lua --pos -30468,-1780,13281 --ang -8,30,0 --fov 70 --settle 8
-- replica of local_stuff/terrain/Terrain (ferrefire): heightmap fbm with erosion, grass/rock by steepness, snow by height
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local assets = import("goluwa/assets.lua")
local vfs = import("goluwa/vfs.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local render3d = import("goluwa/render3d/render3d.lua")
vfs.Mount("os:" .. vfs.GetStorageDirectory("working_directory") .. "local_stuff/terrain/Terrain/resources/")
local DIR = "textures/"
local MAX_HEIGHT = 5000

local HEIGHT_GLSL = [=[
float lc_rnd(vec2 p, float seed) {
	p += vec2(seed, seed * 1.6180339);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 lc_value_noise(vec2 x, float seed) {
	vec2 pi = floor(x);
	vec2 pf = fract(x);
	float a = lc_rnd(pi, seed);
	float b = lc_rnd(pi + vec2(1.0, 0.0), seed);
	float c = lc_rnd(pi + vec2(0.0, 1.0), seed);
	float d = lc_rnd(pi + 1.0, seed);
	vec2 u = pf * pf * pf * (pf * (pf * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * pf * pf * (pf - 1.0) * (pf - 1.0);
	float k1 = b - a;
	float k2 = c - a;
	float k3 = a - b - c + d;
	return vec3(a + k1 * u.x + k2 * u.y + k3 * u.x * u.y, (k1 + k3 * u.y) * du.x, (k2 + k3 * u.x) * du.y);
}

// the original runs 15 octaves on the nearest heightmap and fewer on the coarse ones. here an octave stops once its
// wavelength is under two samples, and the sum is normalised by the full 15 so levels agree
float terrain_height(vec2 world) {
	const mat2 m = mat2(0.825, -0.6, 0.6, 0.825);
	const float erosion = 2.5;
	const float seed = 0.303586;
	vec2 p = world / 10000.0;
	float step_uv = terrain_bake_step() / 10000.0;
	float a = 0.0;
	float b = 1.0;
	float total = 0.0;
	float full_total = 0.0;
	float wavelength = 1.0;
	vec2 d = vec2(0.0);
	int used = 15;

	for (int i = 0; i < 15; i++) {
		full_total += b;
		b *= 0.5;
	}

	b = 1.0;

	for (int i = 0; i < 15; i++) {
		if (wavelength < step_uv * 2.0) {
			used = i;
			break;
		}

		vec3 n = lc_value_noise(p, seed);
		d += n.yz;
		a += b * n.x / (1.0 + dot(d, d) * erosion);
		b *= 0.5;
		p = m * p * 2.0;
		wavelength *= 0.5;
	}

	// the octaves a coarse bake leaves out have a mean of 0.5 each, without them the level sits lower than the finer ones
	if (used < 15) a += b * 2.0 * (1.0 - pow(0.5, float(15 - used))) * 0.5 / (1.0 + dot(d, d) * erosion);

	return (a / full_total - 0.5) * 5000.0;
}
]=]

local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	float steepness = 1.0 - (n.y * 0.5 + 0.5);
	float rock = clamp((steepness - 0.075) / 0.025, 0.0, 1.0);
	float snow_amount = pow(clamp(h + 1250.0, 0.0, 1500.0) / 1500.0, 0.75);
	float diff = mix(0.0, 0.3, snow_amount) - steepness;
	float snow = clamp(diff / 0.05, 0.0, 1.0);
	float rest = 1.0 - snow;
	return vec4((1.0 - rock) * rest, rock * rest, snow, 0.0);
}
]=]

local function tex(name, srgb)
	return assert(assets.GetTexture(DIR .. name .. ".jpg", {config = {srgb = srgb}}), name)
end

local function layer(albedo, normal, scale)
	return {albedo = tex(albedo, true), normal = tex(normal, false), scale = scale}
end

if _G.limterrain then _G.limterrain:Stop() end

_G.limterrain = Terrain.New{
	Name = "limterrain",
	Source = ShaderSource.New{
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		MinHeight = -MAX_HEIGHT * 0.5,
		MaxHeight = MAX_HEIGHT * 0.5,
		Layers = {
			layer("rocky_terrain_diff", "rocky_terrain_norm", 8),
			layer("rock_diff", "rock_norm", 5),
			{albedo = terrain_textures.snow.albedo, normal = terrain_textures.snow.normal, scale = 7},
			layer("rock_diff", "rock_norm", 5),
		},
	},
	Levels = 9,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ShadowLevels = 4,
	BVHLevels = 0,
}:Start()
return _G.limterrain
