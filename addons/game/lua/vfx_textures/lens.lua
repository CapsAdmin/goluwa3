return {
	Source = [[
vec2 p = uv * 2.0 - 1.0;
float r = length(p);
vec3 n = normalize(vec3(p * (0.6 + 2.0 * r * r), 0.6));
return vec4(n * 0.5 + 0.5, 1.0 - smoothstep(0.85, 1.0, r));
]],
}
