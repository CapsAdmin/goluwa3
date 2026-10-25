local Color = import("goluwa/structs/color.lua")
return {
	name = "subsurface_color",
	category = "Subsurface",
	block = "own",
	active = function(material)
		return material.Subsurface > 0
	end,
	params = {
		{name = "SubsurfaceColor", kind = "vec4", default = Color(1.0, 0.4, 0.2, 1.0)},
	},
	fields = {
		{
			name = "subsurface_tint_r",
			kind = "unorm4",
			member = false,
			default = "1.95",
			encode = "v * 0.5",
			decode = "v * 2.0",
			max = 2,
			readers = {"lighting", "subsurface"},
		},
		{
			name = "subsurface_tint_b",
			kind = "unorm4",
			member = false,
			default = "0.39",
			encode = "v * 0.5",
			decode = "v * 2.0",
			max = 2,
			readers = {"lighting", "subsurface"},
		},
	},
	surface_members = [[

		vec3 subsurface_tint;
	]],
	surface_default = [[
		s.subsurface_tint = vec3(1.95, 0.78, 0.39);
	]],
	material_init = [[
		s.subsurface_tint = get_subsurface_tint();
	]],
	gbuffer_write = [[
		set_subsurface_tint_r(gbuffer_encode_subsurface_tint_r(s.subsurface_tint.r));
		set_subsurface_tint_b(gbuffer_encode_subsurface_tint_b(s.subsurface_tint.b));
	]],
	decoders = [[
		vec3 gbuffer_subsurface_tint(COORD c) {
			float r = gbuffer_subsurface_tint_r(c);
			float b = gbuffer_subsurface_tint_b(c);
			return vec3(r, max((1.0 - 0.2126 * r - 0.0722 * b) / 0.7152, 0.0), b);
		}
	]],
	getters = [[
		vec3 get_subsurface_tint() {
			if (factor_model.Subsurface <= 0.0) return vec3(1.95, 0.78, 0.39);

			vec3 tint = subsurface_color_model.SubsurfaceColor.rgb;
			return tint / max(luminance(tint), 0.001);
		}
	]],
}
