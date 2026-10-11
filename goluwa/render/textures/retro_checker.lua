local Texture = import("goluwa/render/texture.lua")
local tex = Texture.New{
	width = 2,
	height = 2,
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
tex:Shade([[
	vec2 p = floor(uv * 2.0);
	float lum = mod(p.x + p.y, 2.0) > 0.5 ? 1.0 : 0.45;
	return vec4(vec3(lum), 1.0);
]])
return tex
