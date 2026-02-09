local Texture = require("render.texture")
local tex = Texture.New(
	{
		width = 256,
		height = 256,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
)
tex:Shade([[
	float dist = distance(uv, vec2(0.5));
	float alpha = 1.0 - clamp(dist / 0.5, 0.0, 1.0);
	return vec4(1.0, 1.0, 1.0, alpha);
]])
return tex
