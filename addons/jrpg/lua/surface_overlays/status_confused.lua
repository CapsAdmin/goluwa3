local Color = import("goluwa/structs/color.lua")
return {
	name = "status_confused",
	defaults = {
		FadeIn = 0.5,
		FadeOut = 0.6,
		Intensity = 1,
		Scale = 1.2,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(1, 0.95, 0.4, 1),
		ColorB = Color(1, 1, 1, 1),
		Params = {1.4},
	},
	glsl = [[
		vec4 n = overlay_noise_at(c, vec3(0.0, t * 0.1, 0.0), l.scale);
		float angle = atan(c.P.z, c.P.x);
		float swirl = sin(angle * 3.0 + c.height * 7.0 - t * 2.4 + n.g * 2.0) * 0.5 + 0.5;
		float band = smoothstep(0.55, 0.95, swirl);
		float stars = smoothstep(0.88, 0.95, n.r) * (0.5 + 0.5 * sin(t * 6.0 + n.a * 40.0));
		vec3 color = mix(l.color_a.rgb, overlay_hue(fract(angle / 6.2831853 + t * 0.15)), 0.35);
		s.emissive += (color * (band * 0.8 + pow(1.0 - c.ndv, 2.5) * 0.4) + l.color_b.rgb * stars * 1.6) * fade * l.params.x;
		overlay_cover(s, fade * (band * 0.4 + 0.1));
	]],
}
