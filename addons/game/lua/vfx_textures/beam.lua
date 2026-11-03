return {
	Source = [[
float edge = 1.0 - abs(uv.x * 2.0 - 1.0);
float v = edge * edge * (1.0 - smoothstep(0.6, 1.0, uv.y)) * smoothstep(0.0, 0.05, uv.y);
return vec4(vec3(v), v);
]],
}
