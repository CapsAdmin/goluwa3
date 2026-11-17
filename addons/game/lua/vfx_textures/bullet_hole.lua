return {
	Size = 128,
	Source = [[
vec2 p = uv * 2.0 - 1.0;
float r = length(p);
float a = atan(p.y, p.x);
float jag = 0.07 * sin(a * 7.0) + 0.05 * sin(a * 13.0 + 1.3) + 0.03 * sin(a * 23.0 + 2.1);
float hole = 1.0 - smoothstep(0.16 + jag * 0.5, 0.24 + jag * 0.5, r);
float scorch = (1.0 - smoothstep(0.25 + jag, 0.9, r)) * (0.75 + 0.25 * sin(a * 31.0 + r * 9.0));
float alpha = clamp(max(hole, scorch * 0.8), 0.0, 1.0);
vec3 color = mix(vec3(0.16, 0.15, 0.14), vec3(0.015), hole);
return vec4(color, alpha);
]],
}
