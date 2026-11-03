return {
	name = "aegis",
	params = {
		{Name = "Emissive", Min = 0, Max = 40},
	},
	glsl = [[
		vec4 cells = overlay_noise(c, l.scale);
		float rim = pow(1.0 - c.ndv, 2.5);
		float edge = 1.0 - smoothstep(0.0, 0.09, cells.b);
		float wave = exp(-pow((fract(c.height - t * 0.25) - 0.5) * 7.0, 2.0));
		float flick = step(0.82, fract(cells.a * 31.0 + floor(t * 2.0) * 0.37));
		float shimmer = 0.5 + 0.5 * sin(t * 4.0 + cells.a * 30.0);
		vec3 glow = l.color_a.rgb * (rim * 1.6 + edge * (0.35 + wave * 2.2) + flick * shimmer * 0.5) + l.color_b.rgb * rim * wave * 1.2;
		s.emissive += glow * fade * emissive;
		s.albedo = mix(s.albedo, l.color_a.rgb * 0.08, fade * 0.8);
		overlay_set_roughness(s, 0.12, fade * 0.6);
		overlay_cover(s, fade * max(rim * 0.8, edge * 0.6));
	]],
}
