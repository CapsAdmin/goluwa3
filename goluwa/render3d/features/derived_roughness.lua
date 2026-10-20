-- a material with no roughness map is uniformly smooth. this varies its roughness around the constant it
-- has, rougher where the albedo is darker than its average (dirt, wear, grout) and where the normal map
-- leans off the surface, and takes specular away from the same places (specular occlusion in cracks, pores and
-- grout). the amounts are 0 for a material that has a roughness source of its own
return {
	name = "derived_roughness",
	category = "Derived Roughness",
	params = {
		-- perceptual roughness per unit of difference between the sqrt of the albedo's luminance and its mean
		{name = "DerivedRoughnessAlbedo", default = 0.0, getter = "get_derived_roughness_albedo"},
		{name = "DerivedRoughnessAlbedoMean", default = 0.5, requires = "DerivedRoughnessAlbedo", getter = "get_derived_roughness_albedo_mean"},
		-- perceptual roughness per unit of 1 - normal.z
		{name = "DerivedRoughnessNormal", default = 0.0, getter = "get_derived_roughness_normal"},
		-- a metal has a low roughness to begin with and little to vary, so its variation is this many times larger
		{name = "DerivedRoughnessMetal", default = 0.0, getter = "get_derived_roughness_metal"},
		-- the part of the specular a crevice loses, 1 is all of it
		{name = "DerivedSpecularCavity", default = 0.0, getter = "get_derived_specular_cavity"},
	},
	material_init = [[
		if ((get_derived_roughness_albedo() > 0.0 || get_derived_roughness_normal() > 0.0 || get_derived_specular_cavity() > 0.0) && get_roughness_texel(uv) < 0.0) {
			float derived = sqrt(s.roughness_alpha);
			// how much of a crevice the texel is, from 0 to 1
			float cavity = 0.0;
			float contrast = 1.0 + get_derived_roughness_metal() * s.metallic;

			if (model.AlbedoTexture != -1) {
				float darker = get_derived_roughness_albedo_mean() - sqrt(luminance(get_albedo_uv(uv)));
				derived += get_derived_roughness_albedo() * contrast * darker;
				cavity = clamp(darker / max(get_derived_roughness_albedo_mean(), 0.05), 0.0, 1.0);
			}

			if (model.NormalTexture != -1) {
				float lean = 1.0 - clamp(get_normal_map(uv).z, 0.0, 1.0);
				derived += get_derived_roughness_normal() * contrast * lean;
				cavity = max(cavity, clamp(lean * 4.0, 0.0, 1.0));
			}

			s.roughness_alpha = clamp(derived * derived, 0.002, 1.0);
			s.specular *= 1.0 - get_derived_specular_cavity() * cavity;
		}
	]],
}
