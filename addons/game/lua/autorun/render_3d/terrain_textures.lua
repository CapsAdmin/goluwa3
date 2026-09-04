--[[
	Procedural terrain layer textures, registered as texture assets so any
	scene can use them:

		textures/terrain/<name>_albedo.lua  rgb albedo, roughness in alpha
		textures/terrain/<name>_normal.lua  tangent space normal, ambient occlusion in alpha

	Each layer defines a tileable relief function `layer_height(vec2 uv)` and
	an albedo body. Normals and ambient occlusion are derived from the relief.
	uv covers 0..1 over one tile, so a feature of period 8 repeats 8 times per
	tile. See goluwa/terrain/noise.lua for the tile_* functions. Cell patterns
	are always domain warped, plain voronoi reads as cracked mud or paving.

	Returns {name = {albedo = path, normal = path}} for every layer.
]]
local assets = import("goluwa/assets.lua")
local layer_texture = import("goluwa/terrain/layer_texture.lua")
local LAYERS = {}
-- 3 meter tile: low, irregular tufts with fine blade streaks between them
LAYERS.grass = {
	Depth = 0.04,
	Height = [=[
		float grass_tufts(vec2 uv) {
			vec2 w = tile_warp(uv + vec2(0.13, 0.41), 5.0, 0.05);
			vec3 c = tile_cells(w, 16.0);
			float present = smoothstep(0.25, 0.6, tile_hash(c.yz + 3.0));
			float size = mix(0.5, 0.95, tile_hash(c.yz + 9.0));
			float tuft = 1.0 - smoothstep(0.1, size, c.x);
			return tuft * tuft * present;
		}

		// blades lean in locally consistent directions
		float grass_blades(vec2 uv) {
			float a = tile_fbm(uv, vec2(24.0, 96.0), 3, 0.5);
			float b = tile_fbm(uv + 0.37, vec2(96.0, 24.0), 3, 0.5);
			float c = tile_fbm(vec2(uv.x + uv.y, uv.y - uv.x) * 0.5 + 0.61, vec2(24.0, 96.0), 3, 0.5);
			float mixer = tile_fbm(uv + 0.71, 4.0, 2, 0.5);
			float mixer2 = tile_fbm(uv + 2.31, 5.0, 2, 0.5);
			return mix(mix(a, b, smoothstep(0.35, 0.65, mixer)), c, smoothstep(0.4, 0.7, mixer2));
		}

		float layer_height(vec2 uv) {
			float tufts = grass_tufts(uv);
			float blades = grass_blades(uv);
			float fine = tile_fbm(uv + 2.7, 200.0, 2, 0.5);
			float ground = tile_fbm(uv, 4.0, 3, 0.5);
			return tufts * 0.35 + blades * 0.4 + fine * 0.1 + ground * 0.15;
		}
	]=],
	Albedo = [=[
		float h = layer_height(uv);
		float tufts = grass_tufts(uv);
		float blades = grass_blades(uv);
		float fine = tile_fbm(uv + 2.7, 200.0, 2, 0.5);
		float patches = tile_fbm(uv + 0.7, 3.0, 4, 0.5);
		float dry = smoothstep(0.55, 0.78, tile_fbm(uv + 2.3, 4.0, 4, 0.55));
		float thin = smoothstep(0.55, 0.75, tile_fbm(uv * 2.0 + 5.9, 7.0, 3, 0.5));
		vec3 green = vec3(0.095, 0.14, 0.05);
		vec3 lush = vec3(0.075, 0.135, 0.04);
		vec3 straw = vec3(0.24, 0.21, 0.11);
		vec3 soil = vec3(0.10, 0.08, 0.05);
		vec3 col = mix(green, lush, smoothstep(0.35, 0.65, patches));
		col = mix(col, straw, dry * 0.55);
		col *= mix(0.7, 1.1, blades);
		col *= mix(0.9, 1.1, fine);
		col *= mix(0.75, 1.1, h);
		col = mix(col, soil, thin * (1.0 - tufts) * 0.6);
		col = mix(col, soil * 0.6, (1.0 - smoothstep(0.08, 0.3, h)) * 0.5);
		float roughness = 0.93 - tufts * 0.06;
		return vec4(col, roughness);
	]=],
}
-- 3 meter tile: packed soil with a few embedded stones
LAYERS.dirt = {
	Depth = 0.07,
	Height = [=[
		// returns stone coverage 0..1 and the stone id
		vec3 dirt_stones(vec2 uv) {
			vec2 w = tile_warp(uv + 0.5, 6.0, 0.03);
			vec3 c = tile_cells(w, 28.0);
			float present = step(0.88, tile_hash(c.yz + 3.0));
			float size = mix(0.1, 0.28, tile_hash(c.yz + 7.0));
			float shape = 1.0 - smoothstep(size * 0.5, size, c.x);
			return vec3(sqrt(clamp(shape, 0.0, 1.0)) * present, c.yz);
		}

		float layer_height(vec2 uv) {
			float base = tile_fbm(uv, 12.0, 4, 0.5);
			float lumps = tile_fbm(uv + 1.3, 28.0, 3, 0.55);
			float stones = dirt_stones(uv).x;
			float grit = tile_fbm(uv + 5.1, 120.0, 3, 0.5);
			float h = base * 0.3 + lumps * 0.3 + grit * 0.3;
			h = max(h, 0.4 + stones * 0.2);
			return h + 0.05;
		}
	]=],
	Albedo = [=[
		float h = layer_height(uv);
		vec3 stones = dirt_stones(uv);
		float wet = tile_fbm(uv + 1.9, 10.0, 4, 0.5);
		float lumps = tile_fbm(uv + 1.3, 28.0, 3, 0.55);
		float grit = tile_fbm(uv + 5.1, 120.0, 3, 0.5);
		vec3 soil = vec3(0.26, 0.19, 0.12);
		vec3 dark = vec3(0.18, 0.135, 0.09);
		vec3 stone = mix(vec3(0.25, 0.22, 0.19), vec3(0.17, 0.15, 0.13), tile_hash(stones.yz + 11.0));
		vec3 col = mix(dark, soil, smoothstep(0.3, 0.8, wet));
		col *= mix(0.85, 1.1, grit);
		col *= mix(0.9, 1.08, lumps);
		col = mix(col, stone, stones.x * 0.7);
		col *= mix(0.75, 1.08, h);
		float roughness = 0.94 - stones.x * 0.25;
		return vec4(col, roughness);
	]=],
}
-- 11 meter tile: weathered blocks with strata, cracks only partly exposed
LAYERS.rock = {
	Depth = 0.06,
	Height = [=[
		vec2 rock_warp(vec2 uv) {
			return tile_warp(uv + 0.1, 3.0, 0.07);
		}

		float rock_cracks(vec2 uv) {
			vec2 w = rock_warp(uv);
			vec2 big = tile_cells2(w, 4.0);
			vec2 small = tile_cells2(tile_warp(uv + 0.6, 5.0, 0.04), 10.0);
			float crack_big = 1.0 - smoothstep(0.0, 0.03, big.y - big.x);
			float crack_small = 1.0 - smoothstep(0.0, 0.02, small.y - small.x);
			float mask_big = smoothstep(0.45, 0.7, tile_fbm(uv + 7.7, 5.0, 3, 0.5));
			float mask_small = smoothstep(0.55, 0.75, tile_fbm(uv + 2.2, 4.0, 3, 0.5));
			return max(crack_big * mask_big, crack_small * mask_small * 0.5);
		}

		float rock_blocks(vec2 uv) {
			vec3 big = tile_cells(rock_warp(uv), 4.0);
			vec3 small = tile_cells(tile_warp(uv + 0.6, 5.0, 0.04), 10.0);
			return tile_hash(big.yz + 5.0) * 0.7 + tile_hash(small.yz + 5.0) * 0.3;
		}

		float rock_strata(vec2 uv) {
			float warp = tile_gfbm(uv + 0.9, 3.0, 3, 0.5) * 0.09;
			float band = sin((uv.y + warp + uv.x * 0.2) * 6.2831853 * 8.0);
			return smoothstep(-0.7, 0.7, band);
		}

		float layer_height(vec2 uv) {
			float cracks = rock_cracks(uv);
			float blocks = rock_blocks(uv);
			float strata = rock_strata(uv);
			float chips = tile_ridged(uv + 3.7, 14.0, 4, 0.5);
			float lumps = tile_gfbm(uv + 5.5, 2.0, 3, 0.5) * 0.5 + 0.5;
			float bumps = tile_fbm(uv + 6.3, 30.0, 3, 0.5);
			float grain = tile_fbm(uv + 8.1, 160.0, 2, 0.5);
			float h = 0.1 + lumps * 0.3 + blocks * 0.15 + strata * 0.04 + chips * 0.15 + bumps * 0.18 + grain * 0.06;
			return h - cracks * 0.15;
		}
	]=],
	Albedo = [=[
		float h = layer_height(uv);
		float cracks = rock_cracks(uv);
		float blocks = rock_blocks(uv);
		float strata = rock_strata(uv);
		float grain = tile_fbm(uv + 8.1, 160.0, 2, 0.5);
		float weather = tile_fbm(uv + 4.4, 5.0, 4, 0.5);
		float stain = smoothstep(0.55, 0.8, tile_fbm(uv * 3.0 + 1.1, 6.0, 4, 0.5));
		float lichen = smoothstep(0.7, 0.82, tile_fbm(uv * 2.0 + 6.4, 13.0, 4, 0.5));
		float speck = step(0.93, tile_noise(uv * 400.0, 400.0));
		vec3 grey = vec3(0.21, 0.205, 0.20);
		vec3 warm = vec3(0.26, 0.225, 0.18);
		vec3 dark = vec3(0.13, 0.125, 0.12);
		vec3 col = mix(grey, warm, smoothstep(0.3, 0.7, weather));
		col = mix(col, dark, strata * 0.3);
		col = mix(col, dark * 0.8, stain * 0.5);
		col *= 0.9 + blocks * 0.2;
		col *= mix(0.9, 1.1, grain);
		col = mix(col, vec3(0.34, 0.36, 0.2), lichen * 0.4);
		col = mix(col, vec3(0.32), speck * 0.5);
		col *= mix(0.7, 1.08, h);
		col *= 1.0 - cracks * 0.3;
		float roughness = 0.84 - h * 0.1 + lichen * 0.1;
		return vec4(col, roughness);
	]=],
}
-- 7 meter tile: wind packed drifts with meandering ripples and a grainy crust
LAYERS.snow = {
	Depth = 0.045,
	Height = [=[
		float snow_ripples(vec2 uv) {
			float warp = tile_gfbm(uv + 0.4, 2.0, 3, 0.5) * 0.14;
			float r = sin((uv.x + warp + uv.y * 0.2) * 6.2831853 * 11.0);
			float mask = smoothstep(0.3, 0.6, tile_fbm(uv + 3.3, 3.0, 3, 0.5));
			return (r * 0.5 + 0.5) * mask;
		}

		float layer_height(vec2 uv) {
			float drifts = tile_gfbm(uv, 3.0, 4, 0.5) * 0.5 + 0.5;
			float ripples = snow_ripples(uv);
			float crust = tile_fbm(uv + 8.2, 48.0, 3, 0.5);
			float lumps = 1.0 - smoothstep(0.0, 0.5, tile_cells(tile_warp(uv + 0.8, 4.0, 0.03), 22.0).x);
			float lump_mask = smoothstep(0.5, 0.7, tile_fbm(uv + 1.4, 4.0, 3, 0.5));
			return drifts * 0.6 + ripples * 0.12 + crust * 0.15 + lumps * lump_mask * 0.13;
		}
	]=],
	Albedo = [=[
		float h = layer_height(uv);
		float crust = tile_fbm(uv + 8.2, 48.0, 3, 0.5);
		float sparkle = step(0.988, tile_hash(floor(uv * 512.0)));
		vec3 shadowed = vec3(0.76, 0.81, 0.90);
		vec3 lit = vec3(0.90, 0.92, 0.95);
		vec3 col = mix(shadowed, lit, smoothstep(0.2, 0.8, h));
		col *= mix(0.96, 1.02, crust);
		col += sparkle * 0.06;
		float roughness = 0.6 + (1.0 - h) * 0.2;
		return vec4(col, roughness);
	]=],
}
local terrain_textures = {}

for name, config in pairs(LAYERS) do
	local albedo_path = "textures/terrain/" .. name .. "_albedo.lua"
	local normal_path = "textures/terrain/" .. name .. "_normal.lua"

	assets.RegisterVirtualTexture(albedo_path, function()
		return layer_texture.BakeAlbedo(config)
	end)

	assets.RegisterVirtualTexture(normal_path, function()
		return layer_texture.BakeNormal(config)
	end)

	terrain_textures[name] = {albedo = albedo_path, normal = normal_path}
end

return terrain_textures
