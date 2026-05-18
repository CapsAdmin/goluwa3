local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainHybridRenderer = import("addons/game/lua/terrain/procedural_terrain_hybrid_renderer.lua")
local ProceduralTerrainSource = import("addons/game/lua/terrain/procedural_terrain_source.lua")
local HEIGHT_SCALE = 1400
local VERTICAL_OFFSET = 0

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

local function mix(a, b, t)
	return a + (b - a) * t
end

local function fract(value)
	return value - math.floor(value)
end

local function hash2(x, z)
	return fract(math.sin(x * 127.1 + z * 311.7 + 74.7) * 43758.5453123)
end

local function value_noise(x, z)
	local ix = math.floor(x)
	local iz = math.floor(z)
	local fx = x - ix
	local fz = z - iz
	local ux = fx * fx * (3 - 2 * fx)
	local uz = fz * fz * (3 - 2 * fz)
	local a = hash2(ix, iz)
	local b = hash2(ix + 1, iz)
	local c = hash2(ix, iz + 1)
	local d = hash2(ix + 1, iz + 1)
	return mix(mix(a, b, ux), mix(c, d, ux), uz)
end

local function fbm(x, z)
	local value = 0
	local amplitude = 0.5
	local frequency = 1

	for _ = 1, 4 do
		value = value + value_noise(x * frequency, z * frequency) * amplitude
		frequency = frequency * 2.03
		amplitude = amplitude * 0.5
	end

	return value
end

local function ridge(x, z)
	local n = fbm(x, z)
	return 1 - math.abs(n * 2 - 1)
end

local function shape_alpine_height(base_height, world_x, world_z)
	local broad_valley = 0.5 + 0.5 * math.sin(world_x * 0.00022 + 1.3) * math.cos(world_z * 0.00018 - 0.7)
	local valley_mask = 1 - smoothstep(0.32, 0.88, broad_valley)
	local ridge_height = smoothstep(0.18, 0.94, base_height)
	local peak_rounding = smoothstep(0.58, 0.92, ridge_height)
	local rounded_ridge = 1 - (1 - ridge_height) ^ 2.6
	local ridge_profile = mix(ridge_height, rounded_ridge, peak_rounding * 0.65)
	local shaped = 0.46 + ridge_profile * 0.50
	shaped = shaped - valley_mask * 0.05
	return clamp(shaped, 0.455, 0.98)
end

local ALPINE_ALBEDO_SHADER_HEADER = [[
float shapeAlpineSceneHeight01(float base_height, vec2 terrain_world_pos) {
	float broad_valley = 0.5 + 0.5 * sin(terrain_world_pos.x * 0.00022 + 1.3) * cos(terrain_world_pos.y * 0.00018 - 0.7);
	float valley_mask = 1.0 - smoothstep(0.32, 0.88, broad_valley);
	float ridge_height = smoothstep(0.18, 0.94, base_height);
	float peak_rounding = smoothstep(0.58, 0.92, ridge_height);
	float rounded_ridge = 1.0 - pow(1.0 - ridge_height, 2.6);
	float ridge_profile = mix(ridge_height, rounded_ridge, peak_rounding * 0.65);
	float shaped = 0.46 + ridge_profile * 0.50;
	shaped -= valley_mask * 0.05;
	return clamp(shaped, 0.455, 0.98);
}

float sampleAlpineSceneHeight01(vec2 source_world_pos, vec2 terrain_world_pos) {
	float base_height = sampleTerrainHeight01(source_world_pos);
	return shapeAlpineSceneHeight01(base_height, terrain_world_pos);
}

float sampleAlpineSceneSlope01(vec2 source_world_pos, vec2 terrain_world_pos) {
	float sample_step = 8.0;
	float h_left = sampleAlpineSceneHeight01(source_world_pos - vec2(sample_step, 0.0), terrain_world_pos - vec2(sample_step, 0.0)) * 1400.0;
	float h_right = sampleAlpineSceneHeight01(source_world_pos + vec2(sample_step, 0.0), terrain_world_pos + vec2(sample_step, 0.0)) * 1400.0;
	float h_down = sampleAlpineSceneHeight01(source_world_pos - vec2(0.0, sample_step), terrain_world_pos - vec2(0.0, sample_step)) * 1400.0;
	float h_up = sampleAlpineSceneHeight01(source_world_pos + vec2(0.0, sample_step), terrain_world_pos + vec2(0.0, sample_step)) * 1400.0;
	float dx = (h_right - h_left) / max(sample_step * 2.0, 0.0001);
	float dz = (h_up - h_down) / max(sample_step * 2.0, 0.0001);
	return smoothstep(0.04, 1.2, sqrt(dx * dx + dz * dz));
}

vec4 sampleAlpineSceneWeights(float elevation, float slope01) {
	float w1 = (1.0 - smoothstep(40.0 - 80.0, 40.0 + 80.0, elevation)) * (1.0 - smoothstep(0.34 - 0.10, 0.34 + 0.10, slope01));
	float w2 = smoothstep(40.0 - 100.0, 40.0 + 100.0, elevation) * (1.0 - smoothstep(220.0 - 100.0, 220.0 + 100.0, elevation)) * (1.0 - smoothstep(0.52 - 0.12, 0.52 + 0.12, slope01));
	float w3 = smoothstep(220.0 - 120.0, 220.0 + 120.0, elevation) * (1.0 - smoothstep(460.0 - 120.0, 460.0 + 120.0, elevation)) * smoothstep(0.20 - 0.12, 0.20 + 0.12, slope01);
	float w4 = smoothstep(420.0 - 120.0, 420.0 + 120.0, elevation);
	vec4 weights = max(vec4(w1, w2, w3, w4), vec4(0.0));
	float total = dot(weights, vec4(1.0));

	if (total <= 0.0001) {
		return elevation <= 40.0 ? vec4(1.0, 0.0, 0.0, 0.0) : elevation <= 220.0 ? vec4(0.0, 1.0, 0.0, 0.0) : elevation <= 460.0 ? vec4(0.0, 0.0, 1.0, 0.0) : vec4(0.0, 0.0, 0.0, 1.0);
	}

	return weights / total;
}

vec3 sampleAlpineSceneGrass(vec2 terrain_world_pos, float elevation, float slope01) {
	float macro = gradN2D(terrain_world_pos * 0.0012);
	float blades = gradN2D(terrain_world_pos * 0.024 + vec2(4.0, -2.0));
	float clumps = ridgeNoise(terrain_world_pos * 0.006 + vec2(7.0, 3.0));
	float wetness = 1.0 - smoothstep(10.0, 120.0, elevation);
	vec3 base = vec3(mix(0.15, 0.26, macro), mix(0.24, 0.42, macro), mix(0.11, 0.18, macro));
	float blade_tint = 0.88 + blades * 0.22;
	float clump_darkening = 1.0 - clumps * 0.12;
	float wet_tint = wetness * 0.08;
	return clamp(vec3(base.r * blade_tint * clump_darkening - wet_tint * 0.35, base.g * blade_tint * (1.0 - wet_tint * 0.15), base.b * blade_tint * clump_darkening + wet_tint * 0.10), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneGround(vec2 terrain_world_pos, float elevation) {
	float soil = gradN2D(terrain_world_pos * 0.0022 + vec2(13.0, -4.0)) * 0.65 + gradN2D(terrain_world_pos * 0.0075 + vec2(-6.0, 9.0)) * 0.35;
	float pebbles = ridgeNoise(terrain_world_pos * 0.018 + vec2(5.0, -8.0));
	float thaw = smoothstep(80.0, 260.0, elevation);
	vec3 base = vec3(mix(0.24, 0.38, soil), mix(0.28, 0.46, soil), mix(0.17, 0.25, soil));
	float pebble_tint = 1.0 - pebbles * 0.10;
	return clamp(vec3(base.r * pebble_tint + thaw * 0.03, base.g * pebble_tint + thaw * 0.02, base.b * pebble_tint), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneRock(vec2 terrain_world_pos, float slope01) {
	float strata = gradN2D(terrain_world_pos * vec2(0.0045, 0.012) + vec2(9.0, -7.0)) * 0.6 + gradN2D(terrain_world_pos * vec2(0.010, 0.020) + vec2(-4.0, 6.0)) * 0.4;
	float cracks = ridgeNoise(terrain_world_pos * 0.020 + vec2(-12.0, 3.0));
	float scree = gradN2D(terrain_world_pos * 0.035 + vec2(8.0, -5.0));
	float steep = smoothstep(0.26, 0.86, slope01);
	float base = mix(0.34, 0.52, strata);
	float crack_dark = 1.0 - cracks * 0.18;
	float scree_tint = 0.92 + scree * 0.14;
	return clamp(vec3((base * 0.96) * crack_dark * scree_tint + steep * 0.04, (base * 0.95) * crack_dark * scree_tint + steep * 0.03, (base * 0.93) * crack_dark * scree_tint + steep * 0.02), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneSnow(vec2 terrain_world_pos, float slope01) {
	float wind = gradN2D(terrain_world_pos * 0.006 + vec2(21.0, -14.0)) * 0.55 + gradN2D(terrain_world_pos * 0.014 + vec2(-7.0, 11.0)) * 0.45;
	float crust = ridgeNoise(terrain_world_pos * 0.028 + vec2(3.0, 4.0));
	float sheltered = 1.0 - smoothstep(0.18, 0.70, slope01);
	float base = mix(0.84, 0.97, wind);
	float crust_dark = 1.0 - crust * 0.08;
	return clamp(vec3(base * crust_dark - sheltered * 0.01, base * (0.995 - crust * 0.04), base * (1.02 + sheltered * 0.03)), vec3(0.0), vec3(1.0));
}

vec3 sampleAlpineSceneAlbedo(vec2 source_world_pos, vec2 terrain_world_pos) {
	float h01 = sampleAlpineSceneHeight01(source_world_pos, terrain_world_pos);
	float elevation = h01 * 1400.0 - 700.0;
	float slope01 = sampleAlpineSceneSlope01(source_world_pos, terrain_world_pos);
	vec4 weights = sampleAlpineSceneWeights(elevation, slope01);
	vec3 grass = sampleAlpineSceneGrass(terrain_world_pos, elevation, slope01);
	vec3 ground = sampleAlpineSceneGround(terrain_world_pos, elevation);
	vec3 rock = sampleAlpineSceneRock(terrain_world_pos, slope01);
	vec3 snow = sampleAlpineSceneSnow(terrain_world_pos, slope01);
	return grass * weights.x + ground * weights.y + rock * weights.z + snow * weights.w;
}
]]

local function build_alpine_source()
	local source = ProceduralTerrainSource.New{
		Seed = 4242,
		TerrainProfile = "alpine",
		HeightScale = HEIGHT_SCALE,
		VerticalOffset = VERTICAL_OFFSET,
		MaterialLayers = {
			{
				max_elevation = 40,
				blend_elevation = 80,
				max_slope = 0.34,
				slope_blend = 0.10,
				roughness = 0.98,
				ambient_occlusion = 0.94,
				color = {0.18, 0.34, 0.20},
			},
			{
				max_elevation = 220,
				blend_elevation = 100,
				max_slope = 0.52,
				slope_blend = 0.12,
				roughness = 0.92,
				ambient_occlusion = 0.96,
				color = {0.28, 0.42, 0.24},
			},
			{
				max_elevation = 460,
				blend_elevation = 120,
				min_slope = 0.20,
				slope_blend = 0.12,
				roughness = 0.78,
				ambient_occlusion = 0.88,
				color = {0.42, 0.42, 0.40},
			},
			{
				blend_elevation = 120,
				min_elevation = 420,
				roughness = 0.42,
				ambient_occlusion = 0.84,
				color = {0.94, 0.95, 0.98},
			},
		},
		MaterialBands = {
			{max_elevation = 20, color = {0.18, 0.34, 0.20}},
			{max_elevation = 220, color = {0.28, 0.42, 0.24}},
			{max_elevation = 460, color = {0.42, 0.42, 0.40}},
			{color = {0.94, 0.95, 0.98}},
		},
	}
	local base_sample_height01 = source.SampleHeight01
	local base_compute_material_weights = source.ComputeMaterialWeights
	local base_get_shader_header = source.GetShaderHeader
	local base_get_material_shader_header = source.GetMaterialShaderHeader

	function source:SampleHeight01(world_x, world_z)
		local base_height = base_sample_height01(self, world_x, world_z)
		return shape_alpine_height(base_height, world_x, world_z)
	end

	local function sample_grass_albedo(world_x, world_z, elevation, slope01)
		local macro = fbm(world_x * 0.0012, world_z * 0.0012)
		local blades = fbm(world_x * 0.024, world_z * 0.024)
		local clumps = ridge(world_x * 0.006, world_z * 0.006)
		local wetness = 1 - smoothstep(10, 120, elevation)
		local r = mix(0.15, 0.26, macro)
		local g = mix(0.24, 0.42, macro)
		local b = mix(0.11, 0.18, macro)
		local blade_tint = 0.88 + blades * 0.22
		local clump_darkening = 1 - clumps * 0.12
		local wet_tint = wetness * 0.08
		return clamp(r * blade_tint * clump_darkening - wet_tint * 0.35, 0, 1),
		clamp(g * blade_tint * (1 - wet_tint * 0.15), 0, 1),
		clamp(b * blade_tint * clump_darkening + wet_tint * 0.10, 0, 1)
	end

	local function sample_alpine_ground_albedo(world_x, world_z, elevation)
		local soil = fbm(world_x * 0.0022 + 13.0, world_z * 0.0022 - 4.0)
		local pebbles = ridge(world_x * 0.018, world_z * 0.018)
		local thaw = smoothstep(80, 260, elevation)
		local r = mix(0.24, 0.38, soil)
		local g = mix(0.28, 0.46, soil)
		local b = mix(0.17, 0.25, soil)
		local pebble_tint = 1 - pebbles * 0.10
		return clamp(r * pebble_tint + thaw * 0.03, 0, 1),
		clamp(g * pebble_tint + thaw * 0.02, 0, 1),
		clamp(b * pebble_tint, 0, 1)
	end

	local function sample_rock_albedo(world_x, world_z, slope01)
		local strata = fbm(world_x * 0.0045 + 9.0, world_z * 0.012 - 7.0)
		local cracks = ridge(world_x * 0.020 - 12.0, world_z * 0.020 + 3.0)
		local scree = fbm(world_x * 0.035, world_z * 0.035)
		local steep = smoothstep(0.26, 0.86, slope01)
		local base = mix(0.34, 0.52, strata)
		local crack_dark = 1 - cracks * 0.18
		local scree_tint = 0.92 + scree * 0.14
		return clamp((base * 0.96) * crack_dark * scree_tint + steep * 0.04, 0, 1),
		clamp((base * 0.95) * crack_dark * scree_tint + steep * 0.03, 0, 1),
		clamp((base * 0.93) * crack_dark * scree_tint + steep * 0.02, 0, 1)
	end

	local function sample_snow_albedo(world_x, world_z, slope01)
		local wind = fbm(world_x * 0.006 + 21.0, world_z * 0.006 - 14.0)
		local crust = ridge(world_x * 0.028, world_z * 0.028)
		local sheltered = 1 - smoothstep(0.18, 0.70, slope01)
		local base = mix(0.84, 0.97, wind)
		local crust_dark = 1 - crust * 0.08
		return clamp(base * crust_dark - sheltered * 0.01, 0, 1),
		clamp(base * (0.995 - crust * 0.04), 0, 1),
		clamp(base * (1.02 + sheltered * 0.03), 0, 1)
	end

	function source:SampleMaterialColor(world_x, world_z, height01, elevation, slope01)
		height01 = height01 or self:SampleHeight01(world_x, world_z)
		elevation = elevation or
			self.VerticalOffset + height01 * self.HeightScale - self.HeightScale * 0.5
		slope01 = slope01 or self:SampleSlope01(world_x, world_z)
		local w1, w2, w3, w4 = base_compute_material_weights(self, height01, elevation, slope01)
		local g1r, g1g, g1b = sample_grass_albedo(world_x, world_z, elevation, slope01)
		local g2r, g2g, g2b = sample_alpine_ground_albedo(world_x, world_z, elevation)
		local g3r, g3g, g3b = sample_rock_albedo(world_x, world_z, slope01)
		local g4r, g4g, g4b = sample_snow_albedo(world_x, world_z, slope01)
		local r = g1r * w1 + g2r * w2 + g3r * w3 + g4r * w4
		local g = g1g * w1 + g2g * w2 + g3g * w3 + g4g * w4
		local b = g1b * w1 + g2b * w2 + g3b * w3 + g4b * w4
		return clamp(r, 0, 1), clamp(g, 0, 1), clamp(b, 0, 1), elevation
	end

	function source:SampleColorDetail(world_x, world_z, elevation, height01)
		return 1, 1, 1
	end

	function source:GetShaderHeader()
		return base_get_shader_header(self) .. "\n" .. ALPINE_ALBEDO_SHADER_HEADER
	end

	function source:GetMaterialShaderHeader()
		return base_get_material_shader_header(self) .. "\n" .. ALPINE_ALBEDO_SHADER_HEADER
	end

	function source:BuildHeightShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
		texture_width = math.max(1, texture_width or 1)
		texture_height = math.max(1, texture_height or texture_width)
		return string.format(
			[[
			vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
			vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
			vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
			vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
			float h01 = sampleAlpineSceneHeight01(source_world_pos, terrain_world_pos);
			return vec4(h01, h01, h01, 1.0);
		]],
			texture_width,
			texture_height,
			texture_width - 1,
			texture_height - 1,
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			self.SeedOffset.x,
			self.SeedOffset.y
		)
	end

	function source:BuildNormalShader(
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		texture_width,
		texture_height,
		normal_strength
	)
		texture_width = math.max(1, texture_width or 128)
		texture_height = math.max(1, texture_height or texture_width)
		normal_strength = normal_strength or 1
		return string.format(
			[[
			vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
			vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
			vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
			vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
			vec2 sample_step = vec2(%.6f, %.6f);
			float h_left = sampleAlpineSceneHeight01(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * %.6f;
			float h_right = sampleAlpineSceneHeight01(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * %.6f;
			float h_down = sampleAlpineSceneHeight01(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * %.6f;
			float h_up = sampleAlpineSceneHeight01(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * %.6f;
			vec3 tangent_normal = normalize(vec3((h_left - h_right) * %.6f, (h_down - h_up) * %.6f, sample_step.x + sample_step.y));
			return vec4(tangent_normal * 0.5 + 0.5, 1.0);
		]],
			texture_width,
			texture_height,
			texture_width - 1,
			texture_height - 1,
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			self.SeedOffset.x,
			self.SeedOffset.y,
			chunk_world_size / math.max(texture_width - 1, 1),
			chunk_world_size / math.max(texture_height - 1, 1),
			self.HeightScale,
			self.HeightScale,
			self.HeightScale,
			self.HeightScale,
			normal_strength,
			normal_strength
		)
	end

	function source:BuildMaterialShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
		texture_width = math.max(1, texture_width or 128)
		texture_height = math.max(1, texture_height or texture_width)
		return string.format(
			[[
			vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
			vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
			vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
			vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
			float h01 = sampleAlpineSceneHeight01(source_world_pos, terrain_world_pos);
			float elevation = %.6f + h01 * %.6f - %.6f;
			float slope01 = sampleAlpineSceneSlope01(source_world_pos, terrain_world_pos);
			return sampleAlpineSceneWeights(elevation, slope01);
		]],
			texture_width,
			texture_height,
			texture_width - 1,
			texture_height - 1,
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			self.SeedOffset.x,
			self.SeedOffset.y,
			self.VerticalOffset,
			self.HeightScale,
			self.HeightScale * 0.5
		)
	end

	function source:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
		texture_width = math.max(1, texture_width or 1)
		texture_height = math.max(1, texture_height or texture_width)
		return string.format(
			[[
			vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
			vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
			vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
			vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
			vec3 col = sampleAlpineSceneAlbedo(source_world_pos, terrain_world_pos);
			return vec4(col, 1.0);
		]],
			texture_width,
			texture_height,
			texture_width - 1,
			texture_height - 1,
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			self.SeedOffset.x,
			self.SeedOffset.y
		)
	end

	return source
end

local function CreateAlpineTerrainRenderer()
	return ProceduralTerrainHybridRenderer.New{
		Name = "alpine_terrain_scene",
		Seed = 4242,
		Source = build_alpine_source(),
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
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 512,
				height_texture_size = 512,
				normal_texture_size = 512,
				material_texture_size = 512,
				normal_strength = 1.3,
				height_layers = 22,
				tessellation_factor = 16,
			},
			{
				chunk_world_size = 2304,
				radius = 2,
				cast_shadows = false,
				mesh_resolution = Vec2() + 60,
				albedo_sampler = {min_filter = "nearest", mag_filter = "nearest"},
				texture_size = 224,
				height_texture_size = 320,
				normal_texture_size = 256,
				material_texture_size = 224,
				normal_strength = 1.05,
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
			texture_size = 192,
			height_texture_size = 384,
			normal_texture_size = 192,
			material_texture_size = 192,
			normal_strength = 0.95,
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
