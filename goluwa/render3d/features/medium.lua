local medium_common = import("goluwa/render3d/medium_common.lua")
return {
	name = "medium",
	category = "Medium",
	params = {
		{
			name = "MediumAbsorption",
			default = 0.0,
			getter = "get_medium_absorption",
			callback = "InvalidateRayMaterial",
		},
		{name = "MediumCover", default = 0.0, getter = "get_medium_cover"},
		{name = "MediumPorosity", default = 0.0, callback = "InvalidateRayMaterial"},
		{
			name = "MediumPorosityFromAlbedo",
			default = 0.0,
			callback = "InvalidateRayMaterial",
		},
		{name = "MediumPorosityLow", default = 0.35, callback = "InvalidateRayMaterial"},
		{name = "MediumPorosityHigh", default = 0.8, callback = "InvalidateRayMaterial"},
		{name = "MediumPorosityExposure", default = 0.0, getter = "get_medium_exposure"},
	},
	fields = {
		{
			name = "medium_absorption",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_medium_absorption()",
			encode = "v / 32.0",
			decode = "v * 32.0",
			max = 32,
			readers = {"lighting"},
		},
		{
			name = "medium_porosity",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_medium_porosity(uv)",
			readers = {"lighting"},
		},
		{
			name = "medium_mode",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_medium_cover() > 0.0 ? 1.0 : floor(min(get_medium_exposure(), 0.9) / 0.9 * 6.0 + 0.5) / 15.0",
			readers = {"lighting"},
		},
	},
	getters = [[
		float get_medium_porosity(vec2 uv) {
			float porosity = factor_model.MediumPorosity;

			if (factor_model.MediumPorosityFromAlbedo > 0.0) {
				float brightness = pow(max(luminance(get_albedo_uv(uv)), 0.0), 1.0 / 2.2);
				porosity = max(porosity, clamp((brightness - factor_model.MediumPorosityLow) / (factor_model.MediumPorosityHigh - factor_model.MediumPorosityLow), 0.0, 1.0));
			}

			return porosity;
		}
	]],
	common = medium_common.GetGLSL(),
	surface_members = [[

		vec3 medium_scatter;
		float medium_cover;
		float medium_back;
		float medium_thickness;
	]],
	surface_default = [[
		s.medium_scatter = vec3(0.0);
		s.medium_cover = 0.0;
		s.medium_back = 0.0;
		s.medium_thickness = 0.0;
	]],
	material_init = [[
		if (has_terrain_layers()) {
			float terrain_ice = get_terrain_weighted_value(terrain_model.TerrainLayerMedium, terrain_model.TerrainLayerMedium2);
			s.medium_absorption = max(s.medium_absorption, terrain_ice);
			if (terrain_ice > 0.0) s.medium_mode = 1.0;
		}
	]],
	surface_finish = [[
		s.medium_cover = 0.0;
		s.medium_scatter = vec3(0.0);
		s.medium_thickness = 0.0;

		if (s.medium_absorption > 0.0) {
			float strength = saturate(s.medium_absorption / 10.0);

			int mode_level = int(floor(s.medium_mode * 15.0 + 0.5));
			bool snow_mask = mode_level == 15;
			s.medium_back = (mode_level >= 8 && !snow_mask) ? 1.0 : 0.0;
			float exposure_amount = snow_mask ? 0.0 : float(mode_level & 7) / 6.0 * 0.9;

			if (exposure_amount > 0.0) {
				float open_distance = get_medium_light_path(s.world_pos + s.geometric_N * 0.02, s.geometric_N, MEDIUM_EXPOSURE_RANGE);
				float exposure = open_distance > 0.0 ? smoothstep(0.2, 1.0, open_distance / MEDIUM_EXPOSURE_RANGE) : 1.0;
				s.medium_porosity = max(s.medium_porosity, exposure_amount * exposure);
			}

			float slope_snow = get_medium_cover_slope() * smoothstep(0.5, 0.85, s.N.y);
			s.medium_porosity = max(s.medium_porosity, slope_snow);

			float body = 1.0 - 0.6 * s.medium_porosity;
			float fake_depth = 4.0 * strength * mix(0.5, 1.0, min(abs(dot(s.N, s.V)), 0.8) / 0.8) * body;
			vec3 tint = exp(-fake_depth * MEDIUM_TINT_RATIO);
			float assumed_thickness = min(get_medium_assumed_thickness(s.world_pos), MEDIUM_MAX_PATH);
			float view_path = assumed_thickness > 0.0 ? 0.0 : get_medium_light_path(s.world_pos - s.geometric_N * 0.003, -s.V, MEDIUM_MAX_PATH);
			s.medium_thickness = assumed_thickness > 0.0 ? get_medium_local_thickness(s.world_pos, s.N, s.geometric_N, assumed_thickness) : 0.0;
			view_path = max(view_path, s.medium_thickness);

			if (view_path > 0.0) {
				tint = exp(-min(view_path, MEDIUM_VIEW_DEPTH_CAP) * MEDIUM_EXTINCTION * (s.medium_absorption / 10.0) * body);
			}

			s.medium_scatter = mix(tint, MEDIUM_POROUS_COLOR, s.medium_porosity * s.medium_porosity);

			if (snow_mask) {
				s.medium_cover = saturate(5.4545 * (pow(max(s.albedo.b, 0.0), 1.0 / 2.2) - 0.325) - 1.5);
			}

			s.albedo = mix(s.medium_scatter, mix(s.albedo, MEDIUM_POROUS_COLOR, slope_snow), max(s.medium_cover, s.medium_porosity));
			float rough = mix(sqrt(s.roughness_alpha), 0.85, s.medium_porosity);
			s.perceptual_roughness = max(s.perceptual_roughness, rough);
			s.roughness_alpha = max(s.roughness_alpha, rough * rough);
			s.F0 *= 1.0 - 0.8 * s.medium_porosity;
		}
	]],
	face = [[
		if (back && s.medium_absorption > 0.0 && s.medium_mode < 0.99) s.medium_mode += 8.0 / 15.0;
	]],
	compose = [[
		if (s.medium_absorption > 0.0 && s.medium_back > 0.5 && get_medium_assumed_thickness(s.world_pos) <= 0.0) {
			float inside_distance = min(distance(lighting_data.camera_position.xyz, s.world_pos), MEDIUM_VIEW_DEPTH_CAP);
			vec3 transmit = exp(-inside_distance * MEDIUM_EXTINCTION * (s.medium_absorption / 10.0));
			float medium_sky_visibility;
			vec3 medium = MEDIUM_DEEP_COLOR * get_gi_irradiance(s.N, medium_sky_visibility);
			compose_color = mix(medium, compose_color, transmit);
		}
	]],
	lit_from_behind = "s.medium_absorption > 0.0",
	direct_floor = [[
		if (s.medium_absorption > 0.0) scatter_floor = 1.0;
	]],
	direct_layer = [[
		if (s.medium_absorption > 0.0) diffuse_weight *= max(s.medium_cover, s.medium_porosity);
	]],
	direct = [[
		if (s.medium_absorption > 0.0) {
			float diffusion = 1.0 - exp(-s.medium_thickness * get_medium_scatter_coefficient());
			float surface_light = shadow_factor * mix(saturate(3.0 * dot(s.N, L)), saturate((dot(s.N, L) + 0.5) / 1.5), diffusion);
			vec3 through = vec3(0.0);

			if (surface_light < 0.99) {
				float light_reach = type == 0 ? MEDIUM_MAX_PATH : min(MEDIUM_MAX_PATH, length(light.position.xyz - s.world_pos));
				float path = get_medium_light_path(s.world_pos - s.geometric_N * 0.003, L, light_reach);
				path = max(path, min(s.medium_thickness / max(abs(dot(s.N, L)), 0.25), light_reach));
				through = mix(exp(-path * MEDIUM_EXTINCTION * (s.medium_absorption / 10.0)), exp(-path * MEDIUM_EXTINCTION * (s.medium_absorption / 10.0) * 0.35), s.medium_porosity);
			}

			vec3 light_through = surface_light + (1.0 - surface_light) * through;
			diffuse += (1.0 - max(s.medium_cover, s.medium_porosity)) * s.medium_scatter * unshadowed_radiance * light_through * (1.0 - s.metallic) / PI;
		}
	]],
	indirect = [[
		if (s.medium_absorption > 0.0) {
			float medium_body = 1.0 - max(s.medium_cover, s.medium_porosity);

			if (medium_body > 0.0) {
				vec3 front_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, s.N) * sky_visibility;
				vec3 back_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, -s.N);
				vec3 back_irradiance = back_sky + max(irradiance - front_sky, vec3(0.0));
				float far_side = max(get_medium_light_path(s.world_pos - s.geometric_N * 0.003, -s.N, MEDIUM_MAX_PATH), s.medium_thickness);
				vec3 through = exp(-far_side * MEDIUM_EXTINCTION * (s.medium_absorption / 10.0));
				ambient_diffuse += medium_body * s.medium_scatter * through * back_irradiance * ambient_occlusion * (1.0 - s.metallic);
				ambient_diffuse += medium_body * s.medium_scatter * (1.0 - exp(-s.medium_thickness * get_medium_scatter_coefficient())) * 0.3 * irradiance * ambient_occlusion * (1.0 - s.metallic);
			}
		}
	]],
}
