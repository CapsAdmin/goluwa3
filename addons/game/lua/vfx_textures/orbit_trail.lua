return {
	Source = [[
float d = abs(uv.x * 2.0 - 1.0);
float edge = max(step(d, 1.0 / 256.0), exp(-d * 14.0) * (1.0 - d));
float y = clamp(uv.y, 0.0, 1.0);
float v = edge * pow(y, 1.5) * (1.0 - smoothstep(0.8, 1.0, y));
return vec4(vec3(v), v);
]],
}
