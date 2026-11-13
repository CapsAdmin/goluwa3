return {
	name = "ice",
	category = "Ice",
	params = {
		{name = "IceAbsorption", default = 0.0, getter = "get_ice_absorption"},
		{name = "IceSnowMask", default = 0.0, getter = "get_ice_snow_mask"},
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
			name = "ice_snow_mask",
			sheet = "specular",
			kind = "unorm4",
			default = "0.0",
			material = "get_ice_snow_mask()",
			readers = {"lighting"},
		},
	},
	common = [[
		#define ICE_MAX_PATH 60.0
		const vec3 ICE_EXTINCTION = vec3(0.3, 0.09, 0.035);
	]],
	surface_members = [[

		vec3 ice_scatter;
		float ice_snow;
	]],
	surface_default = [[
		s.ice_scatter = vec3(0.0);
		s.ice_snow = 0.0;
	]],
	material_init = [[
		if (has_terrain_layers()) {
			float terrain_ice = get_terrain_weighted_value(terrain_model.TerrainLayerIce, terrain_model.TerrainLayerIce2);
			s.ice_absorption = max(s.ice_absorption, terrain_ice);
			if (terrain_ice > 0.0) s.ice_snow_mask = 1.0;
		}
	]],
	surface_finish = [[
		s.ice_snow = 0.0;
		s.ice_scatter = vec3(0.0);

		if (s.ice_absorption > 0.0) {
			float scatter_depth = 4.0 * saturate(s.ice_absorption / 10.0) * mix(0.5, 1.0, min(abs(dot(s.N, s.V)), 0.8) / 0.8);
			s.ice_scatter = exp(-scatter_depth * vec3(1.0, 0.7, 0.55));

			if (s.ice_snow_mask > 0.0) {
				s.ice_snow = saturate(5.4545 * (pow(max(s.albedo.b, 0.0), 1.0 / 2.2) - 0.325) - 1.5);
			}

			s.albedo = mix(s.ice_scatter, s.albedo, s.ice_snow);
		}
	]],
	lit_from_behind = "s.ice_absorption > 0.0",
	direct_floor = [[
		if (s.ice_absorption > 0.0) scatter_floor = 1.0;
	]],
	direct_layer = [[
		if (s.ice_absorption > 0.0) diffuse_weight *= s.ice_snow;
	]],
	direct = [[
		if (s.ice_absorption > 0.0) {
			float surface_light = shadow_factor * saturate(3.0 * dot(s.N, L));
			vec3 through = vec3(0.0);

			if (surface_light < 0.99) {
				float path = get_ice_light_path(s.world_pos - s.geometric_N * 0.003, L, ICE_MAX_PATH);
				through = exp(-path * ICE_EXTINCTION * (s.ice_absorption / 10.0));
			}

			vec3 light_through = surface_light + (1.0 - surface_light) * through;
			diffuse += (1.0 - s.ice_snow) * s.ice_scatter * unshadowed_radiance * light_through * (1.0 - s.metallic) / PI;
		}
	]],
}
