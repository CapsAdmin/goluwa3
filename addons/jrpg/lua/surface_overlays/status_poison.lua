local Color = import("goluwa/structs/color.lua")
return {
	name = "status_poison",
	defaults = {
		FadeIn = 0.6,
		FadeOut = 0.8,
		Intensity = 1,
		Scale = 1.5,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(0.35, 1, 0.3, 1),
		ColorB = Color(0.7, 1, 0.4, 1),
		Params = {1.8, 1.1, 0.12},
	},
	glsl = [[
		vec4 warp_a = overlay_noise_at(c, vec3(t * 0.04, 0.0, 0.0), l.scale * 0.3);
		vec4 warp_b = overlay_noise_at(c, vec3(0.0, t * 0.04, 7.0), l.scale * 0.3);
		vec3 warp = (vec3(warp_a.r, warp_a.g, warp_b.r) - 0.5) * l.params.z;
		float inside = 0.0;
		float rim = 0.0;
		vec3 gradient = vec3(0.0);

		for (int layer = 0; layer < 2; layer++) {
			float frequency = l.scale * (layer == 0 ? 2.6 : 3.7);
			OverlayCell big = overlay_voronoi(c.P * frequency + warp + vec3(float(layer) * 11.0));
			float radius = mix(0.3, 0.5, big.id.x) * (0.94 + 0.06 * sin(t * 1.4 + big.id.y * 30.0));
			float layer_inside = 1.0 - smoothstep(radius - 0.03, radius, big.nearest);
			rim = max(rim, smoothstep(radius - 0.1, radius - 0.015, big.nearest) * (1.0 - smoothstep(radius - 0.015, radius, big.nearest)));
			gradient += big.offset * (layer_inside * 2.0 * (layer == 0 ? 0.8 : 0.55) * frequency);
			inside = max(inside, layer_inside);
		}

		OverlayCell fizz = overlay_voronoi(c.P * l.scale * 7.0 + warp + vec3(0.0, 0.0, 17.0));
		float phase = fract(t * (0.25 + 0.35 * fizz.id.z) + fizz.id.y * 13.0);
		float hosts = step(fizz.id.x, 0.55);
		float pop = smoothstep(0.8, 1.0, phase);
		float fizz_radius = 0.36 * (0.2 + 0.8 * smoothstep(0.0, 0.8, phase)) + pop * 0.12;
		float body = (1.0 - smoothstep(fizz_radius - 0.025, fizz_radius, fizz.nearest)) * (1.0 - pop) * hosts;
		float burst = smoothstep(fizz_radius - 0.05, fizz_radius - 0.01, fizz.nearest) * (1.0 - smoothstep(fizz_radius - 0.01, fizz_radius + 0.015, fizz.nearest)) * pop * (1.0 - pop) * 4.0 * hosts;
		gradient += fizz.offset * (body * 2.0 * 0.5 * l.scale * 7.0);

		overlay_bump_gradient(s, c, gradient * fade, l.params.y);
		vec3 slime = s.albedo * vec3(0.45, 0.8, 0.35) + l.color_a.rgb * 0.06;
		s.albedo = mix(s.albedo, mix(slime, l.color_a.rgb * 0.35, inside * 0.6), fade * 0.65);
		overlay_set_roughness(s, 0.04, fade * max(inside, 0.4));
		add_surface_film(w, fade * 0.6, 0.02);
		float glow = inside * 0.05 + rim * 0.8 + pow(1.0 - c.ndv, 3.0) * 0.3;
		s.emissive += (l.color_a.rgb * glow + l.color_b.rgb * (body * 0.45 + burst * 2.2)) * fade * l.params.x;
		overlay_cover(s, fade * (0.35 + inside * 0.35 + body * 0.2));
	]],
}
