local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainHybridRenderer = import("addons/game/lua/terrain/render.lua")
local ProceduralTerrainSource = import("addons/game/lua/terrain/source.lua")
local HEIGHT_SCALE = 3000
local VERTICAL_OFFSET = 600
local ALPINE_TERRAIN_SHADER_GLSL = [[
const mat2 ALPINE_TERRAIN_TWIST = mat2(1.3623, 1.7531, -1.7131, 1.4623);
const mat2 ALPINE_TEXTURE_ROT = mat2(0.80, -0.60, 0.60, 0.80);

float sampleAlpineDetailNoise(vec2 world_pos, float scale) {
	vec2 pos = ALPINE_TEXTURE_ROT * (world_pos * scale*0.001);
	float sum = 0.0;
	float amp = 0.58;
	float norm = 0.0;

	for (int i = 0; i < 4; i++) {
		sum += gradN2D(pos) * amp;
		norm += amp;
		pos = ALPINE_TEXTURE_ROT * pos * 2.03 + vec2(17.0, -11.0);
		amp *= 0.5;
	}

	return sum / max(norm, 0.0001);
}

vec2 sampleAlpineDetailPair(vec2 world_pos, float scale) {
	return vec2(
		sampleAlpineDetailNoise(world_pos + vec2(13.0, -7.0), scale),
		sampleAlpineDetailNoise(world_pos.yx + vec2(-5.0, 19.0), scale * 1.11)
	);
}

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
	float lowland = gradN2D(world_pos * 0.00020 + vec2(9.0, -7.0));
	float foothills = gradN2D(world_pos * 0.00065 + vec2(-4.0, 11.0));
	float distant_ranges = pow(abs(macro), 5.0) * 1.28;
	float ridges = pow(clamp(ridgeNoise(world_pos * 0.0015 + vec2(8.0, -5.0)), 0.0, 1.0), 2.2);
	float secondary_ridges = pow(clamp(ridgeNoise(world_pos * 0.0030 + vec2(-13.0, 11.0)), 0.0, 1.0), 3.3);
	float valleys = 1.0 - smoothstep(0.24, 0.84, n2D(world_pos * 0.00024 + vec2(6.0, -9.0)));
	float mass = 0.16 + lowland * 0.18 + foothills * 0.17 + sum * 0.40 + distant_ranges * 0.28 + ridges * 0.14 + secondary_ridges * 0.07;
	mass *= mix(0.42, 1.0, valleys);
	return mass;
}

float sampleTerrainHeight01(vec2 world_pos) {
	float mass = sampleAlpineMountainMass01(world_pos);
	float lowland = gradN2D(world_pos * 0.00024 + vec2(-15.0, 4.0));
	float foothills = gradN2D(world_pos * 0.00090 + vec2(7.0, -13.0));
	float sharp = pow(clamp(ridgeNoise(world_pos * 0.0048 + vec2(-19.0, 7.0)), 0.0, 1.0), 3.0);
	float shelf = gradN2D(world_pos * 0.0014 + vec2(9.0, -12.0));
	float erosion = gradN2D(world_pos * 0.0038 + vec2(-14.0, 5.0));
	float gully_a = 1.0 - ridgeNoise(world_pos * vec2(0.0016, 0.0048) + vec2(17.0, -9.0));
	float gully_b = 1.0 - ridgeNoise(world_pos.yx * vec2(0.0014, 0.0042) + vec2(-12.0, 8.0));
	float gullies = clamp(gully_a * 0.6 + gully_b * 0.4, 0.0, 1.0);
	float erosion_mask = smoothstep(0.22, 0.92, mass);
	float h = 0.08 + lowland * 0.12 + foothills * 0.11 + mass * 0.72;
	h += sharp * smoothstep(0.30, 0.84, mass) * 0.07;
	h -= pow(gullies, 1.8) * erosion_mask * 0.08;
	h += max(shelf - 0.80, 0.0) * 0.04;
	h += (erosion - 0.5) * 0.04;
	return h;
}

float sampleTerrainDisplacement01(vec2 world_pos, float h01) {
	float strata = sampleAlpineDetailNoise(world_pos + vec2(4.0, -6.0), 0.360);
	float cracks = ridgeNoise(world_pos * 0.820 + vec2(-11.0, 14.0));
	float talus = sampleAlpineDetailNoise(world_pos + vec2(13.0, -9.0), 1.500);
	float ledges = ridgeNoise(world_pos * vec2(0.340, 0.980) + vec2(-4.0, 9.0));
	float wash = 1.0 - ridgeNoise(world_pos * vec2(0.260, 0.780) + vec2(9.0, -13.0));
	float fine_strata = sampleAlpineDetailNoise(world_pos + vec2(-3.0, 8.0), 3.200);
	float chip = sampleAlpineDetailNoise(world_pos.yx + vec2(7.0, -12.0), 5.800);
	float fracture = ridgeNoise(world_pos * vec2(1.800, 4.800) + vec2(16.0, -18.0));
	float chatter = ridgeNoise(world_pos.yx * vec2(2.600, 6.200) + vec2(-21.0, 15.0));
	float snow = smoothstep(0.66, 0.94, h01);
	float cliffs = smoothstep(0.56, 0.90, h01);
	float relief = fine_strata * 0.30 + chip * 0.18 + fracture * 0.30 + chatter * 0.22;
	float detail = strata * 0.22 + cracks * 0.22 + talus * 0.08 + ledges * 0.20 + wash * 0.12 + relief * 0.16;
	detail = mix(detail, ledges * 0.44 + cracks * 0.24 + relief * 0.32, cliffs * 0.72);
	detail = mix(detail, 0.5, snow * 0.78);
	return clamp(0.5 + (detail - 0.5) * mix(0.42, 0.72, cliffs), 0.0, 1.0);
}

vec3 sampleTerrainColorDetail(vec2 world_pos, float elevation, float h01) {
	float weathering = sampleAlpineDetailNoise(world_pos + vec2(3.0, -4.0), 0.044) * 0.55 + sampleAlpineDetailNoise(world_pos + vec2(23.0, -17.0), 0.170) * 0.45;
	vec2 detail_pair = sampleAlpineDetailPair(world_pos, 0.110);
	float oxide = detail_pair.x;
	float lichen = detail_pair.y;
	float alpine_topness = smoothstep(0.58, 0.90, h01);
	float snow = smoothstep(0.76, 0.92, h01);
	float cold = smoothstep(0.58, 0.84, h01);
	vec3 tint = vec3(
		mix(0.70, 0.98, weathering) + oxide * 0.05,
		mix(0.72, 1.00, weathering) + lichen * 0.04,
		mix(0.74, 1.02, weathering)
	);
	tint = mix(tint, vec3(0.86, 0.90, 0.96), cold * 0.08 + alpine_topness * 0.03);
	tint = mix(tint, vec3(0.98, 1.00, 1.02), snow * 0.10);
	return tint;
}
]]
local ALPINE_SCENE_SHADER_GLSL = [[
float shapeAlpineSceneHeight01(float base_height, vec2 terrain_world_pos) {
	float valley = 1.0 - smoothstep(0.18, 0.82, n2D(terrain_world_pos * 0.00018 + vec2(5.0, -7.0)));
	float basin = 1.0 - smoothstep(0.26, 0.74, n2D(terrain_world_pos * 0.00052 + vec2(-3.0, 9.0)));
	float face_breakup = pow(clamp(ridgeNoise(terrain_world_pos * 0.0018 + vec2(12.0, -8.0)), 0.0, 1.0), 2.5);
	float shaped = base_height;
	shaped += face_breakup * smoothstep(0.28, 0.82, base_height) * 0.040;
	shaped -= valley * 0.05;
	shaped -= basin * 0.03;
	return shaped;
}

float sampleSceneTerrainHeight01(vec2 source_world_pos, vec2 terrain_world_pos) {
	if (false) {
		vec2 chunk_uv = (terrain_world_pos - vec2(terrain_bake.chunk_min_x, terrain_bake.chunk_min_z)) / max(terrain_bake.chunk_world_size, 0.0001);
		vec2 dome_pos = chunk_uv * 2.0 - 1.0;
		float dome = max(0.0, 1.0 - dot(dome_pos, dome_pos));
		return dome * 0.08;
	}

	float base_height = sampleTerrainHeight01(source_world_pos);
	return shapeAlpineSceneHeight01(base_height, terrain_world_pos);
}

float sampleAlpineSceneTopness01(float h01) {
	return smoothstep(0.14, 0.94, h01);
}

float sampleSceneTerrainSlope01(vec2 source_world_pos, vec2 terrain_world_pos, vec2 sample_step, float height_scale) {
	float h_left = sampleSceneTerrainHeight01(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * height_scale;
	float h_right = sampleSceneTerrainHeight01(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * height_scale;
	float h_down = sampleSceneTerrainHeight01(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * height_scale;
	float h_up = sampleSceneTerrainHeight01(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * height_scale;
	float dx = (h_right - h_left) / max(sample_step.x * 2.0, 0.0001);
	float dz = (h_up - h_down) / max(sample_step.y * 2.0, 0.0001);
	float slope = sqrt(dx * dx + dz * dz);
	float normal_y = 1.0 / sqrt(1.0 + slope * slope);
	return clamp(1.0 - normal_y, 0.0, 1.0);
}

float sampleSceneTerrainDisplacement01(vec2 source_world_pos, vec2 terrain_world_pos, float h01) {
	return sampleTerrainDisplacement01(source_world_pos, h01);
}

vec4 sampleSceneTerrainMaterialWeights(vec2 source_world_pos, vec2 terrain_world_pos, float elevation, float h01, float slope01) {
	float topness = sampleAlpineSceneTopness01(h01)*1.5;
	float flatness = 1.0 - smoothstep(0.24, 0.38, slope01);
	float gentle = 1.0 - smoothstep(0.36, 0.52, slope01);
	float steep = smoothstep(0.32, 0.50, slope01);
	float very_steep = smoothstep(0.48, 0.66, slope01);
	float meadow_macro = sampleAlpineDetailNoise(terrain_world_pos + vec2(41.0, -23.0), 0.00065);
	float meadow_shelves = sampleAlpineDetailNoise(terrain_world_pos + vec2(-17.0, 31.0), 0.0014);
	float meadow_bias = smoothstep(0.40, 0.70, meadow_macro * 0.65 + meadow_shelves * 0.35);
	float shore = 1.0 - smoothstep(0.03, 0.08, topness);
	float grass_band = 1.0 - smoothstep(0.18, 0.42, topness);
	float ground_band = smoothstep(0.10, 0.24, topness) * (1.0 - smoothstep(0.70, 0.90, topness));
	float snowline = smoothstep(0.78, 0.94, topness);
	float exposed_rock = max(steep, very_steep * (1.0 - snowline * 0.65));
	float sheltered_snow = snowline * gentle;
	float w1 = grass_band * flatness * mix(0.60, 1.20, meadow_bias) * (1.0 - shore * 0.45);
	float w2 = max(ground_band * gentle, shore * flatness * 0.55);
	float w3 = max(exposed_rock, smoothstep(0.48, 0.74, topness) * steep * 0.75);
	float w4 = sheltered_snow;
	vec4 weights = max(vec4(w1, w2, w3, w4), vec4(0.0));
	float total = dot(weights, vec4(1.0));

	if (total <= 0.0001) {
		return slope01 >= 0.50 && topness > 0.22 && topness < 0.78 ? vec4(0.0, 0.0, 1.0, 0.0) : topness <= 0.34 ? vec4(1.0, 0.0, 0.0, 0.0) : topness <= 0.78 ? vec4(0.0, 1.0, 0.0, 0.0) : vec4(0.0, 0.0, 0.0, 1.0);
	}

	return weights / total;
}

vec3 sampleAlpineSceneGrass(vec2 terrain_world_pos, float elevation, float slope01) {
	float macro = sampleAlpineDetailNoise(terrain_world_pos + vec2(7.0, -3.0), 0.011);
	float blades = sampleAlpineDetailNoise(terrain_world_pos + vec2(4.0, -2.0), 0.450);
	float weeds = sampleAlpineDetailNoise(terrain_world_pos + vec2(-8.0, 6.0), 0.950);
	float wetness = 1.0 - smoothstep(0.0, 120.0, elevation);
	float exposure = 1.0 - smoothstep(0.18, 0.54, slope01);
	vec3 base = vec3(mix(0.16, 0.25, macro), mix(0.18, 0.34, macro), mix(0.08, 0.14, macro));
	float blade_tint = 0.84 + blades * 0.18;
	return clamp(base * blade_tint + vec3(-0.03, 0.02, 0.01) * wetness + vec3(0.03, 0.03, 0.02) * exposure + vec3(0.05, 0.04, 0.00) * weeds, vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneGround(vec2 terrain_world_pos, float elevation, float slope01) {
	float soil = sampleAlpineDetailNoise(terrain_world_pos + vec2(13.0, -4.0), 0.038) * 0.65 + sampleAlpineDetailNoise(terrain_world_pos + vec2(-6.0, 9.0), 0.150) * 0.35;
	float moraine = ridgeNoise(terrain_world_pos * 0.280 + vec2(5.0, -8.0));
	float runoff = 1.0 - ridgeNoise(terrain_world_pos * vec2(0.080, 0.240) + vec2(-7.0, 11.0));
	float pebbles = sampleAlpineDetailNoise(terrain_world_pos + vec2(14.0, -3.0), 1.200);
	float thaw = smoothstep(60.0, 240.0, elevation);
	float exposed = smoothstep(0.20, 0.56, slope01);
	vec3 base = vec3(mix(0.24, 0.38, soil), mix(0.20, 0.30, soil), mix(0.11, 0.16, soil));
	float moraine_dark = 1.0 - moraine * 0.12;
	return clamp(vec3(base.r * moraine_dark + thaw * 0.02 + runoff * 0.03 + pebbles * 0.05 - exposed * 0.03, base.g * moraine_dark + thaw * 0.02 + runoff * 0.01 + pebbles * 0.03 - exposed * 0.02, base.b * moraine_dark + pebbles * 0.01 - exposed * 0.01), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneRock(vec2 terrain_world_pos, float slope01) {
	float strata = sampleAlpineDetailNoise(terrain_world_pos + vec2(9.0, -7.0), 0.160) * 0.6 + sampleAlpineDetailNoise(terrain_world_pos + vec2(-4.0, 6.0), 0.360) * 0.4;
	float cracks = ridgeNoise(terrain_world_pos * 0.400 + vec2(-12.0, 3.0));
	float scree = sampleAlpineDetailNoise(terrain_world_pos + vec2(8.0, -5.0), 0.680);
	float runoff = 1.0 - ridgeNoise(terrain_world_pos * vec2(0.120, 0.380) + vec2(12.0, -14.0));
	vec2 rock_detail = sampleAlpineDetailPair(terrain_world_pos + vec2(2.0, -3.0), 0.380);
	float oxide = rock_detail.x;
	float lichen = rock_detail.y;
	float steep = smoothstep(0.26, 0.86, slope01);
	float base = mix(0.20, 0.38, strata);
	float crack_dark = 1.0 - cracks * 0.22;
	float scree_tint = 0.90 + scree * 0.10;
	return clamp(vec3(base * crack_dark * scree_tint + steep * 0.05 + runoff * 0.02 + oxide * 0.08, base * 0.94 * crack_dark * scree_tint + steep * 0.04 + runoff * 0.03 + lichen * 0.05, base * 1.02 * crack_dark * scree_tint + steep * 0.03 + runoff * 0.04), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneSnow(vec2 terrain_world_pos, float slope01) {
	float wind = gradN2D(terrain_world_pos * 0.120 + vec2(21.0, -14.0)) * 0.55 + gradN2D(terrain_world_pos * 0.300 + vec2(-7.0, 11.0)) * 0.45;
	float crust = ridgeNoise(terrain_world_pos * 0.540 + vec2(3.0, 4.0));
	float sheltered = 1.0 - smoothstep(0.18, 0.74, slope01);
	float base = mix(0.74, 0.88, wind);
	float crust_dark = 1.0 - crust * 0.10;
	return clamp(vec3(base * crust_dark - sheltered * 0.02, base * (0.99 - crust * 0.04), base * (1.03 + sheltered * 0.04)), vec3(0.0), vec3(1.0));
}

vec3 sampleSceneTerrainAlbedo(vec2 source_world_pos, vec2 terrain_world_pos, float elevation, float h01, float slope01) {
	vec4 weights = sampleSceneTerrainMaterialWeights(source_world_pos, terrain_world_pos, elevation, h01, slope01);
	vec3 grass = sampleAlpineSceneGrass(terrain_world_pos, elevation, slope01);
	vec3 ground = sampleAlpineSceneGround(terrain_world_pos, elevation, slope01);
	vec3 rock = sampleAlpineSceneRock(terrain_world_pos, slope01);
	vec3 snow = sampleAlpineSceneSnow(terrain_world_pos, slope01);
	float topness = sampleAlpineSceneTopness01(h01);
	vec3 albedo = grass * weights.x + ground * weights.y + rock * weights.z + snow * weights.w;
	float rock_mask = smoothstep(0.30, 0.52, slope01) * (1.0 - smoothstep(0.76, 0.94, topness) * 0.65);
	float meadow_macro = sampleAlpineDetailNoise(terrain_world_pos + vec2(41.0, -23.0), 0.00065);
	float meadow_shelves = sampleAlpineDetailNoise(terrain_world_pos + vec2(-17.0, 31.0), 0.0014);
	float meadow_mask = smoothstep(0.40, 0.70, meadow_macro * 0.65 + meadow_shelves * 0.35);
	float grass_mask = (1.0 - smoothstep(0.24, 0.38, slope01)) * (1.0 - smoothstep(0.20, 0.40, topness)) * mix(0.55, 1.0, meadow_mask);
	float ground_mask = (1.0 - smoothstep(0.34, 0.50, slope01)) * smoothstep(0.08, 0.20, topness) * (1.0 - smoothstep(0.72, 0.90, topness)) * mix(0.70, 1.0, meadow_mask);
	albedo = mix(albedo, rock, rock_mask * 0.65);
	albedo = mix(albedo, ground, ground_mask * 0.28);
	albedo = mix(albedo, grass, grass_mask * 0.52);
	vec3 detail_tint = sampleTerrainColorDetail(source_world_pos, elevation, h01);
	float breakup = gradN2D(terrain_world_pos * 0.200 + vec2(6.0, -5.0)) * 0.45 + ridgeNoise(terrain_world_pos * 0.440 + vec2(-3.0, 11.0)) * 0.30 + gradN2D(terrain_world_pos * 1.080 + vec2(15.0, -8.0)) * 0.25;
	albedo *= mix(vec3(0.82), detail_tint, 0.78);
	albedo *= vec3(0.88 + breakup * 0.28, 0.90 + breakup * 0.22, 0.92 + breakup * 0.18);
	return clamp(albedo, vec3(0.0), vec3(1.0));
}
]]
local ALPINE_NORMAL_SHADER_GLSL = [[
float sampleSceneTerrainNormalHeight01(vec2 source_world_pos, vec2 terrain_world_pos) {
	float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
	float alpine_mask = smoothstep(0.24, 0.82, h01);
	float strata = sampleAlpineDetailNoise(source_world_pos + vec2(11.0, -7.0), 0.05);
	float talus = sampleAlpineDetailNoise(source_world_pos + vec2(-9.0, 14.0), 0.820);
	float scree = sampleAlpineDetailNoise(source_world_pos.yx + vec2(5.0, -3.0), 1.360);
	float cracks = ridgeNoise(source_world_pos * vec2(0.440, 1.420) + vec2(-13.0, 17.0));
	float ledges = ridgeNoise(source_world_pos * vec2(0.300, 1.060)*0.05 + vec2(8.0, -11.0));
	float fine_strata = sampleAlpineDetailNoise(source_world_pos + vec2(-4.0, 9.0), 0.01);
	float chip = sampleAlpineDetailNoise(source_world_pos.yx + vec2(7.0, -12.0), 0.1);
	float fracture = ridgeNoise(source_world_pos * vec2(0.960, 2.700)*0.5 + vec2(19.0, -16.0));
	float chatter = ridgeNoise(source_world_pos.yx * vec2(1.700, 4.000)*0.1 + vec2(-23.0, 21.0));
    {return h01+strata*0.001+talus*0.0001+scree*0.0001+cracks*0.0001+ledges*0.001+fine_strata*0.001+chip*0.001 + fracture*0.0001 + chatter*0.0001;}
	float cliff_mask = smoothstep(0.52, 0.88, h01);
	float micro = (strata - 0.5) * 0.0011;
	micro += (talus - 0.5) * 0.0009;
	micro += (scree - 0.5) * 0.0007;
	micro += (fine_strata - 0.5) * 0.0009;
	micro += (chip - 0.5) * 0.0007;
	micro += ((cracks * 0.36 + ledges * 0.24 + fracture * 0.24 + chatter * 0.16) - 0.5) * 0.0022;
	return clamp(0.5 + micro * mix(0.16, 0.90, max(alpine_mask, cliff_mask)), 0.0, 1.0);
}
]]

local function build_alpine_source()
	return ProceduralTerrainSource.New{
		Seed = 4242,
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		TerrainShaderGLSL = ALPINE_TERRAIN_SHADER_GLSL,
		SceneShaderGLSL = ALPINE_SCENE_SHADER_GLSL,
		NormalShaderGLSL = ALPINE_NORMAL_SHADER_GLSL,
		MaterialLayers = {
			{
				max_elevation = 20,
				blend_elevation = 100,
				max_slope = 0.30,
				slope_blend = 0.10,
				checker_scale = 1.0,
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
				checker_scale = 1.4,
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
				checker_scale = 1.8,
				roughness = 0.82,
				ambient_occlusion = 0.88,
				color_a = {0.28, 0.29, 0.31},
				color_b = {0.42, 0.43, 0.45},
			},
			{
				blend_elevation = 140,
				min_elevation = 360,
				checker_scale = 2.4,
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
				albedo_sampler = {min_filter = "linear", mag_filter = "linear"},
				texture_size = 768,
				height_texture_size = 768,
				normal_texture_size = 1024,
				material_texture_size = 768,
				normal_strength = 0.90,
				height_layers = 22,
				tessellation_factor = 16,
			},
			{
				chunk_world_size = 2304,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 60,
				albedo_sampler = {min_filter = "linear", mag_filter = "linear"},
				texture_size = 384,
				height_texture_size = 512,
				normal_texture_size = 640,
				material_texture_size = 384,
				normal_strength = 0.72,
				height_layers = 14,
				tessellation_factor = 8,
			},
		},
		FarTerrain = {
			outer_half_size = 49152,
			snap_size = 6144,
			cast_shadows = false,
			mesh_resolution = Vec2() + 72,
			albedo_sampler = {min_filter = "linear", mag_filter = "linear"},
			texture_size = 320,
			height_texture_size = 512,
			normal_texture_size = 512,
			material_texture_size = 320,
			normal_strength = 0.62,
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
