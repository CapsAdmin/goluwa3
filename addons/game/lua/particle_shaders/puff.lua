return {
	Sprite = "Sprite",
	Params = {
		{
			Name = "Sprite",
			Type = "texture",
			Default = "fire",
			Description = "the texture or flipbook drawn for every particle",
		},
		{
			Name = "Grow",
			Type = "float",
			Default = 2,
			Min = 0.1,
			Max = 6,
			Group = "Look",
			Description = "how fast the size follows its Size curve: 1 is linear, higher grows early and settles",
		},
		{
			Name = "ColorCurve",
			Type = "float",
			Default = 1,
			Min = 0.1,
			Max = 4,
			Group = "Look",
			Description = "how fast the color moves along its Color curve: below 1 early, above 1 late",
		},
		{
			Name = "FadeIn",
			Type = "float",
			Default = 0.05,
			Min = 0.001,
			Max = 1,
			Group = "Look",
			Description = "the fraction of the life it takes to fade in",
		},
		{
			Name = "FadeStart",
			Type = "float",
			Default = 0.4,
			Min = 0,
			Max = 1,
			Group = "Look",
			Description = "the fraction of the life where it starts to fade out",
		},
	},
	Source = [[
void update(emitters_t e, uint index, float dt, float t, inout Particle p) {
	p.width = emitter_size_at(e, index, p, 1.0 - pow(1.0 - t, Grow)) * p.sprite.w;
}

float visibility(emitters_t e, uint index, float t, Particle p) {
	return min(t / FadeIn, 1.0) * (1.0 - smoothstep(FadeStart, 1.0, t));
}

void shade(emitters_t e, uint index, float t, inout Particle p) {
	vec3 linear = emitter_color_at(e, index, p, t).rgb;
	vec3 curved = emitter_color_at(e, index, p, pow(t, ColorCurve)).rgb;
	p.radiance *= curved / max(linear, vec3(1e-4));
}
]],
	Preview = {Emitter = "puff_preview", Offset = {0, 0, 0}},
}
