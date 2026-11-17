return {
	Size = 128,
	Source = [[
float across = abs(uv.y * 2.0 - 1.0);
float core = exp(-across * across * 10.0) * (1.0 - smoothstep(0.85, 1.0, across));
float v = core * pow(uv.x, 1.6) * (1.0 - smoothstep(0.94, 1.0, uv.x));
return vec4(vec3(v), v);
]],
}
