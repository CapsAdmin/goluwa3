local Color = import("goluwa/structs/color.lua")
return {
	name = "crystallize",
	defaults = {
		FadeIn = 1.4,
		FadeOut = 1.2,
		Intensity = 1,
		Scale = 1.1,
		Speed = 1,
		Daylight = 0.6,
		ColorA = Color(0.55, 0.85, 1.0, 1),
		ColorB = Color(0.18, 0.4, 0.75, 1),
		Params = {2.5},
	},
	glsl = [[
		vec4 big = overlay_noise(c, l.scale);
		vec4 fine = overlay_noise(c, l.scale * 4.3);
		float m = overlay_reveal(c.height, grow, (fine.g - 0.5) * 0.3) * outro * l.intensity;
		vec3 facet = vec3(fract(big.a * 7.13), fract(big.a * 13.7), fract(big.a * 3.9)) - 0.5;
		overlay_tilt(s, facet * 1.1, m * 0.85);
		s.albedo = mix(s.albedo, mix(l.color_b.rgb, l.color_a.rgb, big.a), m * 0.75);
		s.metallic *= 1.0 - m;
		overlay_set_roughness(s, 0.04, m);
		float edge = 1.0 - smoothstep(0.0, 0.07, big.b);
		float glint = 0.5 + 0.5 * sin(t * 3.0 + big.a * 40.0);
		float front = exp(-pow((grow * 1.25 - c.height - (fine.g - 0.5) * 0.3) * 9.0, 2.0)) * (1.0 - grow);
		s.emissive += l.color_a.rgb * (edge * glint * 0.6 + front * 1.5 + pow(1.0 - c.ndv, 3.0) * 0.35) * m * l.params.x;
		add_surface_film(w, m, 0.0004);
		overlay_cover(s, m * 0.9);
	]],
}
