-- the rules that choose a terrain layer by the ground at a pixel (the TerrainLayerSlope* and TerrainLayerCover* values), shared by
-- the model pipeline and scatter so that what grows on a layer is where the layer shows
return [[
	// where a layer may be by the slope of the ground, 0 flat to 1 a wall: from slope_min to slope_max, fading over blend
	vec4 get_terrain_slope_mask(float steepness, vec4 slope_min, vec4 slope_max, vec4 blend) {
		vec4 b = max(blend, vec4(0.0001));
		return smoothstep(slope_min, slope_min + b, vec4(steepness)) * (vec4(1.0) - smoothstep(slope_max - b, slope_max, vec4(steepness)));
	}

	// how much a layer covers the ground at a pixel (snow): the steeper the ground may be the higher it is, from
	// cover_slope * ((y - start) / range)^power, and it covers what is flatter than that, fading over blend. a layer
	// with a cover_slope of 0 is not a covering layer
	vec4 get_terrain_cover(float steepness, float height, vec4 cover_slope, vec4 start, vec4 range, vec4 power, vec4 blend) {
		vec4 amount = pow(clamp((vec4(height) - start) / max(range, vec4(0.001)), vec4(0.0), vec4(1.0)), power);
		vec4 cover = clamp((cover_slope * amount - vec4(steepness)) / max(blend, vec4(0.0001)), vec4(0.0), vec4(1.0));
		return cover * vec4(greaterThan(cover_slope, vec4(0.0)));
	}

	// the baked weights of layers 1 to 4 with the rules applied, adding up to one (or zero)
	vec4 apply_terrain_layer_rules(vec4 weights, float steepness, float height, vec4 slope_min, vec4 slope_max, vec4 slope_blend, vec4 cover_slope, vec4 cover_start, vec4 cover_range, vec4 cover_power, vec4 cover_blend) {
		weights *= get_terrain_slope_mask(steepness, slope_min, slope_max, slope_blend);
		vec4 cover = get_terrain_cover(steepness, height, cover_slope, cover_start, cover_range, cover_power, cover_blend);
		weights *= vec4(lessThanEqual(cover_slope, vec4(0.0)));
		float sum = dot(weights, vec4(1.0));
		weights = sum > 0.0001 ? weights / sum : vec4(0.0);
		float cover_sum = dot(cover, vec4(1.0));

		if (cover_sum > 0.0001) {
			float covered = max(max(cover.x, cover.y), max(cover.z, cover.w));
			weights = weights * (1.0 - covered) + cover * (covered / cover_sum);
		}

		return weights;
	}
]]
