local Color = import("goluwa/structs/color.lua")
return {
	name = "magic_generic",
	defaults = {
		FadeIn = 0.9,
		FadeOut = 0.9,
		Intensity = 1,
		Scale = 1,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(1, 1, 1, 1),
		ColorB = Color(1, 1, 1, 1),
		Params = {1.4, 6.5, 0.5},
	},
	glsl = [[
		vec4 p = vec4(c.P * l.scale, 0.2 + t * 0.03);
		vec4 p1 = p * l.params.y;
		vec4 p2 = p * l.params.y * 3.0;
		float g1 = abs(dot(sin(p1), cos(p1.zxwy)) - 1.0) / l.params.y;
		float g2 = abs(dot(sin(p2), cos(p2.zxwy)) - 1.0) / (l.params.y * 3.0);
		float d = abs(g1 - g2) * 0.25;
		float core = 0.008 / (d + 0.008);
		float soft = 0.02 / (d + 0.02);
		float ribbon = pow(core, 1.5) + soft * soft * 0.12;
		float phase = 5.0 * p.z + t * 0.5;
		vec3 palette = 1.0 + cos(vec3(1.4, 0.7, 0.0) + phase);
		vec3 sheen = palette * (0.45 + 0.55 * pow(1.0 - c.ndv, 2.0));
		s.emissive += sheen * ribbon * fade * l.params.x;
		s.albedo = mix(s.albedo, s.albedo * 0.12, fade * 0.7);
		overlay_set_roughness(s, 0.12, fade * 0.8);
		s.metallic = mix(s.metallic, 0.6, fade * 0.5);
		overlay_bump(s, ribbon * 0.02 * fade, l.params.z * 10.0);
		overlay_cover(s, fade * (0.35 + 0.5 * min(ribbon, 1.0)));
	]],
}
