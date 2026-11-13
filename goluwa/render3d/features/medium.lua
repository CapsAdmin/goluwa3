local medium_common = import("goluwa/render3d/medium_common.lua")
return {
	name = "medium",
	category = "Medium",
	params = {
		{
			name = "MediumSlot",
			default = 0.0,
			storable = false,
			getter = "get_medium_slot",
			callback = "InvalidateRayMaterial",
		},
		{name = "MediumCover", default = 0.0, getter = "get_medium_cover"},
		{name = "MediumPorosity", default = 0.0, callback = "InvalidateRayMaterial"},
		{name = "MediumThickness", default = 0.0, callback = "InvalidateRayMaterial"},
		{
			name = "MediumPorosityFromAlbedo",
			default = 0.0,
			callback = "InvalidateRayMaterial",
		},
		{name = "MediumPorosityExposure", default = 0.0, getter = "get_medium_exposure"},
	},
	fields = {
		{
			name = "medium_slot",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_medium_slot()",
			encode = "v / 15.0",
			decode = "floor(v * 15.0 + 0.5)",
			max = 15,
			readers = {"lighting"},
		},
		{
			name = "medium_porosity",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "factor_model.MediumPorosityFromAlbedo > 0.0 ? 1.0 : floor(min(factor_model.MediumPorosity, 1.0) * 14.0 + 0.5) / 15.0",
			readers = {"lighting"},
		},
		{
			name = "medium_mode",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_medium_cover() > 0.0 ? 1.0 : (factor_model.MediumThickness > 0.0 ? 7.0 / 15.0 : floor(min(get_medium_exposure(), 0.9) / 0.9 * 6.0 + 0.5) / 15.0)",
			readers = {"lighting"},
		},
	},
	common = medium_common.GetGLSL(),
	surface_members = [[

		vec3 medium_scatter;
		vec3 medium_extinction;
		vec3 medium_tint_ratio;
		vec3 medium_deep;
		vec3 medium_porous;
		float medium_density;
		float medium_cover;
		float medium_back;
		float medium_thickness;
		float medium_body;
	]],
	surface_default = [[
		s.medium_scatter = vec3(0.0);
		s.medium_extinction = vec3(0.0);
		s.medium_tint_ratio = vec3(0.0);
		s.medium_deep = vec3(0.0);
		s.medium_porous = vec3(0.0);
		s.medium_density = 0.0;
		s.medium_cover = 0.0;
		s.medium_back = 0.0;
		s.medium_thickness = 0.0;
		s.medium_body = 0.0;
	]],
	material_init = [[
		if (has_terrain_layers()) {
			float terrain_ice = get_terrain_weighted_value(terrain_model.TerrainLayerMedium, terrain_model.TerrainLayerMedium2);
			if (terrain_ice > 0.5) {
				s.medium_slot = max(s.medium_slot, get_medium_slot());
				s.medium_mode = 1.0;
			}
		}
	]],
	surface_finish = [[
		s.medium_cover = 0.0;
		s.medium_scatter = vec3(0.0);
		s.medium_thickness = 0.0;

		if (s.medium_slot > 0.0) {
			int medium_slot = int(s.medium_slot + 0.5);
			vec4 slot_extinction = get_medium_slot_extinction(medium_slot);
			s.medium_extinction = slot_extinction.rgb;
			s.medium_density = slot_extinction.a;
			s.medium_tint_ratio = get_medium_slot_tint_ratio(medium_slot);
			s.medium_deep = get_medium_slot_deep_color(medium_slot);
			s.medium_porous = get_medium_slot_porous_color(medium_slot);
			float strength = saturate(s.medium_density);

			int porosity_level = int(floor(s.medium_porosity * 15.0 + 0.5));

			if (porosity_level == 15) {
				float brightness = pow(max(luminance(s.albedo), 0.0), 1.0 / 2.2);
				s.medium_porosity = smoothstep(get_medium_porosity_low(), get_medium_porosity_high(), brightness);
			} else {
				s.medium_porosity = float(porosity_level) / 14.0;
			}

			int mode_level = int(floor(s.medium_mode * 15.0 + 0.5));
			bool snow_mask = mode_level == 15;
			bool is_body = !snow_mask && (mode_level & 7) == 7;
			s.medium_body = is_body ? 1.0 : 0.0;
			s.medium_back = (mode_level >= 8 && !snow_mask) ? 1.0 : 0.0;
			float exposure_amount = (snow_mask || is_body) ? 0.0 : float(mode_level & 7) / 6.0 * 0.9;

			if (exposure_amount > 0.0) {
				float open_distance = get_medium_light_path(s.world_pos + s.geometric_N * 0.02, s.geometric_N, MEDIUM_EXPOSURE_RANGE);
				float exposure = open_distance > 0.0 ? smoothstep(0.2, 1.0, open_distance / MEDIUM_EXPOSURE_RANGE) : 1.0;
				s.medium_porosity = max(s.medium_porosity, exposure_amount * exposure);
			}

			float slope_snow = get_medium_cover_slope() * smoothstep(0.5, 0.85, s.N.y);
			s.medium_porosity = max(s.medium_porosity, slope_snow);

			float body = 1.0 - 0.6 * s.medium_porosity;
			float fake_depth = 4.0 * strength * mix(0.5, 1.0, min(abs(dot(s.N, s.V)), 0.8) / 0.8) * body;
			vec3 tint = exp(-fake_depth * s.medium_tint_ratio);
			float assumed_thickness = min(get_medium_assumed_thickness(s.world_pos), MEDIUM_MAX_PATH);
			float view_path = assumed_thickness > 0.0 ? 0.0 : get_medium_light_path(s.world_pos - s.geometric_N * 0.003, -s.V, MEDIUM_MAX_PATH);
			s.medium_thickness = assumed_thickness;

			if (assumed_thickness > 0.0 && (is_body || get_medium_use_local_thickness() > 0.5)) {
				s.medium_thickness = get_medium_local_thickness(s.world_pos, s.N, s.geometric_N, assumed_thickness);
			}
			view_path = max(view_path, s.medium_thickness);

			if (view_path > 0.0) {
				s.medium_scatter = medium_scatter_color(s.medium_extinction, s.medium_porous, view_path, s.medium_porosity);
			} else {
				s.medium_scatter = mix(tint, s.medium_porous, s.medium_porosity * s.medium_porosity);
			}

			if (snow_mask) {
				s.medium_cover = saturate(5.4545 * (pow(max(s.albedo.b, 0.0), 1.0 / 2.2) - 0.325) - 1.5);
			}

			s.albedo = mix(s.medium_scatter, mix(s.albedo, s.medium_porous, slope_snow), max(s.medium_cover, s.medium_porosity));
			float rough = mix(sqrt(s.roughness_alpha), 0.85, s.medium_porosity);
			s.perceptual_roughness = max(s.perceptual_roughness, rough);
			s.roughness_alpha = max(s.roughness_alpha, rough * rough);
			s.F0 *= 1.0 - 0.8 * s.medium_porosity;
		}
	]],
	face = [[
		if (back && s.medium_slot > 0.0 && s.medium_mode < 0.99 && int(floor(s.medium_mode * 15.0 + 0.5)) != 7) s.medium_mode += 8.0 / 15.0;
	]],
	compose = [[
		if (s.medium_slot > 0.0 && s.medium_back > 0.5 && get_medium_assumed_thickness(s.world_pos) <= 0.0) {
			float inside_distance = min(distance(lighting_data.camera_position.xyz, s.world_pos), MEDIUM_VIEW_DEPTH_CAP);
			vec3 transmit = medium_transmittance(s.medium_extinction, inside_distance, 0.0);
			float medium_sky_visibility;
			vec3 medium = s.medium_deep * get_gi_irradiance(s.N, medium_sky_visibility);
			compose_color = mix(medium, compose_color, transmit);
		}
	]],
	lit_from_behind = "s.medium_slot > 0.0",
	direct_layer = [[
		if (s.medium_slot > 0.0) diffuse_weight *= max(s.medium_cover, s.medium_porosity);
	]],
	direct = [[
		if (s.medium_slot > 0.0) {
			float diffusion = 1.0 - exp(-s.medium_thickness * get_medium_scatter_coefficient());
			float surface_light = shadow_factor * mix(saturate(dot(s.N, L)), saturate((dot(s.N, L) + 0.5) / 1.5) / 1.5, diffusion) * mix(1.0, medium_scatter_amount(s.medium_thickness), s.medium_body);
			diffuse += (1.0 - max(s.medium_cover, s.medium_porosity)) * s.medium_scatter * unshadowed_radiance * surface_light * (1.0 - s.metallic) / PI;
		}
	]],
	indirect = [[
		if (s.medium_slot > 0.0) {
			float medium_matte = max(s.medium_cover, s.medium_porosity);
			ambient_diffuse *= medium_matte;
			float medium_body = 1.0 - medium_matte;

			if (medium_body > 0.0) {
				vec3 back_irradiance = irradiance;

				if (ddgi_data.ddgi_cascade_count > 0 && ddgi_in_volume(s.world_pos)) {
					float back_weight;
					vec4 back_probes = ddgi_sample_irradiance(s.world_pos, -s.N, -s.N, s.V, ddgi_data.ddgi_smooth_blend != 0, DDGI_NO_VISIBILITY_RAYS, back_weight);

					if (back_weight > 0.0) back_irradiance = back_probes.rgb;
				}
				float far_side = get_medium_assumed_thickness(s.world_pos) > 0.0 ? s.medium_thickness : get_medium_light_path(s.world_pos - s.geometric_N * 0.003, -s.N, MEDIUM_MAX_PATH);
				vec3 through = medium_transmittance(s.medium_extinction, far_side, 0.0);
				float in_scatter = 0.3 * (1.0 - exp(-far_side * get_medium_scatter_coefficient()));
				ambient_diffuse += medium_body * s.medium_scatter * (in_scatter * mix(1.0, medium_scatter_amount(s.medium_thickness), s.medium_body) * irradiance + (1.0 - in_scatter) * MEDIUM_TRANSMIT_SHARE * through * back_irradiance) * ambient_occlusion * (1.0 - s.metallic);
			}
		}
	]],
}
