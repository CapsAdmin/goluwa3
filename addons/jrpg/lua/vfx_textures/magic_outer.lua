return {
	Source = [[
float line(float d, float w) {
	return 1.0 - smoothstep(0.0, w, abs(d));
}

float hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

vec4 shade(vec2 uv, vec3 _cube_dir) {
	vec2 p = uv * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x) / 6.2831853 + 0.5;
	float v = line(r - 0.97, 0.014);
	v += line(r - 0.91, 0.008);
	v += line(r - 0.64, 0.008);
	v += step(0.91, r) * step(r, 0.97) * smoothstep(0.38, 0.48, abs(fract(a * 72.0) - 0.5));
	float fa = fract(a * 32.0);
	float fr = fract((r - 0.68) / 0.06);
	float lit = step(0.45, hash(floor(a * 32.0) * 7.0 + floor((r - 0.68) / 0.06) * 31.0));
	v += step(0.68, r) * step(r, 0.86) * lit * step(0.18, fa) * step(fa, 0.82) * step(0.2, fr) * step(fr, 0.8) * 0.85;
	v = clamp(v, 0.0, 1.0) * (1.0 - smoothstep(0.98, 1.0, r));
	return vec4(vec3(v), v);
}
]],
}
