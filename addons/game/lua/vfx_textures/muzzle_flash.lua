return {
	Source = [[
vec2 p = uv * 2.0 - 1.0;
float r = length(p);
float a = atan(p.y, p.x);
float rays = pow(abs(cos(a * 2.5)), 10.0) * 0.7 + pow(abs(cos(a * 3.5 + 0.7)), 18.0) * 0.5;
float core = exp(-r * r * 14.0);
float star = rays * (1.0 - r) * (1.0 - r);
float v = clamp(core + star, 0.0, 1.0) * (1.0 - smoothstep(0.85, 1.0, r));
return vec4(vec3(v), v);
]],
}
