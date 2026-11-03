return {
	Source = [[
float along = clamp(uv.y, 0.0, 1.0);
float v = pow(uv.x, 2.5) * (1.0 - smoothstep(0.9, 1.0, uv.x)) * along * along;
return vec4(vec3(v), v);
]],
}
