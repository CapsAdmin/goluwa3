return {
	Source = [[
float line(float d, float w) {
	return 1.0 - smoothstep(0.0, w, abs(d));
}

float hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

vec4 shade(vec2 uv, vec3 _cube_dir) {
	vec2 p = vec2(uv.x * 2.0 - 1.0, uv.y);
	float ax = abs(p.x);
	float width = pow(max(sin(3.14159 * pow(clamp(p.y, 0.0, 1.0), 0.7)), 0.0), 0.6) * 0.92;
	float ragged = width * (0.82 + 0.18 * hash(floor(p.y * 48.0) + (p.x > 0.0 ? 17.0 : 0.0)));
	float inside = step(ax, ragged);
	float spine = step(ax, 0.045);
	float barb = abs(fract(p.y * 30.0 - ax * 6.0) - 0.5) * 2.0;
	float shade = mix(0.78, 1.0, barb);
	return vec4(vec3(mix(shade, 1.0, spine)), inside);
}
]],
}
