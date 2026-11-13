local ice_common = import("goluwa/render3d/ice_common.lua")
return {
	name = "ice",
	category = "Ice",
	params = {
		{
			name = "IceAbsorption",
			default = 0.0,
			getter = "get_ice_absorption",
			callback = "InvalidateRayMaterial",
		},
		{name = "IceSnowMask", default = 0.0, getter = "get_ice_snow_mask"},
		{name = "IcePorosity", default = 0.0, callback = "InvalidateRayMaterial"},
		{
			name = "IcePorosityFromAlbedo",
			default = 0.0,
			callback = "InvalidateRayMaterial",
		},
		{name = "IcePorosityLow", default = 0.35, callback = "InvalidateRayMaterial"},
		{name = "IcePorosityHigh", default = 0.8, callback = "InvalidateRayMaterial"},
		{name = "IcePorosityExposure", default = 0.0, getter = "get_ice_exposure"},
	},
	fields = {
		{
			name = "ice_absorption",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_ice_absorption()",
			encode = "v / 32.0",
			decode = "v * 32.0",
			max = 32,
			readers = {"lighting"},
		},
		{
			name = "ice_porosity",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_ice_porosity(uv)",
			readers = {"lighting"},
		},
		{
			name = "ice_mode",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_ice_snow_mask() > 0.0 ? 1.0 : floor(min(get_ice_exposure(), 0.9) / 0.9 * 6.0 + 0.5) / 15.0",
			readers = {"lighting"},
		},
	},
	getters = [[
		float get_ice_porosity(vec2 uv) {
			float porosity = factor_model.IcePorosity;

			if (factor_model.IcePorosityFromAlbedo > 0.0) {
				float brightness = pow(max(luminance(get_albedo_uv(uv)), 0.0), 1.0 / 2.2);
				porosity = max(porosity, clamp((brightness - factor_model.IcePorosityLow) / (factor_model.IcePorosityHigh - factor_model.IcePorosityLow), 0.0, 1.0));
			}

			return porosity;
		}
	]],
	common = ice_common.GLSL,
	surface_members = [[

		vec3 ice_scatter;
		float ice_snow;
		float ice_back;
		float ice_thickness;
	]],
	surface_default = [[
		s.ice_scatter = vec3(0.0);
		s.ice_snow = 0.0;
		s.ice_back = 0.0;
		s.ice_thickness = 0.0;
	]],
	material_init = [[
		if (has_terrain_layers()) {
			float terrain_ice = get_terrain_weighted_value(terrain_model.TerrainLayerIce, terrain_model.TerrainLayerIce2);
			s.ice_absorption = max(s.ice_absorption, terrain_ice);
			if (terrain_ice > 0.0) s.ice_mode = 1.0;
		}
	]],
	surface_finish = [[
		s.ice_snow = 0.0;
		s.ice_scatter = vec3(0.0);
		s.ice_thickness = 0.0;

		if (s.ice_absorption > 0.0) {
			float strength = saturate(s.ice_absorption / 10.0);

			int mode_level = int(floor(s.ice_mode * 15.0 + 0.5));
			bool snow_mask = mode_level == 15;
			s.ice_back = (mode_level >= 8 && !snow_mask) ? 1.0 : 0.0;
			float exposure_amount = snow_mask ? 0.0 : float(mode_level & 7) / 6.0 * 0.9;

			if (exposure_amount > 0.0) {
				float open_distance = get_ice_light_path(s.world_pos + s.geometric_N * 0.02, s.geometric_N, ICE_EXPOSURE_RANGE);
				float exposure = open_distance > 0.0 ? smoothstep(0.2, 1.0, open_distance / ICE_EXPOSURE_RANGE) : 1.0;
				s.ice_porosity = max(s.ice_porosity, exposure_amount * exposure);
			}

			float slope_snow = get_ice_snow_slope() * smoothstep(0.5, 0.85, s.N.y);
			s.ice_porosity = max(s.ice_porosity, slope_snow);

			float body = 1.0 - 0.6 * s.ice_porosity;
			float fake_depth = 4.0 * strength * mix(0.5, 1.0, min(abs(dot(s.N, s.V)), 0.8) / 0.8) * body;
			vec3 tint = exp(-fake_depth * ICE_TINT_RATIO);
			float assumed_thickness = min(get_ice_assumed_thickness(s.world_pos), ICE_MAX_PATH);
			float view_path = assumed_thickness > 0.0 ? 0.0 : get_ice_light_path(s.world_pos - s.geometric_N * 0.003, -s.V, ICE_MAX_PATH);
			s.ice_thickness = assumed_thickness > 0.0 ? get_ice_local_thickness(s.world_pos, s.N, s.geometric_N, assumed_thickness) : 0.0;
			view_path = max(view_path, s.ice_thickness);

			if (view_path > 0.0) {
				tint = exp(-min(view_path, ICE_VIEW_DEPTH_CAP) * ICE_EXTINCTION * (s.ice_absorption / 10.0) * body);
			}

			s.ice_scatter = mix(tint, ICE_POROUS_COLOR, s.ice_porosity * s.ice_porosity);

			if (snow_mask) {
				s.ice_snow = saturate(5.4545 * (pow(max(s.albedo.b, 0.0), 1.0 / 2.2) - 0.325) - 1.5);
			}

			s.albedo = mix(s.ice_scatter, mix(s.albedo, ICE_POROUS_COLOR, slope_snow), max(s.ice_snow, s.ice_porosity));
			float rough = mix(sqrt(s.roughness_alpha), 0.85, s.ice_porosity);
			s.perceptual_roughness = max(s.perceptual_roughness, rough);
			s.roughness_alpha = max(s.roughness_alpha, rough * rough);
			s.F0 *= 1.0 - 0.8 * s.ice_porosity;
		}
	]],
	face = [[
		if (back && s.ice_absorption > 0.0 && s.ice_mode < 0.99) s.ice_mode += 8.0 / 15.0;
	]],
	compose = [[
		if (s.ice_absorption > 0.0 && s.ice_back > 0.5 && get_ice_assumed_thickness(s.world_pos) <= 0.0) {
			float inside_distance = min(distance(lighting_data.camera_position.xyz, s.world_pos), ICE_VIEW_DEPTH_CAP);
			vec3 transmit = exp(-inside_distance * ICE_EXTINCTION * (s.ice_absorption / 10.0));
			float medium_sky_visibility;
			vec3 medium = ICE_DEEP_COLOR * get_gi_irradiance(s.N, medium_sky_visibility);
			compose_color = mix(medium, compose_color, transmit);
		}
	]],
	lit_from_behind = "s.ice_absorption > 0.0",
	direct_floor = [[
		if (s.ice_absorption > 0.0) scatter_floor = 1.0;
	]],
	direct_layer = [[
		if (s.ice_absorption > 0.0) diffuse_weight *= max(s.ice_snow, s.ice_porosity);
	]],
	direct = [[
		if (s.ice_absorption > 0.0) {
			float diffusion = 1.0 - exp(-s.ice_thickness * get_ice_scatter_coefficient());
			float surface_light = shadow_factor * mix(saturate(3.0 * dot(s.N, L)), saturate((dot(s.N, L) + 0.5) / 1.5), diffusion);
			vec3 through = vec3(0.0);

			if (surface_light < 0.99) {
				float light_reach = type == 0 ? ICE_MAX_PATH : min(ICE_MAX_PATH, length(light.position.xyz - s.world_pos));
				float path = get_ice_light_path(s.world_pos - s.geometric_N * 0.003, L, light_reach);
				path = max(path, min(s.ice_thickness / max(abs(dot(s.N, L)), 0.25), light_reach));
				through = mix(exp(-path * ICE_EXTINCTION * (s.ice_absorption / 10.0)), exp(-path * ICE_EXTINCTION * (s.ice_absorption / 10.0) * 0.35), s.ice_porosity);
			}

			vec3 light_through = surface_light + (1.0 - surface_light) * through;
			diffuse += (1.0 - max(s.ice_snow, s.ice_porosity)) * s.ice_scatter * unshadowed_radiance * light_through * (1.0 - s.metallic) / PI;
		}
	]],
	indirect = [[
		if (s.ice_absorption > 0.0) {
			float ice_body = 1.0 - max(s.ice_snow, s.ice_porosity);

			if (ice_body > 0.0) {
				vec3 front_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, s.N) * sky_visibility;
				vec3 back_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, -s.N);
				vec3 back_irradiance = back_sky + max(irradiance - front_sky, vec3(0.0));
				float far_side = max(get_ice_light_path(s.world_pos - s.geometric_N * 0.003, -s.N, ICE_MAX_PATH), s.ice_thickness);
				vec3 through = exp(-far_side * ICE_EXTINCTION * (s.ice_absorption / 10.0));
				ambient_diffuse += ice_body * s.ice_scatter * through * back_irradiance * ambient_occlusion * (1.0 - s.metallic);
				ambient_diffuse += ice_body * s.ice_scatter * (1.0 - exp(-s.ice_thickness * get_ice_scatter_coefficient())) * 0.3 * irradiance * ambient_occlusion * (1.0 - s.metallic);
			}
		}
	]],
}
