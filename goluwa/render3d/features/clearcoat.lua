-- a smooth film over the surface. the rain's film is one too, see surface_weather.lua
return {
	name = "clearcoat",
	category = "Clearcoat",
	params = {
		{name = "Clearcoat", default = 0.0, getter = "get_clearcoat"},
		{
			name = "ClearcoatRoughness",
			default = 0.05,
			requires = "Clearcoat",
			-- ggx alpha
			getter = "get_clearcoat_roughness",
			getter_expression = "v * v",
		},
	},
	fields = {
		{
			name = "clearcoat",
			kind = "unorm8",
			default = "0.0",
			material = "get_clearcoat()",
			readers = {"lighting", "reflections"},
		},
		{
			name = "clearcoat_roughness",
			member = "clearcoat_alpha",
			material = "get_clearcoat_roughness()",
			kind = "unorm8",
			default = "1.0",
			-- ggx alpha in, stored as the perceptual roughness
			encode = "sqrt(v)",
			decode = "v * v",
			readers = {"lighting", "reflections"},
		},
		{name = "clearcoat_rain", kind = "unorm8", default = "0.0", readers = {"lighting", "reflections"}},
		{name = "clearcoat_normal", kind = "octa", member = false, readers = {"lighting", "reflections"}},
	},
	surface_members = [[
		// the coat's normal without the rain's waves
		vec3 coat_smooth_N;
		vec3 coat_N;
	]],
	surface_default = [[
		s.coat_smooth_N = s.geometric_N;
		s.coat_N = s.geometric_N;
	]],
	weather = [[
		// the rain's film is a coat too, it takes the material's coat where that is thicker
		if (w.film > s.clearcoat) {
			s.clearcoat_alpha = mix(s.clearcoat_alpha, w.film_alpha, (w.film - s.clearcoat) / w.film);
			s.clearcoat = w.film;
		}

		// the snow covers the water
		s.clearcoat *= 1.0 - w.snow;
		s.clearcoat_rain = w.rain;
	]],
	gbuffer_write = [[
		set_clearcoat_normal(gbuffer_encode_normal(s.coat_smooth_N));
	]],
	surface_decode = [[
		s.coat_smooth_N = s.geometric_N;

		if (s.clearcoat > 0.0) s.coat_smooth_N = gbuffer_clearcoat_normal(uv);

		s.coat_N = s.coat_smooth_N;

		if (s.clearcoat > 0.0) {
			// meters a pixel covers on the surface. at a glancing angle it stretches along the view only,
			// across it the rings stay as sharp, so the mean of both
			float footprint = length(s.world_pos - lighting_data.camera_position.xyz) * 2.0 * lighting_data.inv_projection[1][1] / float(size.y) / sqrt(max(dot(s.geometric_N, s.V), 0.01));
			apply_rain_surface(s.world_pos, footprint, s.clearcoat_rain, s.coat_N, s.clearcoat_alpha);
		}
	]],
	direct_peak = [[
		if (s.clearcoat > 0.0) lobe_alpha_min = min(lobe_alpha_min, s.clearcoat_alpha);
	]],
	reflection = [[
		// a clearcoat is smoother than the surface under it, the sharp reflection is its. traced off the
		// flat film: the rain's waves on it are too fine and too quick for the reflections' resolution and
		// history, the lighting pass bends what this finds by them. far away they roughen the film
		if (gbuffer_clearcoat(gbuffer_pos) > 0.5) {
			float coat_alpha = gbuffer_clearcoat_roughness(gbuffer_pos);
			vec3 coat_N = gbuffer_clearcoat_normal(gbuffer_pos);
			vec3 rain_N = coat_N;
			apply_rain_surface(world_pos, footprint, gbuffer_clearcoat_rain(gbuffer_pos), rain_N, coat_alpha);
			N = coat_N;
			roughness = sqrt(coat_alpha);
		}
	]],
	direct_layer = [[
		if (s.clearcoat > 0.0) {
			float coat_NoL = saturate(dot(s.coat_N, L));
			float coat_alpha = s.clearcoat_alpha;
			float coat_energy = 1.0;

			if (type == 0) {
				coat_alpha = saturate(s.clearcoat_alpha + SUN_ANGULAR_RADIUS * 0.5);
				coat_energy = s.clearcoat_alpha / coat_alpha;
				coat_energy *= coat_energy;
			} else if (glow_widening > 0.0) {
				coat_alpha = saturate(s.clearcoat_alpha + glow_widening);
				coat_energy = s.clearcoat_alpha / coat_alpha;
				coat_energy *= coat_energy;
			}

			float Fc = F_SchlickScalar(CLEARCOAT_F0, LoH) * s.clearcoat;
			specular += D_GGXAlpha(coat_alpha, saturate(dot(s.coat_N, H))) * coat_energy * V_Kelemen(LoH) * Fc * radiance * coat_NoL;
			radiance *= 1.0 - Fc;
		}
	]],
	indirect_layer = [[
		if (s.clearcoat > 0.0) {
			// the coat reflects its share, the rest goes through to the surface and back out
			float coat_NdotV = max(dot(s.coat_N, s.V), 0.001);
			float coat_roughness = sqrt(clamp(s.clearcoat_alpha, 0.0, 1.0));
			float Fc = F_SchlickScalar(CLEARCOAT_F0, coat_NdotV) * s.clearcoat;
			// the reflections traced the flat film, the rain's waves bend what it found as they would bend the ray. by
			// their tilt on screen, less so further away where the rings are smaller
			vec3 tilt = mat3(lighting_data.view) * (s.coat_N - s.coat_smooth_N);
			vec2 reflection_uv = in_uv + vec2(tilt.x, -tilt.y) * (0.1 / max(length(lighting_data.camera_position.xyz - s.world_pos), 1.0));
			vec3 coat_reflection = get_reflection(s.coat_N, coat_roughness, s.V, s.world_pos, sky_visibility, irradiance, reflection_uv);
			ambient_diffuse *= 1.0 - Fc;
			ambient_specular = ambient_specular * (1.0 - Fc) + coat_reflection * Fc * SpecularOcclusion(coat_NdotV, ambient_occlusion, coat_roughness);
		}
	]],
}
