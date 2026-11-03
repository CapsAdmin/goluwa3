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
	float v = line(r - 0.58, 0.006) * 0.8;
	v += line(r - 0.22, 0.006) * 0.7;

	for (int i = 0; i < 6; i++) {
		float a0 = float(i) * 1.0471976;
		float a1 = float(i + 2) * 1.0471976;
		vec2 s0 = vec2(cos(a0), sin(a0)) * 0.58;
		vec2 d = vec2(cos(a1), sin(a1)) * 0.58 - s0;
		float h = clamp(dot(p - s0, d) / dot(d, d), 0.0, 1.0);
		v += line(length(p - s0 - d * h), 0.008);
	}

	v += exp(-r * r * 10.0) * 0.35;
	v = clamp(v, 0.0, 1.0) * (1.0 - smoothstep(0.62, 0.66, r));
	return vec4(vec3(v), v);
}
]],
}
