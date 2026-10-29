local Color = import("goluwa/structs/color.lua")
return {
	name = "void_rift",
	defaults = {
		FadeIn = 1.0,
		FadeOut = 1.0,
		Intensity = 1,
		Scale = 0.9,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(0.62, 0.15, 1.0, 1),
		ColorB = Color(0.02, 0.0, 0.05, 1),
		Params = {6},
	},
	glsl = [[
		vec4 big = overlay_noise_at(c, vec3(0.0, t * 0.04, 0.0), l.scale);
		vec4 fine = overlay_noise_at(c, vec3(t * 0.05, 0.0, 0.0), l.scale * 2.7);
		float spread = smoothstep(0.0, 0.25, grow * 1.2 - big.r * 0.6);
		float m = spread * fade;
		s.albedo = mix(s.albedo, l.color_b.rgb, m * 0.92);
		s.metallic = mix(s.metallic, 0.0, m);
		overlay_set_roughness(s, 0.32, m);
		float crack = 1.0 - smoothstep(0.0, 0.1, big.b);
		float fine_crack = 1.0 - smoothstep(0.0, 0.06, fine.b);
		float pulse = 0.65 + 0.35 * sin(t * 2.2 + big.a * 25.0);
		float motes = smoothstep(0.93, 1.0, fine.g) * (0.5 + 0.5 * sin(t * 5.0 + fine.a * 60.0));
		s.emissive += l.color_a.rgb * (crack * pulse + fine_crack * 0.35 + motes * 1.5) * m * l.params.x;
		s.emissive += l.color_a.rgb * pow(1.0 - c.ndv, 4.0) * 0.6 * m;
		s.ao = mix(s.ao, 1.0, m * 0.5);
		overlay_cover(s, m * 0.95);
	]],
}
