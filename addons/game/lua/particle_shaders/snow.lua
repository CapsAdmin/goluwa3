return {
	Sprite = "Flake",
	Params = {
		{
			Name = "Flake",
			Type = "texture",
			Default = "snowflake",
			Description = "the texture drawn for every particle",
		},
		{
			Name = "Sway",
			Type = "float",
			Default = 0.35,
			Min = 0,
			Max = 3,
			Group = "Motion",
			Description = "sideways speed of the flutter in m/s",
		},
		{
			Name = "SwayRate",
			Type = "float",
			Default = 1.2,
			Min = 0.1,
			Max = 6,
			Group = "Motion",
			Description = "how fast the flutter turns, in turns per second",
		},
		{
			Name = "Wind",
			Type = "vec3",
			Default = {0.05, 0, 0},
			Group = "Motion",
			Description = "steady drift added to the flutter",
		},
		{
			Name = "Tumble",
			Type = "float",
			Default = 1.5,
			Min = 0,
			Max = 10,
			Group = "Look",
			Description = "how fast flakes spin, in radians per second",
		},
		{
			Name = "SizeVariation",
			Type = "float",
			Default = 0.5,
			Min = 0,
			Max = 1,
			Group = "Look",
			Description = "how much smaller than Size the smallest flakes are",
		},
	},
	Source = [[
void spawn(emitters_t e, uint index, uint generation, inout Particle p) {
	float h = fract(sin(float(index) * 91.7 + float(generation) * 13.1) * 43758.5453);
	p.sprite.w = 1.0 - SizeVariation * h;
	p.sprite.z = h;
}

void update(emitters_t e, uint index, float dt, float t, inout Particle p) {
	float phase = p.age * SwayRate * 6.2831853 + p.sprite.z * 6.2831853;
	vec2 target = vec2(sin(phase), cos(phase * 0.83 + 1.3)) * Sway + Wind.xz;
	p.velocity.xz += (target - p.velocity.xz) * min(dt * 2.0, 1.0);
	p.sprite.x += Tumble * (p.sprite.z - 0.5) * 2.0 * dt;
}
]],
	Preview = {Emitter = "shader_preview", Offset = {0, 1, 0}},
}
