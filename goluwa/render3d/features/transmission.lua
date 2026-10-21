local Color = import("goluwa/structs/color.lua")
return {
	name = "transmission",
	category = "Transmission",
	block = "own",
	active = function(material)
		return material:GetTransmissive()
	end,
	params = {
		{
			name = "TransmissionTexture",
			kind = "texture",
			type = "render_texture",
			requires = "DiffuseTransmission",
		},
		{name = "DiffuseTransmission", default = 0.0, callback = "InvalidateFlags"},
		{
			name = "TransmissionColor",
			kind = "vec4",
			default = Color(1.0, 1.0, 1.0, 1.0),
			requires = "DiffuseTransmission",
		},
		{name = "TransmissionScattering", default = 0.5, requires = "DiffuseTransmission"},
	},
	getters = [[
		float get_transmission(vec2 uv) {
			if (!Transmissive) return 0.0;

			float amount = transmission_model.DiffuseTransmission;

			if (transmission_model.TransmissionTexture != -1) {
				amount *= luminance(texture(TEXTURE(transmission_model.TransmissionTexture), uv).rgb);
			}

			return clamp(amount, 0.0, 1.0);
		}

		float get_transmission_scattering() {
			if (!Transmissive) return 0.0;
			return clamp(transmission_model.TransmissionScattering, 0.0, 1.0);
		}

		vec3 get_transmission_color() {
			if (!Transmissive) return vec3(1.0);
			vec3 tint = transmission_model.TransmissionColor.rgb;
			return tint / max(luminance(tint), 0.001);
		}
	]],
	fields = {
		{name = "transmission", kind = "unorm8", default = "0.0", material = "get_transmission(uv)"},
		{
			name = "transmission_scattering",
			sheet = "transmission",
			kind = "unorm4",
			default = "0.0",
			material = "get_transmission_scattering()",
		},
		{name = "transmission_tint_r", sheet = "transmission", kind = "unorm8", member = false, default = "1.0", encode = "v * 0.5", decode = "v * 2.0", max = 2},
		{name = "transmission_tint_b", sheet = "transmission", kind = "unorm8", member = false, default = "1.0", encode = "v * 0.5", decode = "v * 2.0", max = 2},
	},
	thin = "gbuffer_transmission(c) > 0.0",
	lit_from_behind = "s.transmission > 0.0",
	encoders = [[
		vec2 gbuffer_encode_transmission_tint(vec3 tint) {
			return vec2(gbuffer_encode_transmission_tint_r(tint.r), gbuffer_encode_transmission_tint_b(tint.b));
		}
	]],
	decoders = [[
		vec3 gbuffer_transmission_color(COORD c) {
			float r = gbuffer_transmission_tint_r(c);
			float b = gbuffer_transmission_tint_b(c);
			return vec3(r, max((1.0 - 0.2126 * r - 0.0722 * b) / 0.7152, 0.0), b);
		}
	]],
	common = [[

		float transmission_phase(vec3 V, vec3 L, float cos_incidence, float scattering)
		{
			const float g = 0.6;
			float henyey_greenstein = phase_henyey_greenstein(-dot(V, L), g);
			float c = saturate(cos_incidence);
			float lobe_flux = 0.37707 + c * (0.58701 + c * (0.57085 + c * (-0.29538 + c * 0.06498)));
			return mix(1.0 / PI, 2.0 * henyey_greenstein / lobe_flux, scattering);
		}
	]],
	surface_members = [[

		vec3 transmission_color;
	]],
	surface_default = [[
		s.transmission_color = vec3(1.0);
	]],
	material_init = [[
		s.transmission_color = get_transmission_color();
	]],
	weather_input = [[

		w.porosity *= 1.0 - s.transmission;
	]],
	weather = [[
		s.transmission *= 1.0 - w.snow;
	]],
	surface_decode = [[
		s.transmission_color = gbuffer_transmission_color(uv);
	]],
	gbuffer_write = [[
		vec2 transmission_tint = gbuffer_encode_transmission_tint(s.transmission_color);
		set_transmission_tint_r(transmission_tint.x);
		set_transmission_tint_b(transmission_tint.y);
	]],
	direct_shadow = [[

		if (s.transmission > 0.0) {
			shadow_N = normalize((dot(s.geometric_N, L) < 0.0 ? -s.geometric_N : s.geometric_N) + L);
			shadow_facing = 1.0;
		}
	]],
	direct_layer = [[
		diffuse_weight *= 1.0 - s.transmission;
	]],
	direct = [[
		if (s.transmission > 0.0) {
			diffuse += s.transmission * s.transmission_color * s.albedo * (1.0 - s.metallic) * transmission_phase(s.V, L, saturate(-dot(s.N, L)), s.transmission_scattering) * saturate(-dot(s.N, L)) * radiance;
		}
	]],
	indirect = [[
		ambient_diffuse *= 1.0 - s.transmission;

		if (s.transmission > 0.0) {
			vec3 front_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, s.N) * sky_visibility;
			vec3 back_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, -s.N) * sky_visibility;
			vec3 back_irradiance = back_sky + max(irradiance - front_sky, vec3(0.0));
			ambient_diffuse += s.transmission * s.transmission_color * s.albedo * (1.0 - s.metallic) * back_irradiance * ambient_occlusion;
		}
	]],
}
