return {
	FadeIn = 1,
	FadeOut = 3,
	Intensity = 1,
	Scale = 1,
	Speed = 0,
	Daylight = 1,
	ColorA = {0.2, 0.19, 0.18, 1},
	ColorB = {0.42, 0.3, 0.2, 1},
	Params = {},
	Source = [[
vec4 broad = overlay_noise(c, l.scale * 0.31);
vec4 cracks = overlay_noise(c, l.scale * 1.9);
float burnt = fade * 1.2;
float threshold = mix(0.12, 0.85, broad.r);
float charred = smoothstep(threshold - 0.07, threshold + 0.07, burnt);
float scorch = smoothstep(threshold - 0.5, threshold - 0.02, burnt) * (1.0 - charred);
float crack = 1.0 - smoothstep(0.02, 0.16, cracks.b);
float ash = smoothstep(0.7, 1.0, burnt) * smoothstep(0.35, 0.8, cracks.a);
vec3 charcoal = vec3(0.022, 0.019, 0.017) * mix(0.55, 1.5, cracks.a);
s.albedo = mix(s.albedo, s.albedo * l.color_b.rgb, scorch * 0.85);
s.albedo = mix(s.albedo, mix(charcoal, l.color_a.rgb, ash * 0.75), charred);
overlay_set_roughness(s, 0.8, charred);
s.metallic *= 1.0 - charred;
s.ao *= 1.0 - crack * charred * 0.6;
]],
}
