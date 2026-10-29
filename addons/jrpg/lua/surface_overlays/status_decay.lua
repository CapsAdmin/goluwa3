local Color = import("goluwa/structs/color.lua")
return {
	name = "status_decay",
	defaults = {
		FadeIn = 0.8,
		FadeOut = 1.0,
		Intensity = 1,
		Scale = 1.4,
		Speed = 1,
		Daylight = 0.9,
		ColorA = Color(0.75, 0.15, 0.7, 1),
		ColorB = Color(0.06, 0.02, 0.08, 1),
		Params = {2.4, 0.7},
	},
	glsl = [[
		vec4 big = overlay_noise(c, l.scale);
		vec4 fine = overlay_noise(c, l.scale * 3.1);
		float field = big.r * 0.6 + fine.g * 0.4;
		float reach = l.intensity * 1.1;
		float cover = smoothstep(0.0, 0.07, reach - field) * smoothstep(0.0, 1.0, grow) * outro;
		float frontier = (1.0 - smoothstep(0.0, 0.22, reach - field)) * cover;

		vec4 slow_a = overlay_noise_at(c, vec3(t * 0.11, t * 0.07, 0.0), l.scale * 0.8);
		vec4 slow_b = overlay_noise_at(c, vec3(-t * 0.08, 3.0, t * 0.1), l.scale * 1.7);
		vec3 wobble = vec3(slow_a.r - 0.5, slow_a.g - 0.5, slow_b.r - 0.5) * 1.6 + vec3(slow_b.g - 0.5, slow_b.b - 0.5, slow_a.b - 0.5) * 0.8;
		wobble += vec3(sin(c.P.y * 6.0 + t * 1.7), sin(c.P.z * 5.0 - t * 1.3), sin(c.P.x * 7.0 + t * 1.1)) * 0.18;

		s.albedo = mix(s.albedo, mix(l.color_b.rgb, l.color_a.rgb * 0.1, fine.r), cover * 0.9);
		s.metallic *= 1.0 - cover;
		overlay_set_roughness(s, 0.22, cover);
		overlay_tilt(s, wobble * l.params.y, cover);
		s.emissive += l.color_a.rgb * (frontier * 1.2 + pow(1.0 - c.ndv, 3.0) * 0.5 * fade) * l.params.x;
		s.ao *= 1.0 - cover * 0.4;
		overlay_cover(s, cover);
	]],
}
