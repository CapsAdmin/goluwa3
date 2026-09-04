--[[
	GLSL noise snippets shared by terrain sources and layer texture bakes.

	WORLD is meant for world-space sampling (heights, splat masks): gradient
	noise, fbm, ridged multifractal and cellular noise, all non-tiling.

	TILE is meant for texture bakes: the same kinds of noise, but they repeat
	every `period` units so a texture baked over uv 0..1 tiles seamlessly.
]]
local noise = {}
noise.WORLD = [=[
const mat2 PN_ROT = mat2(0.80, 0.60, -0.60, 0.80);

vec2 pn_hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float pn_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(dot(pn_hash(i), f), dot(pn_hash(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
		mix(dot(pn_hash(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)), dot(pn_hash(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x),
		u.y
	) * 1.6;
}

float pn_fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		sum += pn_noise(p) * amp;
		norm += amp;
		p = PN_ROT * p * 2.02 + vec2(1.7, 9.2);
		amp *= 0.5;
	}

	return sum / norm;
}

float pn_ridged(vec2 p, int octaves, float offset, float gain) {
	float sum = 0.0;
	float amp = 0.5;
	float weight = 1.0;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		float n = offset - abs(pn_noise(p));
		n = n * n * weight;
		weight = clamp(n * gain, 0.0, 1.0);
		sum += n * amp;
		norm += amp;
		p = PN_ROT * p * 2.1 + vec2(3.1, -4.7);
		amp *= 0.5;
	}

	return sum / norm;
}

// fbm and ridged variants whose octaves fade out as their wavelength approaches
// the bake sample step, so coarse LOD bakes do not alias into per texel noise.
// `wavelength` is the world size of the first octave, `step` the sample spacing.
float pn_octave_fade(float wavelength, float step) {
	return 1.0 - smoothstep(wavelength * 0.2, wavelength * 0.5, step);
}

float pn_fbm_lod(vec2 p, int octaves, float wavelength, float step) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		sum += pn_noise(p) * amp * pn_octave_fade(wavelength, step);
		norm += amp;
		p = PN_ROT * p * 2.02 + vec2(1.7, 9.2);
		amp *= 0.5;
		wavelength *= 0.5;
	}

	return sum / norm;
}

float pn_ridged_lod(vec2 p, int octaves, float offset, float gain, float wavelength, float step) {
	float sum = 0.0;
	float amp = 0.5;
	float weight = 1.0;
	float norm = 0.0;

	for (int i = 0; i < octaves; i++) {
		float n = offset - abs(pn_noise(p));
		n = n * n * weight;
		weight = clamp(n * gain, 0.0, 1.0);
		sum += n * amp * pn_octave_fade(wavelength, step);
		norm += amp;
		p = PN_ROT * p * 2.1 + vec2(3.1, -4.7);
		amp *= 0.5;
		wavelength *= 0.5;
	}

	return sum / norm;
}

float pn_cells(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float best = 8.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec2 point = cell + pn_hash(i + cell) * 0.5 + 0.5;
			best = min(best, dot(point - f, point - f));
		}
	}

	return sqrt(best);
}
]=]
noise.TILE = [=[
float tile_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec2 tile_hash2(vec2 p) {
	return vec2(tile_hash(p), tile_hash(p + 17.0));
}

// value noise, repeats every `period` cells (per axis)
float tile_noise(vec2 p, vec2 period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = tile_hash(mod(i, period));
	float b = tile_hash(mod(i + vec2(1.0, 0.0), period));
	float c = tile_hash(mod(i + vec2(0.0, 1.0), period));
	float d = tile_hash(mod(i + vec2(1.0, 1.0), period));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float tile_noise(vec2 p, float period) {
	return tile_noise(p, vec2(period));
}

// gradient noise in -1..1, repeats every `period` cells
float tile_gradient(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 ga = tile_hash2(mod(i, period)) * 2.0 - 1.0;
	vec2 gb = tile_hash2(mod(i + vec2(1.0, 0.0), period)) * 2.0 - 1.0;
	vec2 gc = tile_hash2(mod(i + vec2(0.0, 1.0), period)) * 2.0 - 1.0;
	vec2 gd = tile_hash2(mod(i + vec2(1.0, 1.0), period)) * 2.0 - 1.0;
	return mix(
		mix(dot(ga, f), dot(gb, f - vec2(1.0, 0.0)), u.x),
		mix(dot(gc, f - vec2(0.0, 1.0)), dot(gd, f - vec2(1.0, 1.0)), u.x),
		u.y
	) * 1.4;
}

// uv is 0..1, result is 0..1, period may differ per axis for streaky noise
float tile_fbm(vec2 uv, vec2 period, int octaves, float gain) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	vec2 p = uv * period;

	for (int i = 0; i < octaves; i++) {
		sum += tile_noise(p, period) * amp;
		norm += amp;
		p *= 2.0;
		period *= 2.0;
		amp *= gain;
	}

	return sum / norm;
}

float tile_fbm(vec2 uv, float period, int octaves, float gain) {
	return tile_fbm(uv, vec2(period), octaves, gain);
}

// offsets uv by a tileable noise field, so cell and band patterns lose their regularity
vec2 tile_warp(vec2 uv, float period, float amount) {
	return uv + vec2(tile_gradient(uv * period, period), tile_gradient(uv * period + vec2(37.0, 11.0), period)) * amount;
}

// gradient fbm, result is roughly -1..1
float tile_gfbm(vec2 uv, float period, int octaves, float gain) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	vec2 p = uv * period;

	for (int i = 0; i < octaves; i++) {
		sum += tile_gradient(p, period) * amp;
		norm += amp;
		p *= 2.0;
		period *= 2.0;
		amp *= gain;
	}

	return sum / norm;
}

// result is 0..1 with sharp creases at 1
float tile_ridged(vec2 uv, float period, int octaves, float gain) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	float weight = 1.0;
	vec2 p = uv * period;

	for (int i = 0; i < octaves; i++) {
		float n = 1.0 - abs(tile_gradient(p, period));
		n = n * n * weight;
		weight = clamp(n * 2.0, 0.0, 1.0);
		sum += n * amp;
		norm += amp;
		p *= 2.0;
		period *= 2.0;
		amp *= gain;
	}

	return sum / norm;
}

// distance to the closest feature point (0..~1) and the id of that cell
vec3 tile_cells(vec2 uv, float period) {
	vec2 p = uv * period;
	vec2 i = floor(p);
	vec2 f = fract(p);
	float best = 8.0;
	vec2 best_id = vec2(0.0);

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec2 wrapped = mod(i + cell, period);
			vec2 point = cell + tile_hash2(wrapped);
			float d = dot(point - f, point - f);

			if (d < best) {
				best = d;
				best_id = wrapped;
			}
		}
	}

	return vec3(sqrt(best), best_id);
}

// distance to the closest and second closest feature point
vec2 tile_cells2(vec2 uv, float period) {
	vec2 p = uv * period;
	vec2 i = floor(p);
	vec2 f = fract(p);
	float best = 8.0;
	float second = 8.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec2 point = cell + tile_hash2(mod(i + cell, period));
			float d = dot(point - f, point - f);

			if (d < best) {
				second = best;
				best = d;
			} else if (d < second) {
				second = d;
			}
		}
	}

	return sqrt(vec2(best, second));
}
]=]
return noise
