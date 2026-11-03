return {
	Source = [[
float r = length(uv * 2.0 - 1.0);
return vec4(1.0, 1.0, 1.0, 1.0 - smoothstep(0.85, 1.0, r));
]],
}
