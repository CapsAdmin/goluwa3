local Vec2 = import("goluwa/structs/vec2.lua")
return {
	name = "micro_detail",
	category = "Micro Detail",
	block = "own",
	active = function(material)
		return material:GetMicroDetailTexture() ~= nil
	end,
	params = {
		{name = "MicroDetailTexture", kind = "texture", type = "render_texture"},
		{
			name = "MicroDetailTiling",
			kind = "vec2",
			default = Vec2(4.0, 4.0),
			requires = "MicroDetailTexture",
		},
		{name = "MicroDetailRoughness", default = 0.0, requires = "MicroDetailTexture"},
		{name = "MicroDetailNormal", default = 0.0, requires = "MicroDetailTexture"},
	},
	material_init = [[
		if (micro_detail_model.MicroDetailTexture != -1) {
			vec2 grain_uv = uv * micro_detail_model.MicroDetailTiling;
			float grain = texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv).r + texture(TEXTURE(micro_detail_model.MicroDetailTexture), grain_uv * 0.37 + 0.5).r;
			float rough = sqrt(s.roughness_alpha) - micro_detail_model.MicroDetailRoughness * (grain - 1.0);
			s.roughness_alpha = clamp(rough * rough, 0.002, 1.0);
		}
	]],
}
