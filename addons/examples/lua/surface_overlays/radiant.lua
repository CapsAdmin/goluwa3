return {
	FadeIn = 0.8,
	FadeOut = 1,
	Intensity = 1,
	Scale = 1,
	Speed = 1,
	Daylight = 1,
	ColorA = {1, 0.82, 0.45, 1},
	ColorB = {1, 1, 0.95, 1},
	Params = {
		{Default = 1.6, Max = 40, Min = 0, Name = "Emissive"},
		{Default = 7, Max = 24, Min = 0, Name = "RayCount"},
	},
	Source = [[
vec4 n = overlay_noise(c, l.scale);
float breath = 0.55 + 0.45 * sin(t * 1.6);
float angle = atan(c.P.z, c.P.x);
float rays = smoothstep(0.35, 1.0, sin(angle * ray_count + t * 0.9 + n.g * 2.0) * 0.5 + 0.5);
float halo = pow(c.ndv, 1.5);
float rise = smoothstep(0.0, 1.0, c.height + (n.r - 0.5) * 0.4);
s.albedo = mix(s.albedo, mix(s.albedo, l.color_b.rgb, 0.7), fade * 0.6);
overlay_set_roughness(s, 0.35, fade * 0.5);
s.emissive += (l.color_a.rgb * (breath * halo * 0.9 + rays * 0.8 * rise) + l.color_b.rgb * pow(breath, 3.0) * 0.4) * fade * emissive;
add_surface_film(w, fade * 0.4, 0.02);
overlay_cover(s, fade * 0.35);
]],
}
