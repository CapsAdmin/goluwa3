local Color = import("goluwa/structs/color.lua")
return {
	name = "blight",
	defaults = {
		FadeIn = 3.0,
		FadeOut = 2.0,
		Intensity = 1,
		Scale = 1.4,
		Speed = 1,
		Daylight = 0.9,
		ColorA = Color(0.55, 1.0, 0.2, 1),
		ColorB = Color(0.1, 0.08, 0.04, 1),
		Params = {18},
	},
	glsl = [[
		vec4 big = overlay_noise(c, l.scale);
		vec4 fine = overlay_noise(c, l.scale * 3.1);
		float field = big.r * 0.6 + fine.g * 0.4;
		float reach = grow * 1.1 * mix(1.0, 0.0, 1.0 - outro);
		float cover = smoothstep(0.0, 0.07, reach - field) * outro;
		float frontier = (1.0 - smoothstep(0.0, 0.22, reach - field)) * cover;
		s.albedo = mix(s.albedo, mix(l.color_b.rgb, l.color_b.rgb * vec3(1.6, 1.8, 0.8), fine.r), cover * 0.9 * l.intensity);
		s.metallic *= 1.0 - cover;
		overlay_set_roughness(s, 0.9, cover);
		overlay_tilt(s, (fine.rgb - 0.5) * 0.9, cover * 0.7);
		float vein = 1.0 - smoothstep(0.0, 0.08, big.b);
		float throb = 0.6 + 0.4 * sin(t * 1.8 + big.a * 20.0);
		s.emissive += l.color_a.rgb * (frontier * 1.4 + vein * throb * 0.9 * cover) * l.params.x * 0.5;
		s.ao *= 1.0 - cover * 0.4;
		w.wet_scale *= 1.0 - cover;
		overlay_cover(s, cover * l.intensity);
	]],
}
