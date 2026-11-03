return {
	Source = [[
float r = length(uv * 2.0 - 1.0);
float v = exp(-r * r * 5.0) * (1.0 - smoothstep(0.75, 1.0, r));
return vec4(vec3(v), v);
]],
}
