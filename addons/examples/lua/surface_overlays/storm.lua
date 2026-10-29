local Color = import("goluwa/structs/color.lua")
return {
	name = "storm",
	defaults = {
		FadeIn = 0.4,
		FadeOut = 0.8,
		Intensity = 1,
		Scale = 1.3,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(0.55, 0.7, 1.0, 1),
		ColorB = Color(1.0, 1.0, 1.0, 1),
		Params = {14},
	},
	glsl = [[
		float step_time = t * 6.0;
		float seed = floor(step_time);
		float local_t = fract(step_time);
		vec3 jump = vec3(overlay_hash(seed), overlay_hash(seed + 11.0), overlay_hash(seed + 23.0)) * 8.0;
		vec4 bolts = overlay_noise_at(c, jump, l.scale);
		vec4 branches = overlay_noise_at(c, jump + 3.7, l.scale * 2.9);
		float strike = step(0.4, overlay_hash(seed + 5.0)) * exp(-local_t * 5.0);
		float arc = 1.0 - smoothstep(0.0, 0.03, bolts.b);
		float twig = (1.0 - smoothstep(0.0, 0.022, branches.b)) * 0.5;
		float charge = (pow(1.0 - c.ndv, 2.0) * 0.8 + 0.15) * (0.5 + 0.5 * sin(t * 9.0 + c.height * 12.0));
		s.emissive += (l.color_b.rgb * (arc + twig) * strike * l.params.x + l.color_a.rgb * charge * 1.0) * fade;
		s.emissive += l.color_a.rgb * strike * 0.25 * fade;
		s.albedo = mix(s.albedo, vec3(0.03, 0.035, 0.05), fade * 0.8);
		overlay_set_roughness(s, 0.3, fade * 0.7);
		overlay_cover(s, fade * 0.85);
	]],
}
