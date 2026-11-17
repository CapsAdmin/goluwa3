return {
	Source = [[
float across = abs(uv.y * 2.0 - 1.0);
float along = uv.x;
float width = sin(3.14159 * pow(along, 0.55)) * (0.55 + 0.45 * (1.0 - along));
float body = 1.0 - smoothstep(width * 0.35, width, across);
float v = body * smoothstep(0.0, 0.06, along) * (1.0 - smoothstep(0.7, 1.0, along));
return vec4(vec3(v), v);
]],
}
