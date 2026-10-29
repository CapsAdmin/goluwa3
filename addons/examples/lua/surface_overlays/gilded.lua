local Color = import("goluwa/structs/color.lua")
return {
	name = "gilded",
	defaults = {
		FadeIn = 1.6,
		FadeOut = 1.2,
		Intensity = 1,
		Scale = 3,
		Speed = 1,
		Daylight = 0.5,
		ColorA = Color(1.0, 0.72, 0.28, 1),
		ColorB = Color(1.0, 0.95, 0.7, 1),
		Params = {3},
	},
	glsl = [[
		vec4 grain = overlay_noise(c, l.scale);
		float d = grow * 1.3 - c.height - (grain.g - 0.5) * 0.2;
		float m = smoothstep(0.0, 0.1, d) * outro * l.intensity;
		float front = exp(-pow((d - 0.05) * 14.0, 2.0)) * (1.0 - grow) * 2.0 * outro;
		float sweep = pow(max(sin((c.height * 3.0 - t * 0.5) * 3.14159), 0.0), 24.0);
		s.albedo = mix(s.albedo, l.color_a.rgb * (0.9 + grain.r * 0.15), m);
		s.metallic = mix(s.metallic, 1.0, m);
		overlay_set_roughness(s, 0.14 + grain.g * 0.2, m);
		vec3 ripple = (grain.rgb - 0.5) * 0.35;
		overlay_tilt(s, ripple, m * 0.5);
		overlay_cover(s, m);
		s.emissive += l.color_b.rgb * (front * l.params.x + sweep * 0.12 * m);
	]],
}
