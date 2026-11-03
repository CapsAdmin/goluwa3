return {
	Columns = 8,
	Rows = 8,
	TileSize = 256,
	Source = [[
float smoke_fbm(vec3 q, float phase, int octaves) {
	float sum = 0.0;
	float amplitude = 0.5;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		float a = phase * (i % 2 == 0 ? 1.0 : -1.0) + float(i) * 1.7;
		vec3 orbit = vec3(cos(a), sin(a), float(i) * 5.3) * 0.5;
		sum += value_noise3(q + orbit) * amplitude;
		norm += amplitude;
		amplitude *= 0.52;
		q *= 2.03;
	}

	return sum / norm;
}

float smoke_fine(vec2 p, float phase) {
	return smoke_fbm(vec3(p * 4.0, 9.0), phase, 4);
}

float smoke_height(vec2 p, float phase) {
	vec3 q = vec3(p * 1.3, 0.0);
	vec3 warp = vec3(smoke_fbm(q + vec3(7.1, 0.0, 0.0), phase, 2), smoke_fbm(q + vec3(0.0, 3.7, 0.0), phase, 2), 0.0);
	float n = smoke_fbm(q + (warp - 0.5) * 1.1, phase, 5);
	float fine = smoke_fine(p, phase);
	float r = length(p);
	float body = 1.0 - smoothstep(0.45, 1.0, r + (n - 0.5) * 1.0 + (fine - 0.5) * 0.3);
	body *= 1.0 - smoothstep(0.8, 0.98, r);
	return body * (0.1 + n * 1.5) * (0.7 + 0.6 * fine);
}

vec4 flipbook_frame(vec2 local, float phase, float frame) {
	vec2 p = local * 2.0 - 1.0;
	float h = smoke_height(p, phase);
	float heat = clamp(pow(smoothstep(0.12, 0.85, h), 1.7) * (0.65 + 0.7 * smoke_fine(p, phase)), 0.0, 1.0);
	return vec4(vec3(heat), heat);
}
]],
}
