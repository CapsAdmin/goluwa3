return {
	name = "weather_response",
	category = "Weather",
	params = {
		{name = "Porosity", default = 1.0, getter = "get_porosity_scale"},
		{name = "WetnessResponse", default = 1.0, getter = "get_wetness_scale"},
		{name = "SnowResponse", default = 1.0, getter = "get_snow_scale"},
	},
	surface_members = [[
		float porosity_scale;
		float wetness_scale;
		float snow_scale;
	]],
	surface_default = [[
		s.porosity_scale = 1.0;
		s.wetness_scale = 1.0;
		s.snow_scale = 1.0;
	]],
	material_init = [[
		s.porosity_scale = get_porosity_scale();
		s.wetness_scale = get_wetness_scale();
		s.snow_scale = get_snow_scale();
	]],
	weather_input = [[
		w.porosity *= s.porosity_scale;
		w.wet_scale *= s.wetness_scale;
		w.snow_scale *= s.snow_scale;
	]],
}
