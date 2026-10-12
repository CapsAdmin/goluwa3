local Color = import("goluwa/structs/color.lua")
-- light through a thin surface, leaves and cloth
return {
	name = "transmission",
	category = "Transmission",
	-- the params have a texture and a color, and a material that isn't transmissive doesn't upload them
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
				amount *= dot(texture(TEXTURE(transmission_model.TransmissionTexture), uv).rgb, vec3(0.2126, 0.7152, 0.0722));
			}

			return clamp(amount, 0.0, 1.0);
		}

		float get_transmission_scattering() {
			if (!Transmissive) return 0.0;
			return clamp(transmission_model.TransmissionScattering, 0.0, 1.0);
		}

		// only the hue, the brightness comes from DiffuseTransmission
		vec3 get_transmission_color() {
			if (!Transmissive) return vec3(1.0);
			vec3 tint = transmission_model.TransmissionColor.rgb;
			return tint / max(dot(tint, vec3(0.2126, 0.7152, 0.0722)), 0.001);
		}
	]],
	fields = {
		{name = "transmission", kind = "unorm8", default = "0.0", material = "get_transmission(uv)"},
		{
			name = "transmission_scattering",
			kind = "unorm8",
			default = "0.0",
			material = "get_transmission_scattering()",
		},
		-- red and blue of a tint, halved to fit up to 2. its luminance is 1, which gives the green back
		{name = "transmission_tint_r", kind = "unorm8", member = false, default = "1.0", encode = "v * 0.5", decode = "v * 2.0"},
		{name = "transmission_tint_b", kind = "unorm8", member = false, default = "1.0", encode = "v * 0.5", decode = "v * 2.0"},
	},
	thin = "gbuffer_transmission(c) > 0.0",
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
		// how a thin surface spreads the light going through it, over the side facing away from the
		// light. lambert, blended by scattering towards a henyey greenstein lobe around the light's
		// direction with the same total over that side
		float transmission_phase(vec3 V, vec3 L, float scattering)
		{
			const float g = 0.6;
			float denominator = 1.0 + g * g + 2.0 * g * dot(V, L);
			float henyey_greenstein = (1.0 - g * g) / (4.0 * BRDF_PI * denominator * sqrt(denominator));
			return mix(1.0 / BRDF_PI, 2.0 * henyey_greenstein, scattering);
		}
	]],
	surface_members = [[
		// the part of the diffuse light that leaves through the side facing away from the light
		vec3 transmission_color;
	]],
	surface_default = [[
		s.transmission_color = vec3(1.0);
	]],
	material_init = [[
		s.transmission_color = get_transmission_color();
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
		// light reaches a thin translucent surface from either side, so its shadow is looked up
		// on the side facing the light, and bent towards the light so edge on doesn't read as
		// facing away
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
			diffuse += s.transmission * s.transmission_color * s.albedo * (1.0 - s.metallic) * transmission_phase(s.V, L, s.transmission_scattering) * saturate(-dot(s.N, L)) * radiance;
		}
	]],
	indirect = [[
		ambient_diffuse *= 1.0 - s.transmission;

		if (s.transmission > 0.0) {
			// the gi only holds the light arriving at the front. the sky's part of it
			// is taken again from behind, and what bounced is assumed the same on
			// both sides
			vec3 front_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, s.N) * sky_visibility;
			vec3 back_sky = sample_environment_irradiance(lighting_data.env_irradiance_tex, -s.N) * sky_visibility;
			vec3 back_irradiance = back_sky + max(irradiance - front_sky, vec3(0.0));
			ambient_diffuse += s.transmission * s.transmission_color * s.albedo * (1.0 - s.metallic) * back_irradiance * ambient_occlusion;
		}
	]],
}
