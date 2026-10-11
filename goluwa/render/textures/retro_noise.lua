local Texture = import("goluwa/render/texture.lua")
return function(options)
	options = options or {}
	local size = options.size or 64
	local levels = options.levels or 6
	local tex = Texture.New{
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		anisotropy = 0,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
	tex:Shade(
		string.format(
			[[
		float size = %d.0;
		float levels = %d.0;
		vec2 p = floor(uv * size);
		float h = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
		float wave = sin(6.2831853 * (p.x + p.y) * 4.0 / size);
		float weave = sin(6.2831853 * (p.x - p.y) * 2.0 / size);
		float lum = 0.86 + 0.07 * wave + 0.04 * weave + 0.09 * h;
		lum = floor(lum * levels + 0.5) / levels;
		return vec4(vec3(lum), 1.0);
	]],
			size,
			levels
		)
	)
	return tex
end
