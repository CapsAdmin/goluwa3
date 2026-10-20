local Vec2 = import("goluwa/structs/vec2.lua")
-- a tiling grayscale grain (a source $detail texture) that varies the roughness and the normal of a surface up
-- close, darker is rougher. its middle gray leaves the roughness as it is
return {
	name = "micro_detail",
	category = "Micro Detail",
	block = "own",
	active = function(material)
		return material:GetMicroDetailTexture() ~= nil
	end,
	params = {
		{name = "MicroDetailTexture", kind = "texture", type = "render_texture"},
		{name = "MicroDetailTiling", kind = "vec2", default = Vec2(4.0, 4.0), requires = "MicroDetailTexture"},
		-- perceptual roughness per unit of grain, the grain being from -1 to 1
		{name = "MicroDetailRoughness", default = 0.0, requires = "MicroDetailTexture"},
		-- the slope of the normal per unit of grain height change over one texel, 1 is 45 degrees
		{name = "MicroDetailNormal", default = 0.0, requires = "MicroDetailTexture"},
	},
	material_init = [[
		if (micro_detail_model.MicroDetailTexture != -1) {
			vec2 grain_uv = uv * micro_detail_model.MicroDetailTiling;
			// two scales so the repeat is not seen
			float grain = texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv).r + texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv * 0.37 + 0.5).r;
			float rough = sqrt(s.roughness_alpha) - micro_detail_model.MicroDetailRoughness * (grain - 1.0);
			s.roughness_alpha = clamp(rough * rough, 0.002, 1.0);
		}
	]],
}
