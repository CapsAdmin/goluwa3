local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
local ProceduralTerrainSource = {}
ProceduralTerrainSource.__index = ProceduralTerrainSource
local TERRAIN_BAKE_PUSH_CONSTANT_SIZE = 48
local TERRAIN_BAKE_PUSH_CONSTANT_DECLARATIONS = [[
layout(push_constant, scalar) uniform TerrainBakeConstants {
	float chunk_min_x;
	float chunk_min_z;
	float chunk_world_size;
	float texture_width;
	float texture_height;
	float sample_step_x;
	float sample_step_y;
	float normal_strength;
	float vertical_offset;
	float height_scale;
	float seed_offset_x;
	float seed_offset_y;
} terrain_bake;
]]
local COMMON_SHADER_HEADER = [[
float n2D(vec2 p) {
	vec2 i = floor(p);
	p -= i;
	p *= p * (3.0 - p * 2.0);
	return dot(
		mat2(fract(sin(mod(vec4(0.0, 1.0, 113.0, 114.0) + dot(i, vec2(1.0, 113.0)), 6.2831853)) * 43758.5453)) *
			vec2(1.0 - p.y, p.y),
		vec2(1.0 - p.x, p.x)
	);
}

vec2 hash22(vec2 p) {
	float n = sin(dot(p, vec2(113.0, 1.0)));
	return fract(vec2(2097152.0, 262144.0) * n) * 2.0 - 1.0;
}

float gradN2D(in vec2 f) {
	const vec2 e = vec2(0.0, 1.0);
	vec2 p = floor(f);
	f -= p;
	vec2 w = f * f * (3.0 - 2.0 * f);
	float c = mix(
		mix(dot(hash22(p + e.xx), f - e.xx), dot(hash22(p + e.yx), f - e.yx), w.x),
		mix(dot(hash22(p + e.xy), f - e.xy), dot(hash22(p + e.yy), f - e.yy), w.x),
		w.y
	);
	return c * 0.5 + 0.5;
}

float ridgeNoise(vec2 p) {
	return 1.0 - abs(gradN2D(p) * 2.0 - 1.0);
}
]]

local function get_seed_offsets(seed)
	seed = tonumber(seed) or 1337
	return Vec2(math.sin(seed * 12.9898) * 16384.0, math.cos(seed * 78.2330) * 16384.0)
end

function ProceduralTerrainSource.New(config)
	config = config or {}
	local self = setmetatable({}, ProceduralTerrainSource)
	self.Seed = config.Seed or 1337
	self.SeedOffset = config.SeedOffset or get_seed_offsets(self.Seed)
	self.HeightScale = config.HeightScale or 512
	self.VerticalOffset = config.VerticalOffset or 0
	self.MaterialLayers = config.MaterialLayers
	self.TerrainShaderGLSL = config.TerrainShaderGLSL
	self.SceneShaderGLSL = config.SceneShaderGLSL
	self.NormalShaderGLSL = config.NormalShaderGLSL
	self.ShaderHeader = table.concat(
		{
			COMMON_SHADER_HEADER,
			self.TerrainShaderGLSL,
			self.SceneShaderGLSL,
			self.NormalShaderGLSL,
		},
		"\n"
	)
	return self
end

function ProceduralTerrainSource:GetShaderHeader()
	return self.ShaderHeader
end

function ProceduralTerrainSource:GetMaterialShaderHeader()
	return self.ShaderHeader
end

function ProceduralTerrainSource:BuildBakeShaderExtraConfig(
	chunk_min_x,
	chunk_min_z,
	chunk_world_size,
	texture_width,
	texture_height,
	normal_strength
)
	texture_width = math.max(1, texture_width or 1)
	texture_height = math.max(1, texture_height or texture_width)
	normal_strength = normal_strength or 1
	return {
		custom_declarations = TERRAIN_BAKE_PUSH_CONSTANT_DECLARATIONS,
		fragment_push_constants = {
			size = TERRAIN_BAKE_PUSH_CONSTANT_SIZE,
			data = ffi.new(
				"float[12]",
				chunk_min_x,
				chunk_min_z,
				chunk_world_size,
				texture_width,
				texture_height,
				chunk_world_size / math.max(texture_width - 1, 1),
				chunk_world_size / math.max(texture_height - 1, 1),
				normal_strength,
				self.VerticalOffset,
				self.HeightScale,
				self.SeedOffset.x,
				self.SeedOffset.y
			),
		},
	}
end

function ProceduralTerrainSource:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	if texture_width ~= nil or texture_height ~= nil then
		return [[
		vec2 pixel = gl_FragCoord.xy - vec2(0.5);
		vec2 uv01 = vec2(
			pixel.x / max(terrain_bake.texture_width - 1.0, 1.0),
			pixel.y / max(terrain_bake.texture_height - 1.0, 1.0)
		);
		vec2 terrain_world_pos = vec2(terrain_bake.chunk_min_x, terrain_bake.chunk_min_z) + uv01 * terrain_bake.chunk_world_size;
		vec2 source_world_pos = terrain_world_pos + vec2(terrain_bake.seed_offset_x, terrain_bake.seed_offset_y);
		vec2 sample_step = vec2(terrain_bake.sample_step_x, terrain_bake.sample_step_y);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		float elevation = terrain_bake.vertical_offset + h01 * terrain_bake.height_scale - terrain_bake.height_scale * 0.5;
		float slope01 = sampleSceneTerrainSlope01(source_world_pos, terrain_world_pos, sample_step, terrain_bake.height_scale);
		vec3 col = sampleSceneTerrainAlbedo(source_world_pos, terrain_world_pos, elevation, h01, slope01);
		return vec4(col, 1.0);
		]],
		self:BuildBakeShaderExtraConfig(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	end

	texture_width = math.max(1, texture_width or 1)
	texture_height = math.max(1, texture_height or texture_width)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
		vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
		vec2 sample_step = vec2(%.6f, %.6f);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		float elevation = %.6f + h01 * %.6f - %.6f;
		float slope01 = sampleSceneTerrainSlope01(source_world_pos, terrain_world_pos, sample_step, %.6f);
		vec3 col = sampleSceneTerrainAlbedo(source_world_pos, terrain_world_pos, elevation, h01, slope01);
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
		self.SeedOffset.y,
		chunk_world_size / math.max(texture_width - 1, 1),
		chunk_world_size / math.max(texture_height - 1, 1),
		self.VerticalOffset,
		self.HeightScale,
		self.HeightScale * 0.5,
		self.HeightScale
	)
end

function ProceduralTerrainSource:BuildHeightShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	if texture_width ~= nil or texture_height ~= nil then
		return [[
		vec2 pixel = gl_FragCoord.xy - vec2(0.5);
		vec2 uv01 = vec2(
			pixel.x / max(terrain_bake.texture_width - 1.0, 1.0),
			pixel.y / max(terrain_bake.texture_height - 1.0, 1.0)
		);
		vec2 terrain_world_pos = vec2(terrain_bake.chunk_min_x, terrain_bake.chunk_min_z) + uv01 * terrain_bake.chunk_world_size;
		vec2 source_world_pos = terrain_world_pos + vec2(terrain_bake.seed_offset_x, terrain_bake.seed_offset_y);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		return vec4(h01, h01, h01, 1.0);
		]],
		self:BuildBakeShaderExtraConfig(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	end

	texture_width = math.max(1, texture_width or 1)
	texture_height = math.max(1, texture_height or texture_width)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
		vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
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

function ProceduralTerrainSource:BuildNormalShader(
	chunk_min_x,
	chunk_min_z,
	chunk_world_size,
	texture_width,
	texture_height,
	normal_strength
)
	local height_function_name = self.NormalShaderGLSL and
		self.NormalShaderGLSL ~= "" and
		"sampleSceneTerrainNormalHeight01" or
		"sampleSceneTerrainHeight01"

	if texture_width ~= nil or texture_height ~= nil then
		return string.format(
			[[ 
		vec2 pixel = gl_FragCoord.xy - vec2(0.5);
		vec2 uv01 = vec2(
			pixel.x / max(terrain_bake.texture_width - 1.0, 1.0),
			pixel.y / max(terrain_bake.texture_height - 1.0, 1.0)
		);
		vec2 terrain_world_pos = vec2(terrain_bake.chunk_min_x, terrain_bake.chunk_min_z) + uv01 * terrain_bake.chunk_world_size;
		vec2 source_world_pos = terrain_world_pos + vec2(terrain_bake.seed_offset_x, terrain_bake.seed_offset_y);
		vec2 sample_step = vec2(terrain_bake.sample_step_x, terrain_bake.sample_step_y);
		float h_left = %s(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * terrain_bake.height_scale;
		float h_right = %s(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * terrain_bake.height_scale;
		float h_down = %s(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * terrain_bake.height_scale;
		float h_up = %s(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * terrain_bake.height_scale;
		vec3 tangent_normal = normalize(vec3((h_left - h_right) * terrain_bake.normal_strength, (h_down - h_up) * terrain_bake.normal_strength, sample_step.x + sample_step.y));
		return vec4(tangent_normal * 0.5 + 0.5, 1.0);
		]],
			height_function_name,
			height_function_name,
			height_function_name,
			height_function_name
		),
		self:BuildBakeShaderExtraConfig(
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			texture_width,
			texture_height,
			normal_strength
		)
	end

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
		float h_left = %s(source_world_pos - vec2(sample_step.x, 0.0), terrain_world_pos - vec2(sample_step.x, 0.0)) * %.6f;
		float h_right = %s(source_world_pos + vec2(sample_step.x, 0.0), terrain_world_pos + vec2(sample_step.x, 0.0)) * %.6f;
		float h_down = %s(source_world_pos - vec2(0.0, sample_step.y), terrain_world_pos - vec2(0.0, sample_step.y)) * %.6f;
		float h_up = %s(source_world_pos + vec2(0.0, sample_step.y), terrain_world_pos + vec2(0.0, sample_step.y)) * %.6f;
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
		height_function_name,
		self.HeightScale,
		height_function_name,
		self.HeightScale,
		height_function_name,
		self.HeightScale,
		height_function_name,
		self.HeightScale,
		normal_strength,
		normal_strength
	)
end

function ProceduralTerrainSource:BuildMaterialShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	if texture_width ~= nil or texture_height ~= nil then
		return [[
		vec2 pixel = gl_FragCoord.xy - vec2(0.5);
		vec2 uv01 = vec2(
			pixel.x / max(terrain_bake.texture_width - 1.0, 1.0),
			pixel.y / max(terrain_bake.texture_height - 1.0, 1.0)
		);
		vec2 terrain_world_pos = vec2(terrain_bake.chunk_min_x, terrain_bake.chunk_min_z) + uv01 * terrain_bake.chunk_world_size;
		vec2 source_world_pos = terrain_world_pos + vec2(terrain_bake.seed_offset_x, terrain_bake.seed_offset_y);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		float elevation = terrain_bake.vertical_offset + h01 * terrain_bake.height_scale - terrain_bake.height_scale * 0.5;
		vec2 sample_step = vec2(terrain_bake.sample_step_x, terrain_bake.sample_step_y);
		float slope01 = sampleSceneTerrainSlope01(source_world_pos, terrain_world_pos, sample_step, terrain_bake.height_scale);
		return sampleSceneTerrainMaterialWeights(source_world_pos, terrain_world_pos, elevation, h01, slope01);
		]],
		self:BuildBakeShaderExtraConfig(chunk_min_x, chunk_min_z, chunk_world_size, texture_width, texture_height)
	end

	texture_width = math.max(1, texture_width or 128)
	texture_height = math.max(1, texture_height or texture_width)
	local sample_step_x = chunk_world_size / math.max(texture_width - 1, 1)
	local sample_step_y = chunk_world_size / math.max(texture_height - 1, 1)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 uv01 = vec2(pixel.x / max(%.6f, 1.0), pixel.y / max(%.6f, 1.0));
		vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv01 * %.6f;
		vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		float elevation = %.6f + h01 * %.6f - %.6f;
		vec2 sample_step = vec2(%.6f, %.6f);
		float slope01 = sampleSceneTerrainSlope01(source_world_pos, terrain_world_pos, sample_step, %.6f);
		return sampleSceneTerrainMaterialWeights(source_world_pos, terrain_world_pos, elevation, h01, slope01);
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
		self.HeightScale * 0.5,
		sample_step_x,
		sample_step_y,
		self.HeightScale
	)
end

function ProceduralTerrainSource:BuildDisplacementShader(chunk_min_x, chunk_min_z, chunk_world_size)
	return string.format(
		[[
		vec2 terrain_world_pos = vec2(%.6f, %.6f) + uv * %.6f;
		vec2 source_world_pos = terrain_world_pos + vec2(%.6f, %.6f);
		float h01 = sampleSceneTerrainHeight01(source_world_pos, terrain_world_pos);
		float h = sampleSceneTerrainDisplacement01(source_world_pos, terrain_world_pos, h01);
		return vec4(h, h, h, 1.0);
	]],
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y
	)
end

return ProceduralTerrainSource
