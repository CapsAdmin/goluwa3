local Color = import("goluwa/structs/color.lua")
return {
	name = "status_fire",
	defaults = {
		FadeIn = 0.5,
		FadeOut = 0.6,
		Intensity = 2,
		Scale = 1.6,
		Speed = 0.7,
		Daylight = 1.2,
		ColorA = Color(1, 0.38, 0.05, 1),
		ColorB = Color(1, 0.85, 0.35, 1),
		Params = {1.1},
	},
	glsl = [[
		float flame_time = t * 0.8;
		vec3 uvw = c.P * l.scale + vec3(0.0, -flame_time, flame_time * 0.5);
		vec4 flow = vec4(0.0);
		float frequency = 1.0;
		float amplitude = 1.0;

		for (int i = 0; i < 5; i++) {
			float angle = (t * 0.4 + c.P.y * 0.5) * 2.0 * frequency;
			vec4 dn = overlay_gradient_noise(uvw, angle);
			uvw -= 0.01 * dn.xyz;
			flow += abs(amplitude * dn);
			uvw *= 2.13;
			frequency *= 2.13;
			amplitude /= 2.13;
		}

		float de = length(flow.xyz) * 0.4 + 0.2 - flow.w * 0.3;
		vec3 flame = overlay_hsv(vec3((de - 0.375) * 0.2083, de * 1.25 + 0.2, de * 0.95));
		float heat = smoothstep(0.5, 0.95, de);
		s.emissive += flame * heat * fade * l.params.x;
		s.albedo = mix(s.albedo, s.albedo * 0.15, fade * 0.7 * (1.0 - heat));
		overlay_set_roughness(s, 0.85, fade * 0.5);
		s.metallic *= 1.0 - fade * 0.6;
		overlay_cover(s, fade * (0.35 + heat * 0.5));
	]],
}
