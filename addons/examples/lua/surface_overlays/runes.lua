local Color = import("goluwa/structs/color.lua")
return {
	name = "runes",
	defaults = {
		FadeIn = 1.2,
		FadeOut = 1.0,
		Intensity = 1,
		Scale = 5,
		Speed = 1,
		Daylight = 1,
		ColorA = Color(1.0, 0.55, 0.15, 1),
		ColorB = Color(1.0, 0.9, 0.5, 1),
		Params = {4, 12},
	},
	glsl = [[
		float bands = max(l.params.y * 0.5, 3.0);
		float ring = floor(c.height * bands);
		float ring_frac = fract(c.height * bands);
		float dir = overlay_hash(ring) > 0.5 ? 1.0 : -1.0;
		float angle = atan(c.P.z, c.P.x) / 6.2831853 + 0.5;
		float columns = l.params.y;
		float spin = t * 0.04 * dir * (0.6 + overlay_hash(ring + 3.0));
		float slot_pos = (angle + spin) * columns;
		float column = floor(slot_pos);
		vec2 uv = vec2(fract(slot_pos), ring_frac);
		float lit = step(0.28, overlay_hash2(vec2(column, ring)));
		vec2 cell = floor(uv * vec2(3.0, 5.0));
		vec2 inner = fract(uv * vec2(3.0, 5.0));
		float stroke = step(0.5, overlay_hash2(cell + vec2(column, ring) * 7.0));
		float bar = step(0.2, inner.x) * step(inner.x, 0.8) * step(0.2, inner.y) * step(inner.y, 0.8);
		float frame = 1.0 - step(0.06, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
		float glyph = (stroke * bar * 0.9 + frame * 0.35) * lit;
		float pulse = 0.6 + 0.4 * sin(t * 2.0 + column * 1.3 + ring);
		float reveal = smoothstep(0.0, 0.3, grow * 1.4 - abs(c.height - 0.5) * 1.4);
		float mask = smoothstep(0.08, 0.2, c.height) * smoothstep(0.92, 0.8, c.height);
		vec3 heat = mix(l.color_a.rgb, l.color_b.rgb, pulse * pulse);
		s.emissive += heat * glyph * pulse * reveal * mask * fade * l.params.x;
		overlay_cover(s, fade * mask * (0.55 + glyph * 0.4));
		s.albedo = mix(s.albedo, vec3(0.03, 0.025, 0.02), fade * mask * (0.55 + glyph * 0.4));
	]],
}
