local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainHybridRenderer = import("addons/game/lua/terrain/render.lua")
local ProceduralTerrainSource = import("addons/game/lua/terrain/source.lua")
local HEIGHT_SCALE = 2200
local VERTICAL_OFFSET = 260
local ALPINE_TERRAIN_SHADER_GLSL = [[
const mat2 ALPINE_TERRAIN_TWIST = mat2(1.3623, 1.7531, -1.7131, 1.4623);

float sampleAlpineMountainMass01(vec2 world_pos) {
	vec2 pos = world_pos * 0.00078;
	float weight = n2D(pos * 0.25 + vec2(2.0, -3.0)) * 0.75 + 0.15;
	float amplitude = 1.34 * weight * weight;
	float sum = 0.0;

	for (int i = 0; i < 5; i++) {
		float octave = n2D(pos) * 2.0 - 1.0;
		sum += amplitude * octave;
		amplitude *= -0.42;
		pos = ALPINE_TERRAIN_TWIST * pos;
	}

	float macro = n2D(pos * 0.003 + vec2(-6.0, 4.0)) * 2.0 - 1.0;
	float distant_ranges = pow(abs(macro), 5.0) * 1.28;
	float ridges = pow(clamp(ridgeNoise(world_pos * 0.0015 + vec2(8.0, -5.0)), 0.0, 1.0), 2.2);
	float secondary_ridges = pow(clamp(ridgeNoise(world_pos * 0.0030 + vec2(-13.0, 11.0)), 0.0, 1.0), 3.3);
	float valleys = 1.0 - smoothstep(0.24, 0.84, n2D(world_pos * 0.00024 + vec2(6.0, -9.0)));
	float mass = 0.43 + sum * 0.46 + distant_ranges * 0.30 + ridges * 0.14 + secondary_ridges * 0.08;
	mass *= mix(0.42, 1.0, valleys);
	return clamp(mass, 0.0, 1.0);
}

float sampleTerrainHeight01(vec2 world_pos) {
	float mass = sampleAlpineMountainMass01(world_pos);
	float sharp = pow(clamp(ridgeNoise(world_pos * 0.0048 + vec2(-19.0, 7.0)), 0.0, 1.0), 3.0);
	float shelf = gradN2D(world_pos * 0.0014 + vec2(9.0, -12.0));
	float erosion = gradN2D(world_pos * 0.0038 + vec2(-14.0, 5.0));
	float gully_a = 1.0 - ridgeNoise(world_pos * vec2(0.0016, 0.0048) + vec2(17.0, -9.0));
	float gully_b = 1.0 - ridgeNoise(world_pos.yx * vec2(0.0014, 0.0042) + vec2(-12.0, 8.0));
	float gullies = clamp(gully_a * 0.6 + gully_b * 0.4, 0.0, 1.0);
	float erosion_mask = smoothstep(0.36, 0.86, mass);
	float h = smoothstep(0.16, 0.95, mass);
	h = mix(h, 1.0 - pow(1.0 - h, 2.25), 0.34);
	h += sharp * smoothstep(0.46, 0.90, h) * 0.05;
	h -= pow(gullies, 1.8) * erosion_mask * 0.08;
	h += max(shelf - 0.80, 0.0) * 0.04;
	h += (erosion - 0.5) * 0.04;
	return clamp(h, 0.02, 1.0);
}

float sampleTerrainDisplacement01(vec2 world_pos, float h01) {
	float strata = gradN2D(world_pos * vec2(0.010, 0.028) + vec2(4.0, -6.0));
	float cracks = ridgeNoise(world_pos * 0.046 + vec2(-11.0, 14.0));
	float talus = gradN2D(world_pos * 0.080 + vec2(13.0, -9.0));
	float ledges = ridgeNoise(world_pos * vec2(0.018, 0.052) + vec2(-4.0, 9.0));
	float wash = 1.0 - ridgeNoise(world_pos * vec2(0.014, 0.041) + vec2(9.0, -13.0));
	float snow = smoothstep(0.66, 0.94, h01);
	float cliffs = smoothstep(0.56, 0.90, h01);
	float detail = strata * 0.26 + cracks * 0.26 + talus * 0.10 + ledges * 0.24 + wash * 0.14;
	detail = mix(detail, ledges * 0.65 + cracks * 0.35, cliffs * 0.55);
	detail = mix(detail, 0.5, snow * 0.78);
	return clamp(0.5 + (detail - 0.5) * 0.34, 0.0, 1.0);
}

vec3 sampleTerrainColorDetail(vec2 world_pos, float elevation, float h01) {
	float weathering = gradN2D(world_pos * 0.0024 + vec2(3.0, -4.0)) * 0.55 + gradN2D(world_pos * 0.009) * 0.45;
	float snow = smoothstep(0.66, 0.96, h01);
	float cold = smoothstep(260.0, 620.0, elevation);
	vec3 tint = vec3(mix(0.74, 1.06, weathering));
	tint = mix(tint, vec3(0.88, 0.92, 0.98), cold * 0.18);
	tint = mix(tint, vec3(1.02, 1.03, 1.05), snow * 0.52);
	return tint;
}
]]
local ALPINE_SCENE_SHADER_GLSL = [[
float shapeAlpineSceneHeight01(float base_height, vec2 terrain_world_pos) {
	float valley = 1.0 - smoothstep(0.18, 0.82, n2D(terrain_world_pos * 0.00018 + vec2(5.0, -7.0)));
	float basin = 1.0 - smoothstep(0.26, 0.74, n2D(terrain_world_pos * 0.00052 + vec2(-3.0, 9.0)));
	float ridge = smoothstep(0.12, 0.98, base_height);
	float shoulders = 1.0 - pow(1.0 - ridge, 2.35);
	float face_breakup = pow(clamp(ridgeNoise(terrain_world_pos * 0.0018 + vec2(12.0, -8.0)), 0.0, 1.0), 2.5);
	float shaped = mix(ridge, shoulders, 0.44);
	shaped += face_breakup * smoothstep(0.40, 0.88, ridge) * 0.035;
	shaped -= valley * 0.06;
	shaped -= basin * 0.04;
	return clamp(shaped, 0.06, 1.0);
}

float sampleSceneTerrainHeight01(vec2 source_world_pos, vec2 terrain_world_pos) {
	float base_height = sampleTerrainHeight01(source_world_pos);
	return shapeAlpineSceneHeight01(base_height, terrain_world_pos);
}

float sampleSceneTerrainSlope01(vec2 source_world_pos, vec2 terrain_world_pos, vec2 sample_step, float height_scale) {
	float h_left = sampleSceneTerrainHeight01(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * height_scale;
	float h_right = sampleSceneTerrainHeight01(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * height_scale;
	float h_down = sampleSceneTerrainHeight01(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * height_scale;
	float h_up = sampleSceneTerrainHeight01(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * height_scale;
	float dx = (h_right - h_left) / max(sample_step.x * 2.0, 0.0001);
	float dz = (h_up - h_down) / max(sample_step.y * 2.0, 0.0001);
	return smoothstep(0.04, 1.2, sqrt(dx * dx + dz * dz));
}

float sampleSceneTerrainDisplacement01(vec2 source_world_pos, vec2 terrain_world_pos, float h01) {
	return sampleTerrainDisplacement01(source_world_pos, h01);
}

vec4 sampleSceneTerrainMaterialWeights(vec2 source_world_pos, vec2 terrain_world_pos, float elevation, float h01, float slope01) {
	float lowland = 1.0 - smoothstep(20.0, 150.0, elevation);
	float alpine = smoothstep(40.0, 220.0, elevation) * (1.0 - smoothstep(280.0, 480.0, elevation));
	float cliff = smoothstep(0.22, 0.68, slope01) * (1.0 - smoothstep(520.0, 700.0, elevation) * 0.35);
	float snowline = smoothstep(360.0, 620.0, elevation);
	float sheltered_snow = snowline * (0.45 + (1.0 - smoothstep(0.35, 0.86, slope01)) * 0.55);
	float w1 = lowland * (1.0 - smoothstep(0.28, 0.52, slope01));
	float w2 = alpine * (1.0 - smoothstep(0.42, 0.72, slope01));
	float w3 = cliff;
	float w4 = sheltered_snow;
	vec4 weights = max(vec4(w1, w2, w3, w4), vec4(0.0));
	float total = dot(weights, vec4(1.0));

	if (total <= 0.0001) {
		return elevation <= 20.0 ? vec4(1.0, 0.0, 0.0, 0.0) : elevation <= 280.0 ? vec4(0.0, 1.0, 0.0, 0.0) : elevation <= 540.0 ? vec4(0.0, 0.0, 1.0, 0.0) : vec4(0.0, 0.0, 0.0, 1.0);
	}

	return weights / total;
}

vec3 sampleAlpineSceneGrass(vec2 terrain_world_pos, float elevation, float slope01) {
	float macro = gradN2D(terrain_world_pos * 0.0011 + vec2(7.0, -3.0));
	float blades = gradN2D(terrain_world_pos * 0.022 + vec2(4.0, -2.0));
	float wetness = 1.0 - smoothstep(0.0, 120.0, elevation);
	float exposure = 1.0 - smoothstep(0.18, 0.54, slope01);
	vec3 base = vec3(mix(0.16, 0.25, macro), mix(0.18, 0.34, macro), mix(0.08, 0.14, macro));
	float blade_tint = 0.84 + blades * 0.18;
	return clamp(base * blade_tint + vec3(-0.03, 0.02, 0.01) * wetness + vec3(0.03, 0.03, 0.02) * exposure, vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneGround(vec2 terrain_world_pos, float elevation) {
	float soil = gradN2D(terrain_world_pos * 0.0020 + vec2(13.0, -4.0)) * 0.65 + gradN2D(terrain_world_pos * 0.0082 + vec2(-6.0, 9.0)) * 0.35;
	float moraine = ridgeNoise(terrain_world_pos * 0.014 + vec2(5.0, -8.0));
	float runoff = 1.0 - ridgeNoise(terrain_world_pos * vec2(0.004, 0.012) + vec2(-7.0, 11.0));
	float thaw = smoothstep(60.0, 240.0, elevation);
	vec3 base = vec3(mix(0.28, 0.44, soil), mix(0.24, 0.34, soil), mix(0.14, 0.18, soil));
	float moraine_dark = 1.0 - moraine * 0.12;
	return clamp(vec3(base.r * moraine_dark + thaw * 0.02 + runoff * 0.03, base.g * moraine_dark + thaw * 0.02 + runoff * 0.02, base.b * moraine_dark), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneRock(vec2 terrain_world_pos, float slope01) {
	float strata = gradN2D(terrain_world_pos * vec2(0.0048, 0.013) + vec2(9.0, -7.0)) * 0.6 + gradN2D(terrain_world_pos * vec2(0.011, 0.024) + vec2(-4.0, 6.0)) * 0.4;
	float cracks = ridgeNoise(terrain_world_pos * 0.021 + vec2(-12.0, 3.0));
	float scree = gradN2D(terrain_world_pos * 0.034 + vec2(8.0, -5.0));
	float runoff = 1.0 - ridgeNoise(terrain_world_pos * vec2(0.006, 0.019) + vec2(12.0, -14.0));
	float steep = smoothstep(0.26, 0.86, slope01);
	float base = mix(0.25, 0.43, strata);
	float crack_dark = 1.0 - cracks * 0.22;
	float scree_tint = 0.90 + scree * 0.10;
	return clamp(vec3(base * crack_dark * scree_tint + steep * 0.06 + runoff * 0.05, base * 0.98 * crack_dark * scree_tint + steep * 0.05 + runoff * 0.04, base * 0.95 * crack_dark * scree_tint + steep * 0.04 + runoff * 0.03), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneSnow(vec2 terrain_world_pos, float slope01) {
	float wind = gradN2D(terrain_world_pos * 0.006 + vec2(21.0, -14.0)) * 0.55 + gradN2D(terrain_world_pos * 0.015 + vec2(-7.0, 11.0)) * 0.45;
	float crust = ridgeNoise(terrain_world_pos * 0.027 + vec2(3.0, 4.0));
	float sheltered = 1.0 - smoothstep(0.18, 0.74, slope01);
	float base = mix(0.82, 0.96, wind);
	float crust_dark = 1.0 - crust * 0.10;
	return clamp(vec3(base * crust_dark - sheltered * 0.02, base * (0.99 - crust * 0.04), base * (1.03 + sheltered * 0.04)), vec3(0.0), vec3(1.0));
}

vec3 sampleSceneTerrainAlbedo(vec2 source_world_pos, vec2 terrain_world_pos, float elevation, float h01, float slope01) {
	vec4 weights = sampleSceneTerrainMaterialWeights(source_world_pos, terrain_world_pos, elevation, h01, slope01);
	vec3 grass = sampleAlpineSceneGrass(terrain_world_pos, elevation, slope01);
	vec3 ground = sampleAlpineSceneGround(terrain_world_pos, elevation);
	vec3 rock = sampleAlpineSceneRock(terrain_world_pos, slope01);
	vec3 snow = sampleAlpineSceneSnow(terrain_world_pos, slope01);
	vec3 albedo = grass * weights.x + ground * weights.y + rock * weights.z + snow * weights.w;
	vec3 detail_tint = sampleTerrainColorDetail(source_world_pos, elevation, h01);
	float breakup = gradN2D(terrain_world_pos * 0.010 + vec2(6.0, -5.0)) * 0.55 + ridgeNoise(terrain_world_pos * 0.022 + vec2(-3.0, 11.0)) * 0.45;
	albedo *= mix(vec3(0.90), detail_tint, 0.60);
	albedo *= mix(0.92, 1.08, breakup);
	return clamp(albedo, vec3(0.0), vec3(1.0));
}
]]

local function build_alpine_source()
	return ProceduralTerrainSource.New{
		Seed = 4242,
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		TerrainShaderGLSL = ALPINE_TERRAIN_SHADER_GLSL,
		SceneShaderGLSL = ALPINE_SCENE_SHADER_GLSL,
		MaterialLayers = {
			{
				max_elevation = 20,
				blend_elevation = 100,
				max_slope = 0.30,
				slope_blend = 0.10,
				checker_scale = 18,
				roughness = 0.98,
				ambient_occlusion = 0.94,
				color_a = {0.18, 0.24, 0.12},
				color_b = {0.27, 0.35, 0.16},
			},
			{
				max_elevation = 280,
				blend_elevation = 120,
				max_slope = 0.44,
				slope_blend = 0.12,
				checker_scale = 26,
				roughness = 0.92,
				ambient_occlusion = 0.96,
				color_a = {0.30, 0.27, 0.16},
				color_b = {0.40, 0.36, 0.22},
			},
			{
				max_elevation = 540,
				blend_elevation = 140,
				min_slope = 0.18,
				slope_blend = 0.12,
				checker_scale = 34,
				roughness = 0.82,
				ambient_occlusion = 0.88,
				color_a = {0.28, 0.29, 0.31},
				color_b = {0.42, 0.43, 0.45},
			},
			{
				blend_elevation = 140,
				min_elevation = 360,
				checker_scale = 42,
				roughness = 0.42,
				ambient_occlusion = 0.84,
				color_a = {0.86, 0.89, 0.93},
				color_b = {0.98, 0.99, 1.0},
			},
		},
	}
end

local function CreateAlpineTerrainRenderer()
	return ProceduralTerrainHybridRenderer.New{
		Name = "alpine_terrain_scene",
		Source = build_alpine_source(),
		ChunkWorldSize = 768,
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
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 768,
				height_texture_size = 768,
				normal_texture_size = 768,
				material_texture_size = 768,
				normal_strength = 1.55,
				height_layers = 22,
				tessellation_factor = 16,
			},
			{
				chunk_world_size = 2304,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 60,
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 384,
				height_texture_size = 512,
				normal_texture_size = 384,
				material_texture_size = 384,
				normal_strength = 1.20,
				height_layers = 14,
				tessellation_factor = 8,
			},
		},
		FarTerrain = {
			outer_half_size = 49152,
			snap_size = 6144,
			cast_shadows = false,
			mesh_resolution = Vec2() + 72,
			albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
			texture_size = 320,
			height_texture_size = 512,
			normal_texture_size = 320,
			material_texture_size = 320,
			normal_strength = 1.05,
			height_layers = 12,
			tessellation_factor = 6,
		},
	}:Start()
end

if _G.alpine_terrain_scene_renderer then
	_G.alpine_terrain_scene_renderer:Stop()
end

_G.alpine_terrain_scene_renderer = CreateAlpineTerrainRenderer()
print("Alpine hybrid terrain scene renderer created!")

if not _G.alpine_terrain_scene_renderer.SupportsTessellation then
	print(
		"Alpine terrain scene warning: tessellation is unsupported on this device, so tiles will stay flat."
	)
end
