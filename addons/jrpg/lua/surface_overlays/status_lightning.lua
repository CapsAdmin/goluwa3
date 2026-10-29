local Color = import("goluwa/structs/color.lua")
return {
	name = "status_lightning",
	defaults = {
		FadeIn = 0.2,
		FadeOut = 0.4,
		Intensity = 1,
		Scale = 1.3,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(0.55, 0.7, 1.0, 1),
		ColorB = Color(1, 1, 1, 1),
		Params = {7, 0.9, 1.6},
	},
	glsl = [[
		float step_time = t * 7.0;
		float seed = floor(step_time);
		float local_t = fract(step_time);
		float strike = step(0.3, overlay_hash(seed + 5.0)) * exp(-local_t * 3.0);
		float flicker = mix(0.6, 1.0, overlay_hash(floor(t * 45.0) + 91.0));
		float bolt = 0.0;

		for (int i = 0; i < 2; i++) {
			float bolt_seed = seed * 2.0 + float(i);
			vec3 dir = normalize(vec3(overlay_hash(bolt_seed) - 0.5, overlay_hash(bolt_seed + 7.0) - 0.5, overlay_hash(bolt_seed + 13.0) - 0.5) + vec3(0.0, 0.0001, 0.0));
			vec3 q = c.P * l.params.z + vec3(bolt_seed * 7.3);
			float along = dot(c.P * l.params.z, dir) + (overlay_hash(bolt_seed + 21.0) - 0.5) * 0.8;
			float dist = abs(along + (2.0 * overlay_fbm(q, 6) - 1.0) * l.params.y);
			bolt += 0.004 / (dist + 0.002) + 0.0015 / (dist + 0.025);
		}

		float charge = (pow(1.0 - c.ndv, 2.0) * 0.6 + 0.04) * (0.5 + 0.5 * sin(t * 9.0 + c.height * 12.0));
		s.emissive += (l.color_b.rgb * min(bolt, 8.0) * strike * flicker * l.params.x + l.color_a.rgb * (charge + strike * 0.2)) * fade;
		s.albedo = mix(s.albedo, s.albedo * vec3(0.5, 0.55, 0.75), fade * 0.5);
		overlay_cover(s, fade * 0.7);
	]],
}
