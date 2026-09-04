local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local TerrainSource = import("goluwa/terrain/source.lua")
local ShaderSource = setmetatable({}, {__index = TerrainSource})
ShaderSource.__index = ShaderSource
local FloatArray = ffi.typeof("float[?]")
local BakeConstants = ffi.typeof([[
	struct {
		float origin_x;
		float origin_z;
		float step_x;
		float step_z;
		float sample_step;
		int texture0;
		int texture1;
		int texture2;
		int texture3;
	}
]])
local BAKE_DECLARATIONS = [[
layout(push_constant, scalar) uniform TerrainBakeConstants {
	float origin_x;
	float origin_z;
	float step_x;
	float step_z;
	float sample_step;
	int texture0;
	int texture1;
	int texture2;
	int texture3;
} terrain_bake;
]]
-- available to the source GLSL: the world distance between samples of the
-- current bake, so height functions can fade detail that a coarse LOD cannot represent
local BAKE_STEP_HELPER = [[
float terrain_bake_step() {
	return terrain_bake.sample_step;
}
]]
local BAKE_HELPERS = [[
vec2 terrain_bake_world_pos() {
	vec2 pixel = gl_FragCoord.xy - vec2(0.5);
	return vec2(terrain_bake.origin_x, terrain_bake.origin_z) + pixel * vec2(terrain_bake.step_x, terrain_bake.step_z);
}

vec3 terrain_bake_normal(vec2 p) {
	float s = terrain_bake.sample_step;
	float h_left = terrain_height(p - vec2(s, 0.0));
	float h_right = terrain_height(p + vec2(s, 0.0));
	float h_down = terrain_height(p - vec2(0.0, s));
	float h_up = terrain_height(p + vec2(0.0, s));
	return normalize(vec3(h_left - h_right, 2.0 * s, h_down - h_up));
}
]]
local HEIGHT_BAKE = [[
	float h = terrain_height(terrain_bake_world_pos());
	return vec4(h, h, h, 1.0);
]]
local SPLAT_BAKE = [[
	vec2 p = terrain_bake_world_pos();
	float h = terrain_height(p);
	vec3 n = terrain_bake_normal(p);
	return terrain_splat(p, h, n);
]]
local COLOR_BAKE = [[
	vec2 p = terrain_bake_world_pos();
	float h = terrain_height(p);
	vec3 n = terrain_bake_normal(p);
	return vec4(terrain_color(p, h, n), 1.0);
]]

local function make_bake_texture(size, format)
	return Texture.New{
		width = size,
		height = size,
		format = format,
		mip_map_levels = 1,
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

function ShaderSource.New(config)
	local self = setmetatable(TerrainSource.New(config), ShaderSource)
	self.Textures = config.Textures or {}
	self.HasSplat = config.SplatGLSL ~= nil
	self.HasColor = config.ColorGLSL ~= nil
	self.ShaderHeader = table.concat(
		{
			BAKE_STEP_HELPER,
			config.Header or
			"",
			config.HeightGLSL,
			config.SplatGLSL or
			"",
			config.ColorGLSL or
			"",
			BAKE_HELPERS,
		},
		"\n"
	)
	return self
end

function ShaderSource:GetShaderHeader()
	return self.ShaderHeader
end

function ShaderSource:Bake(texture, glsl, origin_x, origin_z, step_x, step_z, sample_step)
	local textures = self.Textures
	texture:Shade(
		glsl,
		{
			header = self.ShaderHeader,
			custom_declarations = BAKE_DECLARATIONS,
			textures = textures,
			fragment_push_constants = {
				size = ffi.sizeof(BakeConstants),
				get_data = function(_, _, pipeline)
					return BakeConstants(
						origin_x,
						origin_z,
						step_x,
						step_z,
						sample_step,
						textures[1] and pipeline:GetTextureIndex(textures[1]) or -1,
						textures[2] and pipeline:GetTextureIndex(textures[2]) or -1,
						textures[3] and pipeline:GetTextureIndex(textures[3]) or -1,
						textures[4] and pipeline:GetTextureIndex(textures[4]) or -1
					)
				end,
			},
		}
	)
	return texture
end

function ShaderSource:BakeTexelCentered(size, format, glsl, request)
	local step = request.size / size
	return self:Bake(
		make_bake_texture(size, format),
		glsl,
		request.min_x + step * 0.5,
		request.min_z + step * 0.5,
		step,
		step,
		step
	)
end

function ShaderSource:ReadHeights(request)
	local samples = request.samples
	local step = request.size / (samples - 1)
	local texture = self:Bake(
		make_bake_texture(samples, "r32_sfloat"),
		HEIGHT_BAKE,
		request.min_x,
		request.min_z,
		step,
		step,
		step
	)
	local downloaded = texture:Download()
	local pixels = ffi.cast("float*", downloaded.pixels)
	local count = samples * samples
	local heights = FloatArray(count)
	ffi.copy(heights, pixels, count * 4)
	texture:Remove()
	local min_height = math.huge
	local max_height = -math.huge

	for i = 0, count - 1 do
		local h = heights[i]

		if h < min_height then min_height = h end

		if h > max_height then max_height = h end
	end

	return heights, min_height, max_height
end

function ShaderSource:RequestChunk(request, callback)
	local chunk = {request = request}

	if request.samples then
		chunk.heights, chunk.min_height, chunk.max_height = self:ReadHeights(request)
	end

	if request.detail_size then
		chunk.height_texture = self:BakeTexelCentered(request.detail_size, "r32_sfloat", HEIGHT_BAKE, request)
	end

	if request.splat_size and self.HasSplat then
		chunk.splat_texture = self:BakeTexelCentered(request.splat_size, "r8g8b8a8_unorm", SPLAT_BAKE, request)
	end

	if request.color_size and self.HasColor then
		chunk.color_texture = self:BakeTexelCentered(request.color_size, "r8g8b8a8_unorm", COLOR_BAKE, request)
	end

	callback(chunk)
end

return ShaderSource
