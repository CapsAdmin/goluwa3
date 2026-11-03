return {
	Source = [[
float edge = 1.0 - abs(uv.x * 2.0 - 1.0);
edge = edge * edge * (3.0 - 2.0 * edge);
float v = edge * pow(clamp(uv.y, 0.0, 1.0), 1.5);
return vec4(vec3(v), v);
]],
}
