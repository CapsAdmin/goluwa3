return {
	Source = [[
float r = length(uv * 2.0 - 1.0);
float v = smoothstep(0.55, 0.92, r) * (1.0 - smoothstep(0.92, 1.0, r));
return vec4(vec3(v), v);
]],
}
