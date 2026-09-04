local Texture = import("goluwa/render/texture.lua")
local layer_textures = {}
local TEXTURE_SIZE = 512
local cache = {}
local HEADER = [=[
float tile_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float tile_noise(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = tile_hash(mod(i, period));
	float b = tile_hash(mod(i + vec2(1.0, 0.0), period));
	float c = tile_hash(mod(i + vec2(0.0, 1.0), period));
	float d = tile_hash(mod(i + vec2(1.0, 1.0), period));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float tile_fbm(vec2 uv, float period, int octaves, float gain) {
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

float tile_ridged(vec2 uv, float period, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	vec2 p = uv * period;

	for (int i = 0; i < octaves; i++) {
		float n = 1.0 - abs(tile_noise(p, period) * 2.0 - 1.0);
		sum += n * n * amp;
		norm += amp;
		p *= 2.0;
		period *= 2.0;
		amp *= 0.55;
	}

	return sum / norm;
}

float tile_cells(vec2 uv, float period) {
	vec2 p = uv * period;
	vec2 i = floor(p);
	vec2 f = fract(p);
	float best = 8.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec2 wrapped = mod(i + cell, period);
			vec2 point = cell + vec2(tile_hash(wrapped), tile_hash(wrapped + 17.0));
			best = min(best, dot(point - f, point - f));
		}
	}

	return sqrt(best);
}

vec3 tile_normal(vec2 uv, float strength, float texel) {
	float hl = layer_height(uv - vec2(texel, 0.0));
	float hr = layer_height(uv + vec2(texel, 0.0));
	float hd = layer_height(uv - vec2(0.0, texel));
	float hu = layer_height(uv + vec2(0.0, texel));
	return normalize(vec3((hl - hr) * strength, (hd - hu) * strength, texel * 2.0));
}
]=]
local LAYERS = {
	grass = {
		height = [=[
			float layer_height(vec2 uv) {
				float clumps = tile_fbm(uv, 12.0, 4, 0.55);
				float blades = tile_ridged(uv + 0.31, 64.0, 3);
				float fine = tile_fbm(uv + 2.7, 128.0, 2, 0.5);
				return clumps * 0.4 + blades * 0.4 + fine * 0.2;
			}
		]=],
		albedo = [=[
			float h = layer_height(uv);
			float macro = tile_fbm(uv + 0.7, 4.0, 3, 0.5);
			float dry = tile_fbm(uv + 2.3, 7.0, 3, 0.5);
			vec3 lush = vec3(0.16, 0.30, 0.09);
			vec3 pale = vec3(0.34, 0.38, 0.14);
			vec3 col = mix(lush, pale, smoothstep(0.35, 0.75, dry));
			col *= mix(0.72, 1.18, h);
			col *= mix(0.85, 1.1, macro);
			float roughness = 0.88 - h * 0.1;
			return vec4(col, roughness);
		]=],
		normal_strength = 3.0,
	},
	dirt = {
		height = [=[
			float layer_height(vec2 uv) {
				float base = tile_fbm(uv, 6.0, 5, 0.5);
				float pebbles = (1.0 - smoothstep(0.05, 0.22, tile_cells(uv + 0.5, 40.0))) * step(0.55, tile_noise(uv * 40.0 + 3.0, 40.0));
				float grit = tile_fbm(uv + 5.1, 64.0, 3, 0.5);
				return base * 0.65 + pebbles * 0.15 + grit * 0.2;
			}
		]=],
		albedo = [=[
			float h = layer_height(uv);
			float wet = tile_fbm(uv + 1.9, 5.0, 3, 0.5);
			float pebbles = (1.0 - smoothstep(0.05, 0.22, tile_cells(uv + 0.5, 40.0))) * step(0.55, tile_noise(uv * 40.0 + 3.0, 40.0));
			vec3 soil = vec3(0.30, 0.22, 0.14);
			vec3 dark = vec3(0.17, 0.13, 0.09);
			vec3 stone = vec3(0.33, 0.30, 0.26);
			vec3 col = mix(dark, soil, smoothstep(0.3, 0.7, wet));
			col = mix(col, stone, pebbles * 0.5);
			col *= mix(0.8, 1.15, h);
			float roughness = 0.92 - pebbles * 0.25;
			return vec4(col, roughness);
		]=],
		normal_strength = 2.5,
	},
	rock = {
		height = [=[
			float layer_height(vec2 uv) {
				float strata = tile_ridged(vec2(uv.x * 0.35, uv.y) + 0.2, 10.0, 4);
				float cracks = smoothstep(0.0, 0.12, tile_cells(uv + 0.1, 7.0));
				float chips = tile_fbm(uv + 3.7, 40.0, 3, 0.5);
				return strata * 0.55 * cracks + chips * 0.25 + cracks * 0.2;
			}
		]=],
		albedo = [=[
			float h = layer_height(uv);
			float strata = tile_fbm(vec2(uv.x * 0.2, uv.y * 1.6) + 0.9, 8.0, 3, 0.5);
			float lichen = smoothstep(0.62, 0.78, tile_fbm(uv + 4.4, 14.0, 4, 0.5));
			vec3 grey = vec3(0.24, 0.235, 0.23);
			vec3 warm = vec3(0.31, 0.27, 0.22);
			vec3 col = mix(grey, warm, strata);
			col = mix(col, vec3(0.34, 0.40, 0.22), lichen * 0.5);
			col *= mix(0.62, 1.15, h);
			float roughness = 0.78 - h * 0.12;
			return vec4(col, roughness);
		]=],
		normal_strength = 4.0,
	},
	snow = {
		height = [=[
			float layer_height(vec2 uv) {
				float drifts = tile_fbm(uv, 3.0, 4, 0.5);
				float crust = tile_fbm(uv + 8.2, 32.0, 2, 0.5);
				return drifts * 0.8 + crust * 0.2;
			}
		]=],
		albedo = [=[
			float h = layer_height(uv);
			float sparkle = step(0.985, tile_hash(floor(uv * 512.0)));
			vec3 col = mix(vec3(0.80, 0.84, 0.90), vec3(0.93, 0.95, 0.98), h);
			col += sparkle * 0.08;
			float roughness = 0.55 + (1.0 - h) * 0.2;
			return vec4(col, roughness);
		]=],
		normal_strength = 1.2,
	},
}

local function make_texture()
	return Texture.New{
		width = TEXTURE_SIZE,
		height = TEXTURE_SIZE,
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "repeat",
			wrap_t = "repeat",
		},
	}
end

function layer_textures.Get(name)
	if cache[name] then return cache[name] end

	local layer = LAYERS[name]

	if not layer then error("unknown terrain layer texture: " .. tostring(name)) end

	local header = HEADER:gsub("vec3 tile_normal", layer.height .. "\nvec3 tile_normal")
	local albedo = make_texture()
	albedo:Shade(layer.albedo, {header = header})
	local normal = make_texture()
	normal:Shade(
		string.format(
			[=[
			vec3 n = tile_normal(uv, %f, %f);
			float h = layer_height(uv);
			float ao = mix(0.55, 1.0, smoothstep(0.0, 0.7, h));
			return vec4(n * 0.5 + 0.5, ao);
		]=],
			layer.normal_strength,
			1 / TEXTURE_SIZE
		),
		{header = header}
	)
	cache[name] = {albedo = albedo, normal = normal}
	return cache[name]
end

function layer_textures.GetNames()
	local names = {}

	for name in pairs(LAYERS) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

return layer_textures
