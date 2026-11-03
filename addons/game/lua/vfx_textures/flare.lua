return {
	Source = [[
vec2 p = abs(uv * 2.0 - 1.0);
float v = exp(-p.x * 30.0) * (1.0 - p.y) + exp(-p.y * 30.0) * (1.0 - p.x);
v = clamp(v * 0.7 + exp(-dot(p, p) * 10.0), 0.0, 1.0);
return vec4(vec3(v), v);
]],
}
