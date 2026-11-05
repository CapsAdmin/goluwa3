local Texture = import("goluwa/render/texture.lua")
local noise = import("goluwa/terrain/noise.lua")
local layer_texture = {}

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
	return string.format("const float texel = %f;\n", 1 / size) .. noise.TILE .. (
			config.Header or
			""
		) .. "\n" .. config.Height
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
vec3 layer_normal(vec2 uv) {
	float hl = layer_height(uv - vec2(texel, 0.0));
	float hr = layer_height(uv + vec2(texel, 0.0));
	float hd = layer_height(uv - vec2(0.0, texel));
	float hu = layer_height(uv + vec2(0.0, texel));
	float depth = %f;
	return normalize(vec3((hl - hr) * depth, (hd - hu) * depth, texel * 2.0));
}
]=],
			depth
		)
	local texture = make_texture(size)
	texture:Shade(
		[=[
		vec3 n = layer_normal(uv);
		return vec4(n * 0.5 + 0.5, 1.0);
	]=],
		{header = header}
	)
	return texture
end

return layer_texture
