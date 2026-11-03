return {
	FadeIn = 0.6,
	FadeOut = 0.4,
	Intensity = 1,
	Scale = 1.5,
	Speed = 1,
	Daylight = 0.7,
	ColorA = {1, 0.72, 0.2, 1},
	ColorB = {1, 0.93, 0.7, 1},
	Params = {
		{Name = "Emissive", Default = 1.2, Min = 0, Max = 40},
	},
	Source = [[
vec4 n = overlay_noise(c, l.scale);
float rim = pow(1.0 - c.ndv, 2.2);
float pulse = 0.75 + 0.25 * sin(t * 3.0);
float sweep = exp(-pow((fract(c.height * 0.9 - t * 0.3) - 0.5) * 5.0, 2.0));
float shimmer = 0.85 + 0.15 * sin(t * 5.0 + n.g * 12.0);
vec3 glow = l.color_a.rgb * (0.08 + rim * 1.6) * pulse * shimmer + l.color_b.rgb * (sweep * 0.4 + rim * 0.3);
s.emissive += glow * fade * emissive;
s.albedo = mix(s.albedo, s.albedo * l.color_a.rgb * 1.4, fade * 0.25);
]],
}
