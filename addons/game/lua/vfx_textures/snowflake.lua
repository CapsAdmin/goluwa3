return {
	Source = [[
vec2 p = uv * 2.0 - 1.0;
float r = length(p);
float sector = 6.2831853 / 6.0;
float f = abs(mod(atan(p.y, p.x) + sector * 0.5, sector) - sector * 0.5);
vec2 q = vec2(cos(f), sin(f)) * r;
float arm = smoothstep(0.07, 0.02, abs(q.y)) * smoothstep(0.95, 0.75, q.x) * step(0.0, q.x);
float branch = smoothstep(0.06, 0.015, abs(q.y - (q.x - 0.42) * 0.85)) * step(0.25, q.x) * step(q.x, 0.7);
float core = smoothstep(0.2, 0.05, r);
float v = clamp(arm + branch * 0.8 + core, 0.0, 1.0) * (1.0 - smoothstep(0.9, 1.0, r));
return vec4(vec3(1.0), v);
]],
}
