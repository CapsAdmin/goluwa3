--[=[
	Bakes tileable terrain layer textures from GLSL.

	config = {
		Size = 512,
		Header = "",         -- extra GLSL shared by all functions
		Height = [[float layer_height(vec2 uv) { ... }]], -- 0..1 relief used for normals and AO
		Albedo = [[ ... return vec4(color, roughness); ]], -- body, uv is 0..1
		Depth = 0.05,        -- relief amplitude relative to the tile size, controls normal strength
		AmbientOcclusion = [[ ... return float; ]], -- optional body, defaults to cavity + height
	}

	BakeAlbedo returns an rgba8 texture with roughness in alpha.
	BakeNormal returns an rgba8 tangent space normal (z up) with ambient occlusion in alpha.
	Both tile, so they can be sampled in world space by the terrain shader.
]=]
local Texture = import("goluwa/render/texture.lua")
local noise = import("goluwa/terrain/noise.lua")
local layer_texture = {}
local DEFAULT_AO_GLSL = [=[
	float h = layer_height(uv);
	float around = 0.0;
	float radius = texel * 6.0;

	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.7853981;
		around += layer_height(uv + vec2(cos(a), sin(a)) * radius);
	}

	float cavity = clamp((around / 8.0 - h) * 6.0, 0.0, 1.0);
	return clamp((1.0 - cavity * 0.6) * mix(0.75, 1.0, h), 0.0, 1.0);
]=]

local function make_texture(size)
	return Texture.New{
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		anisotropy = 8,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
end

local function build_header(config, size)
	return string.format("const float texel = %f;\n", 1 / size) .. noise.TILE .. (config.Header or "") .. "\n" .. config.Height
end

function layer_texture.BakeAlbedo(config)
	local size = config.Size or 512
	local texture = make_texture(size)
	texture:Shade(config.Albedo, {header = build_header(config, size)})
	return texture
end

function layer_texture.BakeNormal(config)
	local size = config.Size or 512
	local depth = config.Depth or 0.05
	local header = build_header(config, size) .. string.format(
		[=[
float layer_ambient_occlusion(vec2 uv) {
%s
}

vec3 layer_normal(vec2 uv) {
	float hl = layer_height(uv - vec2(texel, 0.0));
	float hr = layer_height(uv + vec2(texel, 0.0));
	float hd = layer_height(uv - vec2(0.0, texel));
	float hu = layer_height(uv + vec2(0.0, texel));
	float depth = %f;
	return normalize(vec3((hl - hr) * depth, (hd - hu) * depth, texel * 2.0));
}
]=],
		config.AmbientOcclusion or DEFAULT_AO_GLSL,
		depth
	)
	local texture = make_texture(size)
	texture:Shade(
		[=[
		vec3 n = layer_normal(uv);
		return vec4(n * 0.5 + 0.5, layer_ambient_occlusion(uv));
	]=],
		{header = header}
	)
	return texture
end

return layer_texture
