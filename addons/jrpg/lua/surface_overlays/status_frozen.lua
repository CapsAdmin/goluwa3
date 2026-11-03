return {
	name = "status_frozen",
	glsl = [[
		OverlayCell cell = overlay_voronoi(c.P * l.scale * 6.0);
		vec4 fine = overlay_noise(c, l.scale * 4.3);
		float m = overlay_reveal(c.height, l.intensity, (fine.g - 0.5) * 0.3) * smoothstep(0.0, 1.0, grow) * outro;
		vec3 facet = cell.id - 0.5;
		overlay_tilt(s, facet * 1.1, m * 0.8);
		s.albedo = mix(s.albedo, mix(l.color_b.rgb, l.color_a.rgb, cell.id.x), m * 0.8);
		s.metallic *= 1.0 - m;
		overlay_set_roughness(s, 0.05, m);
		float sparkle = pow(max(sin(t * 2.5 + cell.id.y * 40.0), 0.0), 24.0);
		s.emissive += l.color_a.rgb * (sparkle * 0.5 + pow(1.0 - c.ndv, 3.0) * 0.45) * m * l.params.x;
		overlay_cover(s, m * 0.9);
	]],
}
