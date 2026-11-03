return {
	FadeIn = 1,
	FadeOut = 1,
	Intensity = 1,
	Scale = 0.8,
	Speed = 1,
	Daylight = 0,
	ColorA = {1, 1, 1, 1},
	ColorB = {1, 1, 1, 1},
	Params = {
		{Name = "HueScale", Default = 1.6, Min = 0, Max = 8},
	},
	Source = [[
vec4 n = overlay_noise_at(c, vec3(0.0, t * 0.06, 0.0), l.scale);
float hue = fract(c.ndv * hue_scale + n.r * 0.8 + t * 0.06);
vec3 film = overlay_hue(hue);
s.albedo = mix(s.albedo, mix(vec3(0.9), film, 0.75), fade * 0.9);
s.metallic = mix(s.metallic, 0.95, fade);
overlay_set_roughness(s, 0.07 + n.g * 0.1, fade);
s.emissive += film * pow(1.0 - c.ndv, 2.0) * 0.18 * fade;
add_surface_film(w, fade, 0.0025);
overlay_cover(s, fade * (0.15 + 0.5 * pow(1.0 - c.ndv, 2.0)));
]],
}
